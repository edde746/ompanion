#include "notifications.h"

#include "app.h"
#include "json.h"
#include "util.h"

// mingw-w64's windows.foundation.h specializes IReference for BYTE and for boolean, which C++ sees as one type
// (unsigned char): skipping the second, unused one lets the WinRT headers compile.
#define ____FIReference_1_boolean_INTERFACE_DEFINED__

#include <notificationactivationcallback.h>
#include <roapi.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>
#include <winstring.h>
#include <wrl/client.h>

#include <cstdio>
#include <optional>

using Microsoft::WRL::ComPtr;
namespace wdxd = ABI::Windows::Data::Xml::Dom;
namespace wfc = ABI::Windows::Foundation::Collections;
namespace wun = ABI::Windows::UI::Notifications;

namespace {

constexpr wchar_t kGroup[] = L"ompanion";
// The activator's COM class, named in the AppUserModelId registration and the MSIX manifest (msix/build-msix.ps1). It
// is the Flutter app's (flutter_local_notifications' guid), so the registration that app left is the one kept.
constexpr wchar_t kActivatorId[] = L"{75884955-9AE9-4917-B244-95258D7AA2C7}";
constexpr CLSID kActivator = {0x75884955, 0x9ae9, 0x4917, {0xb2, 0x44, 0x95, 0x25, 0x8d, 0x7a, 0xa2, 0xc7}};

class HString {
public:
    explicit HString(std::wstring_view text) {
        ensure(WindowsCreateString(text.data(), static_cast<UINT32>(text.size()), &value_), "creating a WinRT string");
    }
    ~HString() { WindowsDeleteString(value_); }
    HString(const HString&) = delete;
    HString& operator=(const HString&) = delete;

    HSTRING get() const { return value_; }

private:
    HSTRING value_ = nullptr;
};

template <class Interface>
ComPtr<Interface> factory(const wchar_t* runtimeClass) {
    ComPtr<Interface> object;
    ensure(RoGetActivationFactory(HString(runtimeClass).get(), __uuidof(Interface),
                                  reinterpret_cast<void**>(object.GetAddressOf())),
           "getting the factory of " + narrow(runtimeClass));
    return object;
}

// The arguments are the launch attribute content() wrote: {"id": …, "data": …}.
void tapped(const std::string& arguments) {
    std::optional<Json> launch = parseJson(arguments);
    const Json* id = launch ? launch->find("id") : nullptr;
    const Json* data = launch ? launch->find("data") : nullptr;
    if (!id || id->kind != Json::Kind::String || !data) {
        log("ignored a toast activation with the arguments " + arguments);
        return;
    }
    bringToFront();
    postWhenListening(R"({"event":"shell.notificationTap","params":{"id":)" + quote(id->string) + R"(,"data":)" +
                      std::string(data->raw) + "}}");
}

// The activator and its factory live as long as the process, so they count no references.
class Activator final : public INotificationActivationCallback {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
        if (riid == IID_IUnknown || riid == __uuidof(INotificationActivationCallback)) {
            *object = this;
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }

    // On the UI thread: COM calls into the single-threaded apartment that registered the factory through its
    // message loop.
    HRESULT STDMETHODCALLTYPE Activate(LPCWSTR, LPCWSTR arguments, const NOTIFICATION_USER_INPUT_DATA*,
                                       ULONG) override {
        tapped(narrow(arguments ? arguments : L""));
        return S_OK;
    }
} activator;

class ActivatorFactory final : public IClassFactory {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *object = this;
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }

    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID riid, void** object) override {
        if (outer) {
            *object = nullptr;
            return CLASS_E_NOAGGREGATION;
        }
        return activator.QueryInterface(riid, object);
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL) override { return S_OK; }
} activatorFactory;

void setRegistryValue(const std::wstring& key, const wchar_t* name, const std::wstring& value) {
    LSTATUS status = RegSetKeyValueW(HKEY_CURRENT_USER, key.c_str(), name, REG_SZ, value.c_str(),
                                     static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    warn(HRESULT_FROM_WIN32(status), "writing HKCU\\" + narrow(key));
}

// Windows keeps a toast's tag to 64 characters: a hash of the id fits whatever the id's length.
std::wstring tag(const std::string& id) {
    uint32_t hash = 0x811c9dc5;
    for (unsigned char byte : id) hash = (hash ^ byte) * 0x01000193;
    char text[9];
    std::snprintf(text, sizeof text, "%08x", static_cast<unsigned>(hash));
    return widen(text);
}

// Text for an XML attribute or element. Control characters other than tab and line breaks are not allowed in XML.
std::string escapeXml(std::string_view text) {
    std::string out;
    out.reserve(text.size());
    for (char c : text) {
        switch (c) {
        case '&': out += "&amp;"; break;
        case '<': out += "&lt;"; break;
        case '>': out += "&gt;"; break;
        case '"': out += "&quot;"; break;
        case '\'': out += "&apos;"; break;
        default:
            if (static_cast<unsigned char>(c) >= 0x20 || c == '\t' || c == '\n' || c == '\r') out += c;
        }
    }
    return out;
}

ComPtr<wdxd::IXmlDocument> content(const Toast& toast) {
    std::string launch = R"({"id":)" + quote(toast.id) + R"(,"data":)" + toast.data + "}";
    std::string xml = "<toast launch=\"" + escapeXml(launch) +
                      "\"><visual><binding template=\"ToastGeneric\"><text>" + escapeXml(toast.title) + "</text>";
    if (!toast.subtitle.empty()) xml += "<text>" + escapeXml(toast.subtitle) + "</text>";
    xml += "<text>" + escapeXml(toast.body) + "</text></binding></visual></toast>";

    ComPtr<IInspectable> instance;
    ensure(RoActivateInstance(HString(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).get(), instance.GetAddressOf()),
           "creating a toast's XML document");
    ComPtr<wdxd::IXmlDocumentIO> loader;
    ensure(instance.As(&loader), "getting IXmlDocumentIO");
    ensure(loader->LoadXml(HString(widen(xml)).get()), "reading a toast's XML");
    ComPtr<wdxd::IXmlDocument> document;
    ensure(instance.As(&document), "getting IXmlDocument");
    return document;
}

ComPtr<wun::IToastNotificationManagerStatics> manager() {
    return factory<wun::IToastNotificationManagerStatics>(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager);
}

// A packaged app's toasts belong to its package's AppUserModelID, which CreateToastNotifier without an id takes.
ComPtr<wun::IToastNotifier> notifier() {
    startNotifications();
    ComPtr<wun::IToastNotifier> notifier;
    ensure(packaged ? manager()->CreateToastNotifier(notifier.GetAddressOf())
                    : manager()->CreateToastNotifierWithId(HString(kAppId).get(), notifier.GetAddressOf()),
           "creating the toast notifier");
    return notifier;
}

// Windows keeps a second toast scheduled under a tag beside the first, so a replacement removes the old one first.
// The schedule outlives the process: this finds what an earlier run scheduled too.
void unschedule(wun::IToastNotifier* notifier, const std::wstring& tag) {
    ComPtr<wfc::IVectorView<wun::ScheduledToastNotification*>> list;
    ensure(notifier->GetScheduledToastNotifications(list.GetAddressOf()), "listing the scheduled toasts");
    unsigned count;
    ensure(list->get_Size(&count), "counting the scheduled toasts");
    for (unsigned i = 0; i < count; ++i) {
        ComPtr<wun::IScheduledToastNotification> scheduled;
        ensure(list->GetAt(i, scheduled.GetAddressOf()), "reading a scheduled toast");
        ComPtr<wun::IScheduledToastNotification2> tagged;
        ensure(scheduled.As(&tagged), "getting IScheduledToastNotification2");
        HSTRING raw;
        ensure(tagged->get_Tag(&raw), "reading a scheduled toast's tag");
        UINT32 length;
        const wchar_t* text = WindowsGetStringRawBuffer(raw, &length);
        bool same = std::wstring_view(text, length) == tag;
        WindowsDeleteString(raw);
        if (same) ensure(notifier->RemoveFromSchedule(scheduled.Get()), "unscheduling a toast");
    }
}

int64_t nowMs() {
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    ULARGE_INTEGER ticks;
    ticks.LowPart = now.dwLowDateTime;
    ticks.HighPart = now.dwHighDateTime;
    // 100 ns ticks since 1601 to milliseconds since 1970.
    return static_cast<int64_t>(ticks.QuadPart / 10000) - 11644473600000;
}

}  // namespace

void startNotifications() {
    static bool started;
    if (started) return;
    started = true;
    // The package's manifest declares its app and the activator.
    if (!packaged) {
        std::wstring app = std::wstring(L"Software\\Classes\\AppUserModelId\\") + kAppId;
        setRegistryValue(app, L"DisplayName", L"ompanion");
        setRegistryValue(app, L"IconUri", exePath.substr(0, exePath.find_last_of(L'\\')) + L"\\app_icon.ico");
        setRegistryValue(app, L"CustomActivator", kActivatorId);
        setRegistryValue(std::wstring(L"Software\\Classes\\CLSID\\") + kActivatorId + L"\\LocalServer32", nullptr,
                         L"\"" + exePath + L"\"");
    }
    DWORD cookie;
    warn(CoRegisterClassObject(kActivator, &activatorFactory, CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &cookie),
         "registering the toast activator");
}

void notify(const Toast& toast) {
    ComPtr<wun::IToastNotifier> toasts = notifier();
    unschedule(toasts.Get(), tag(toast.id));
    ComPtr<wun::IToastNotification> notification;
    ensure(factory<wun::IToastNotificationFactory>(RuntimeClass_Windows_UI_Notifications_ToastNotification)
               ->CreateToastNotification(content(toast).Get(), notification.GetAddressOf()),
           "creating a toast");
    ComPtr<wun::IToastNotification2> tagged;
    ensure(notification.As(&tagged), "getting IToastNotification2");
    ensure(tagged->put_Tag(HString(tag(toast.id)).get()), "tagging a toast");
    ensure(tagged->put_Group(HString(kGroup).get()), "grouping a toast");
    ensure(toasts->Show(notification.Get()), "showing a toast");
}

void schedule(const Toast& toast, int64_t atMs) {
    // Windows schedules nothing in the past.
    if (atMs <= nowMs()) {
        notify(toast);
        return;
    }
    ComPtr<wun::IToastNotifier> toasts = notifier();
    unschedule(toasts.Get(), tag(toast.id));
    ABI::Windows::Foundation::DateTime at;
    at.UniversalTime = (atMs + 11644473600000) * 10000;  // 100 ns ticks since 1601
    ComPtr<wun::IScheduledToastNotification> notification;
    ensure(factory<wun::IScheduledToastNotificationFactory>(RuntimeClass_Windows_UI_Notifications_ScheduledToastNotification)
               ->CreateScheduledToastNotification(content(toast).Get(), at, notification.GetAddressOf()),
           "creating a scheduled toast");
    ComPtr<wun::IScheduledToastNotification2> tagged;
    ensure(notification.As(&tagged), "getting IScheduledToastNotification2");
    ensure(tagged->put_Tag(HString(tag(toast.id)).get()), "tagging a scheduled toast");
    ensure(tagged->put_Group(HString(kGroup).get()), "grouping a scheduled toast");
    ensure(toasts->AddToSchedule(notification.Get()), "scheduling a toast");
}

void cancelNotification(const std::string& id) {
    unschedule(notifier().Get(), tag(id));
    ComPtr<wun::IToastNotificationManagerStatics2> statics2;
    ensure(manager().As(&statics2), "getting IToastNotificationManagerStatics2");
    ComPtr<wun::IToastNotificationHistory> history;
    ensure(statics2->get_History(history.GetAddressOf()), "getting the toast history");
    ensure(packaged ? history->RemoveGroupedTag(HString(tag(id)).get(), HString(kGroup).get())
                    : history->RemoveGroupedTagWithId(HString(tag(id)).get(), HString(kGroup).get(),
                                                      HString(kAppId).get()),
           "removing a toast");
}
