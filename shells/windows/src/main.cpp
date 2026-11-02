// The Windows shell: a Win32 window hosting WebView2. It serves ui\ next to the exe and the core's cache directory as
// https://app.ompanion/, wires the page to the Go core in libompcore.dll and answers the page's shell.* requests
// (docs/contracts/bridge.md).
#include "app.h"
#include "json.h"
#include "notifications.h"
#include "shell.h"
#include "util.h"

#include <appmodel.h>
#include <dwmapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <wrl/client.h>

#include <WebView2.h>
#include <libompcore.h>

#include <algorithm>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <deque>
#include <mutex>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;

HWND window;
std::wstring exePath;
std::wstring dataFolder;
bool packaged;

namespace {

constexpr wchar_t kStartUrl[] = L"https://app.ompanion/index.html";
// The window's default and minimum size, in pixels at 96 DPI; the Linux and macOS shells match.
constexpr int kWidth = 1280;
constexpr int kHeight = 800;
constexpr int kMinWidth = 360;
constexpr int kMinHeight = 480;

std::wstring uiFolder;
std::wstring cacheFolder;
std::wstring userDataFolder;
ComPtr<ICoreWebView2Environment> environment;
ComPtr<ICoreWebView2Controller> controller;
ComPtr<ICoreWebView2> webview;

std::mutex outboxMutex;
std::deque<std::wstring> outbox;  // messages the core emitted, for the UI thread

bool pageListening;                     // the page has sent a message since it last started loading
bool pageStarted;                       // a page has started loading in this process
std::vector<std::string> waitingForPage;  // postWhenListening's messages until then

// Startup milestones for smoke runs' `shell timing` line, in ms since the process started; -1 until reached.
uint64_t startTicks;  // the process's creation time, in 100 ns ticks
struct {
    double webviewMs = -1;
    double domContentLoadedMs = -1;
    double coreInfoMs = -1;
    bool written = false;
} timing;
std::string awaitedCoreInfo;  // the id of the page's first core.info request until its answer passes

// A WebView2 handler object around a function: what WRL's Callback does, which llvm-mingw's WRL lacks.
template <class Interface, class... Args>
class Handler final : public Interface {
public:
    Handler(const IID& iid, HRESULT (*invoke)(Args...)) : iid_(iid), invoke_(invoke) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
        if (riid == iid_ || riid == IID_IUnknown) {
            AddRef();
            *object = this;
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG left = --references_;
        if (left == 0) delete this;
        return left;
    }
    HRESULT STDMETHODCALLTYPE Invoke(Args... args) override { return invoke_(args...); }

private:
    const IID& iid_;
    ULONG references_ = 1;  // WebView2 calls handlers on the UI thread only
    HRESULT (*invoke_)(Args...);
};

template <class Interface, class... Args>
ComPtr<Interface> handler(const IID& iid, HRESULT (*invoke)(Args...)) {
    ComPtr<Interface> object;
    object.Attach(new Handler<Interface, Args...>(iid, invoke));
    return object;
}

// QueryInterface with the IID spelled out: mingw has no __uuidof for WebView2's interfaces, so ComPtr::As cannot link.
template <class Interface>
HRESULT query(IUnknown* object, const IID& iid, ComPtr<Interface>& result) {
    return object->QueryInterface(iid, reinterpret_cast<void**>(result.ReleaseAndGetAddressOf()));
}

uint64_t ticks(FILETIME time) { return (static_cast<uint64_t>(time.dwHighDateTime) << 32) | time.dwLowDateTime; }

double msSinceStart() {
    FILETIME now;
    GetSystemTimePreciseAsFileTime(&now);
    return static_cast<double>(ticks(now) - startTicks) / 1e4;
}

// The core appends its lines to the same file: both open it only to append one line.
void appendToCoreLog(const std::string& line) {
    const wchar_t* path = _wgetenv(L"OMPCORE_LOG");
    if (!path) return;
    HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        warn(lastError(), "opening OMPCORE_LOG");
        return;
    }
    std::string text = line + "\n";
    DWORD written;
    if (!WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr))
        warn(lastError(), "writing OMPCORE_LOG");
    CloseHandle(file);
}

void writeTiming() {
    if (!smoke || timing.written || timing.webviewMs < 0 || timing.domContentLoadedMs < 0 || timing.coreInfoMs < 0)
        return;
    timing.written = true;
    char line[160];
    std::snprintf(line, sizeof line, R"(shell timing {"webviewMs":%.1f,"domContentLoadedMs":%.1f,"coreInfoMs":%.1f})",
                  timing.webviewMs, timing.domContentLoadedMs, timing.coreInfoMs);
    log(line);
    appendToCoreLog(line);
}

void noteCoreInfoRequest(const std::string& message) {
    if (timing.coreInfoMs >= 0 || !awaitedCoreInfo.empty() || message.find("\"core.info\"") == std::string::npos)
        return;
    std::optional<Json> request = parseJson(message);
    const Json* method = request ? request->find("method") : nullptr;
    const Json* id = request ? request->find("id") : nullptr;
    if (method && method->string == "core.info" && id) awaitedCoreInfo = id->raw;
}

void noteCoreInfoAnswer(const std::wstring& message) {
    std::string text = narrow(message);
    std::optional<Json> answer = parseJson(text);
    const Json* id = answer ? answer->find("id") : nullptr;
    if (!id || id->raw != awaitedCoreInfo) return;
    awaitedCoreInfo.clear();
    timing.coreInfoMs = msSinceStart();
    writeTiming();
}

// Runs on a core goroutine's thread: copies the message and wakes the UI thread when the outbox was empty.
void emit(const char* message, void*) {
    std::wstring text = widen(message);
    bool wake;
    {
        std::lock_guard lock(outboxMutex);
        wake = outbox.empty();
        outbox.push_back(std::move(text));
    }
    if (wake && !PostMessageW(window, kCoreMessages, 0, 0)) fail("waking the UI thread", lastError());
}

void deliver() {
    std::deque<std::wstring> messages;
    {
        std::lock_guard lock(outboxMutex);
        messages.swap(outbox);
    }
    // Without a page, the messages are dropped (docs/contracts/bridge.md, Shells).
    if (!webview) return;
    for (const std::wstring& message : messages) {
        warn(webview->PostWebMessageAsJson(message.c_str()), "posting a message to the page");
        if (!awaitedCoreInfo.empty()) noteCoreInfoAnswer(message);
    }
}

// The system's app mode (Settings, Personalization, Colors), which the page follows too.
bool systemDark() {
    DWORD light;
    DWORD size = sizeof light;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size) != ERROR_SUCCESS)
        return false;  // no value: Windows' default, light
    return light == 0;
}

// The title bar, the window and the webview take the theme's background (ui/src/app/palette.ts), so neither the start
// nor a resize shows a white flash in dark mode.
void applyTheme() {
    BOOL dark = systemDark();
    warn(DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark), "setting the title bar's theme");
    SetClassLongPtrW(window, GCLP_HBRBACKGROUND,
                     reinterpret_cast<LONG_PTR>(GetStockObject(dark ? BLACK_BRUSH : WHITE_BRUSH)));
    ComPtr<ICoreWebView2Controller2> controller2;
    if (controller && SUCCEEDED(query(controller.Get(), IID_ICoreWebView2Controller2, controller2))) {
        COREWEBVIEW2_COLOR background = dark ? COREWEBVIEW2_COLOR{255, 0, 0, 0} : COREWEBVIEW2_COLOR{255, 255, 255, 255};
        warn(controller2->put_DefaultBackgroundColor(background), "setting the webview's background");
    }
}

void resize() {
    if (!controller) return;
    RECT bounds;
    GetClientRect(window, &bounds);
    check(controller->put_Bounds(bounds), "resizing the webview");
}

std::optional<std::string> percentDecoded(std::string_view text) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] != '%') {
            out += text[i];
            continue;
        }
        if (i + 2 >= text.size()) return std::nullopt;
        unsigned byte;
        const char* end = text.data() + i + 3;
        auto [stop, error] = std::from_chars(text.data() + i + 1, end, byte, 16);
        if (error != std::errc() || stop != end) return std::nullopt;
        out += static_cast<char>(byte);
        i += 2;
    }
    return out;
}

const wchar_t* mimeType(std::wstring_view path) {
    static constexpr std::pair<std::wstring_view, const wchar_t*> types[] = {
        {L".html", L"text/html; charset=utf-8"},
        {L".js", L"text/javascript; charset=utf-8"},
        {L".mjs", L"text/javascript; charset=utf-8"},
        {L".css", L"text/css; charset=utf-8"},
        {L".json", L"application/json"},
        {L".map", L"application/json"},
        {L".txt", L"text/plain; charset=utf-8"},
        {L".md", L"text/markdown; charset=utf-8"},
        {L".svg", L"image/svg+xml"},
        {L".png", L"image/png"},
        {L".jpg", L"image/jpeg"},
        {L".jpeg", L"image/jpeg"},
        {L".gif", L"image/gif"},
        {L".webp", L"image/webp"},
        {L".avif", L"image/avif"},
        {L".bmp", L"image/bmp"},
        {L".ico", L"image/x-icon"},
        {L".woff2", L"font/woff2"},
        {L".woff", L"font/woff"},
        {L".ttf", L"font/ttf"},
        {L".otf", L"font/otf"},
        {L".wasm", L"application/wasm"},
        {L".pdf", L"application/pdf"},
        {L".mp4", L"video/mp4"},
        {L".webm", L"video/webm"},
        {L".mov", L"video/quicktime"},
        {L".mp3", L"audio/mpeg"},
        {L".m4a", L"audio/mp4"},
        {L".wav", L"audio/wav"},
        {L".ogg", L"audio/ogg"},
    };
    size_t dot = path.rfind(L'.');
    if (dot != std::wstring_view::npos) {
        std::wstring extension(path.substr(dot));
        for (wchar_t& c : extension)
            if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
        for (const auto& [suffix, type] : types)
            if (extension == suffix) return type;
    }
    return L"application/octet-stream";
}

HRESULT onWebResourceRequested(ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) {
    ComPtr<ICoreWebView2WebResourceRequest> request;
    check(args->get_Request(&request), "reading a resource request");
    LPWSTR raw;
    check(request->get_Uri(&raw), "reading a resource request's URI");
    std::wstring uri = take(raw);
    std::optional<ServedFile> file = servedFile(uri);
    ComPtr<IStream> stream;
    HRESULT opened = file ? SHCreateStreamOnFileEx(file->path.c_str(), STGM_READ | STGM_SHARE_DENY_NONE,
                                                   FILE_ATTRIBUTE_NORMAL, FALSE, nullptr, &stream)
                          : HRESULT_FROM_WIN32(ERROR_BAD_PATHNAME);
    ComPtr<ICoreWebView2WebResourceResponse> response;
    if (SUCCEEDED(opened)) {
        std::wstring headers = std::wstring(L"Content-Type: ") + mimeType(file->path);
        // Cache files are whatever the user downloaded: a document among them runs sandboxed, without scripts or the
        // app's origin. no-cache: the core may write a new file under an old name.
        if (file->cache)
            headers += L"\r\nCache-Control: no-cache\r\nContent-Security-Policy: sandbox\r\nX-Content-Type-Options: nosniff";
        check(environment->CreateWebResourceResponse(stream.Get(), 200, L"OK", headers.c_str(), &response),
              "creating a resource response");
    } else {
        log("404 for " + narrow(uri) + ": " + hex(opened));
        check(environment->CreateWebResourceResponse(nullptr, 404, L"Not Found", L"", &response),
              "creating a 404 response");
    }
    check(args->put_Response(response.Get()), "answering a resource request");
    return S_OK;
}

// File drops (docs/contracts/bridge.md, desktop file paths). WebView2 is the window's drop target and the page sees no
// paths, so this script, which runs before the page's own in every document, takes the drags that carry files and
// posts the dropped File objects to the shell, which reads their paths (onDropMessage). Other drags, such as text,
// stay the page's.
constexpr wchar_t kDropScript[] = LR"js((() => {
  if (window !== window.top || !window.chrome?.webview) return;
  const post = (kind) => chrome.webview.postMessage(`{"shellDrop":"${kind}"}`);
  const carriesFiles = (event) => event.dataTransfer?.types.includes("Files");
  let depth = 0; // dragenter and dragleave come for every element the drag crosses
  addEventListener("dragenter", (event) => {
    if (!carriesFiles(event)) return;
    event.preventDefault();
    if (depth++ === 0) post("enter");
  }, true);
  addEventListener("dragover", (event) => {
    if (!carriesFiles(event)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "copy";
  }, true);
  addEventListener("dragleave", (event) => {
    if (carriesFiles(event) && depth > 0 && --depth === 0) post("leave");
  }, true);
  addEventListener("drop", (event) => {
    if (!carriesFiles(event)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    depth = 0;
    chrome.webview.postMessageWithAdditionalObjects('{"shellDrop":"files"}', event.dataTransfer.files);
  }, true);
})();)js";

// kDropScript's message: shell.drag, and for a drop shell.drop with the paths of the files and folders it carried.
// A drop of files without paths (an image dragged out of a web page) gives no shell.drop.
void onDropMessage(std::string_view kind, ICoreWebView2WebMessageReceivedEventArgs* args) {
    if (kind != "files") {
        postToPage(std::string(R"({"event":"shell.drag","params":{"active":)") + (kind == "enter" ? "true" : "false") +
                   "}}");
        return;
    }
    ComPtr<ICoreWebView2WebMessageReceivedEventArgs2> args2;
    check(query(args, IID_ICoreWebView2WebMessageReceivedEventArgs2, args2),
          "getting ICoreWebView2WebMessageReceivedEventArgs2 (the WebView2 Runtime is too old)");
    ComPtr<ICoreWebView2ObjectCollectionView> objects;
    check(args2->get_AdditionalObjects(&objects), "reading a drop's files");
    UINT32 count;
    check(objects->get_Count(&count), "counting a drop's files");
    std::string paths;
    for (UINT32 i = 0; i < count; ++i) {
        ComPtr<IUnknown> object;
        ComPtr<ICoreWebView2File> file;
        check(objects->GetValueAtIndex(i, &object), "reading a dropped file");
        if (FAILED(query(object.Get(), IID_ICoreWebView2File, file))) continue;
        LPWSTR raw;
        check(file->get_Path(&raw), "reading a dropped file's path");
        std::wstring path = take(raw);
        if (path.empty()) continue;
        paths += (paths.empty() ? "" : ",") + quote(narrow(path));
    }
    postToPage(R"({"event":"shell.drag","params":{"active":false}})");
    if (!paths.empty()) postToPage(R"({"event":"shell.drop","params":{"paths":[)" + paths + "]}}");
}

HRESULT onWebMessage(ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) {
    LPWSTR raw;
    check(args->get_Source(&raw), "reading a web message's source");
    std::wstring source = take(raw);
    if (!source.starts_with(kOrigin)) {
        log("dropped a message from " + narrow(source));
        return S_OK;
    }
    if (FAILED(args->TryGetWebMessageAsString(&raw))) {
        log("dropped a message that is not text");
        return S_OK;
    }
    std::string message = narrow(take(raw));
    constexpr std::string_view dropPrefix = R"({"shellDrop":")";
    if (message.starts_with(dropPrefix)) {
        onDropMessage(std::string_view(message).substr(dropPrefix.size(), message.size() - dropPrefix.size() - 2), args);
        return S_OK;
    }
    if (smoke) noteCoreInfoRequest(message);
    if (!takeShellRequest(message)) OmpCoreSend(message.data());
    if (!pageListening) {
        pageListening = true;
        for (const std::string& waiting : waitingForPage) postToPage(waiting);
        waitingForPage.clear();
    }
    return S_OK;
}

HRESULT onNavigationStarting(ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) {
    LPWSTR raw;
    check(args->get_Uri(&raw), "reading a navigation's URI");
    std::wstring uri = take(raw);
    if (uri.starts_with(kOrigin)) {
        pageListening = false;
        // A new page: Start again makes the core release what the old one opened (docs/contracts/bridge.md, Core
        // bindings). This covers every way a page comes again: the reload after a render process failed, a recreated
        // webview, and the page's own reload.
        if (pageStarted) {
            OmpCoreStart(emit, nullptr);
            // What is still queued answers the old page, whose ids the new one reuses. Clearing it here is exact:
            // Start returns after the core's last emit to the old page, and the new page has asked nothing yet.
            {
                std::lock_guard lock(outboxMutex);
                outbox.clear();
            }
            forgetShellRequests();
        }
        pageStarted = true;
        return S_OK;
    }
    log("blocked a navigation to " + narrow(uri));
    check(args->put_Cancel(TRUE), "cancelling a navigation");
    return S_OK;
}

HRESULT onDomContentLoaded(ICoreWebView2*, ICoreWebView2DOMContentLoadedEventArgs*) {
    if (timing.domContentLoadedMs < 0) {
        timing.domContentLoadedMs = msSinceStart();
        writeTiming();
    }
    // After the first load, which it need not delay; before a toast the app was launched for can be clicked.
    startNotifications();
    return S_OK;
}

HRESULT onNewWindowRequested(ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) {
    LPWSTR raw;
    check(args->get_Uri(&raw), "reading a new window's URI");
    std::wstring uri = take(raw);
    // Handled: WebView2 opens no window of its own.
    check(args->put_Handled(TRUE), "handling a new window");
    if (!uri.starts_with(L"https://") && !uri.starts_with(L"http://")) {
        log("blocked a new window for " + narrow(uri));
        return S_OK;
    }
    auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(window, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
    if (opened <= 32) log("opening " + narrow(uri) + " in the browser failed: " + std::to_string(opened));
    return S_OK;
}

HRESULT onProcessFailed(ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs* args) {
    COREWEBVIEW2_PROCESS_FAILED_KIND kind;
    check(args->get_ProcessFailedKind(&kind), "reading a failed process's kind");
    switch (kind) {
    case COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED:
        log("the WebView2 browser process exited: recreating the webview");
        // Out of this callback: the handler belongs to the webview it replaces.
        if (!PostMessageW(window, kRecreate, 0, 0)) fail("posting the webview's recreation", lastError());
        break;
    case COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED:
    case COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_UNRESPONSIVE:
        log("the page's render process failed (kind " + std::to_string(kind) + "): reloading");
        check(webview->Reload(), "reloading the page");
        break;
    default:
        log("a WebView2 process failed (kind " + std::to_string(kind) + ")");
        break;
    }
    return S_OK;
}

HRESULT onController(HRESULT result, ICoreWebView2Controller* created) {
    check(result, "creating the WebView2 controller");
    controller = created;
    check(controller->get_CoreWebView2(&webview), "getting the webview");
    timing.webviewMs = msSinceStart();
    applyTheme();
    resize();

    ComPtr<ICoreWebView2Settings> settings;
    check(webview->get_Settings(&settings), "getting the webview's settings");
    // An app, not a browser: no link preview in the corner, no reload, find or print keys.
    check(settings->put_IsStatusBarEnabled(FALSE), "turning the status bar off");
    ComPtr<ICoreWebView2Settings3> settings3;
    check(query(settings.Get(), IID_ICoreWebView2Settings3, settings3),
          "getting ICoreWebView2Settings3 (the WebView2 Runtime is too old)");
    check(settings3->put_AreBrowserAcceleratorKeysEnabled(FALSE), "turning the browser's keys off");

    // The page and its cache files come from WebResourceRequested, not SetVirtualHostNameToFolderMapping: WebView2
    // raises no WebResourceRequested for a virtual host, and cache/ must share the page's origin.
    check(webview->AddWebResourceRequestedFilter(L"https://app.ompanion/*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL),
          "filtering app.ompanion's requests");

    // The handlers live as long as the webview: their tokens are never needed.
    EventRegistrationToken token;
    check(webview->add_WebResourceRequested(
              handler<ICoreWebView2WebResourceRequestedEventHandler>(IID_ICoreWebView2WebResourceRequestedEventHandler,
                                                                     onWebResourceRequested)
                  .Get(),
              &token),
          "adding WebResourceRequested");
    check(webview->add_WebMessageReceived(
              handler<ICoreWebView2WebMessageReceivedEventHandler>(IID_ICoreWebView2WebMessageReceivedEventHandler,
                                                                   onWebMessage)
                  .Get(),
              &token),
          "adding WebMessageReceived");
    check(webview->add_NavigationStarting(
              handler<ICoreWebView2NavigationStartingEventHandler>(IID_ICoreWebView2NavigationStartingEventHandler,
                                                                   onNavigationStarting)
                  .Get(),
              &token),
          "adding NavigationStarting");
    ComPtr<ICoreWebView2_2> webview2;
    check(query(webview.Get(), IID_ICoreWebView2_2, webview2), "getting ICoreWebView2_2 (the WebView2 Runtime is too old)");
    check(webview2->add_DOMContentLoaded(
              handler<ICoreWebView2DOMContentLoadedEventHandler>(IID_ICoreWebView2DOMContentLoadedEventHandler,
                                                                 onDomContentLoaded)
                  .Get(),
              &token),
          "adding DOMContentLoaded");
    check(webview->add_NewWindowRequested(
              handler<ICoreWebView2NewWindowRequestedEventHandler>(IID_ICoreWebView2NewWindowRequestedEventHandler,
                                                                   onNewWindowRequested)
                  .Get(),
              &token),
          "adding NewWindowRequested");
    check(webview->add_ProcessFailed(
              handler<ICoreWebView2ProcessFailedEventHandler>(IID_ICoreWebView2ProcessFailedEventHandler, onProcessFailed)
                  .Get(),
              &token),
          "adding ProcessFailed");
    // Added before the first navigation, so it runs in the first document too.
    check(webview->AddScriptToExecuteOnDocumentCreated(kDropScript, nullptr), "adding the file drop script");
    check(webview->Navigate(kStartUrl), "opening the page");
    return S_OK;
}

HRESULT onEnvironment(HRESULT result, ICoreWebView2Environment* created) {
    check(result, "creating the WebView2 environment");
    environment = created;
    check(environment->CreateCoreWebView2Controller(
              window, handler<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                          IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, onController)
                          .Get()),
          "starting the WebView2 controller");
    return S_OK;
}

// Asynchronous: the environment and the controller arrive through the message loop, so the window can be created
// while WebView2 starts its browser process.
void createWebView() {
    check(CreateCoreWebView2EnvironmentWithOptions(
              nullptr, userDataFolder.c_str(), nullptr,
              handler<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                  IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, onEnvironment)
                  .Get()),
          "starting WebView2 (is the WebView2 Runtime installed?)");
}

void closeWebView() {
    if (!controller) return;
    warn(controller->Close(), "closing the webview");
    webview.Reset();
    controller.Reset();
    environment.Reset();
}

LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_SIZE:
        resize();
        // A minimized app's page stops rendering, as WebView2 recommends.
        if (controller) warn(controller->put_IsVisible(wParam != SIZE_MINIMIZED), "showing or hiding the webview");
        return 0;
    case WM_MOVE:
        if (controller) warn(controller->NotifyParentWindowPositionChanged(), "telling the webview the window moved");
        return 0;
    case WM_SETFOCUS:
        if (controller) warn(controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC), "focusing the webview");
        return 0;
    // The app, not just this window: the app's own save panel does not send the page to the back.
    case WM_ACTIVATEAPP:
        sendAppState(wParam != FALSE);
        return 0;
    case WM_GETMINMAXINFO: {
        UINT dpi = GetDpiForWindow(hwnd);
        auto* limits = reinterpret_cast<MINMAXINFO*>(lParam);
        limits->ptMinTrackSize = {MulDiv(kMinWidth, dpi, 96), MulDiv(kMinHeight, dpi, 96)};
        return 0;
    }
    case WM_DPICHANGED: {
        const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_SETTINGCHANGE:
        if (lParam && std::wstring_view(reinterpret_cast<const wchar_t*>(lParam)) == L"ImmersiveColorSet") applyTheme();
        break;
    case kCoreMessages:
        deliver();
        return 0;
    case kShellRequests:
        runShellRequests();
        return 0;
    case kRecreate:
        closeWebView();
        createWebView();
        return 0;
    case WM_DESTROY:
        closeWebView();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

// The default size, centred on the window's monitor.
void placeWindow() {
    UINT dpi = GetDpiForWindow(window);
    MONITORINFO monitor{};
    monitor.cbSize = sizeof monitor;
    if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
        log("reading the window's monitor failed: the window keeps its default place");
        return;
    }
    const RECT& work = monitor.rcWork;
    int width = std::min<int>(MulDiv(kWidth, dpi, 96), work.right - work.left);
    int height = std::min<int>(MulDiv(kHeight, dpi, 96), work.bottom - work.top);
    SetWindowPos(window, nullptr, work.left + (work.right - work.left - width) / 2,
                 work.top + (work.bottom - work.top - height) / 2, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
}

std::wstring modulePath() {
    std::wstring path(MAX_PATH, L'\0');
    for (;;) {
        DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
        if (length == 0) fail("reading the exe's path", lastError());
        if (length < path.size()) {
            path.resize(length);
            return path;
        }
        path.resize(path.size() * 2);
    }
}

std::wstring localAppData() {
    PWSTR raw;
    check(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &raw), "finding %LOCALAPPDATA%");
    return take(raw);
}

}  // namespace

std::optional<ServedFile> servedFile(std::wstring_view url) {
    if (!url.starts_with(kOrigin)) return std::nullopt;
    std::wstring_view rest = url.substr(std::wstring_view(kOrigin).size());
    rest = rest.substr(0, rest.find_first_of(L"?#"));
    std::optional<std::string> decoded = percentDecoded(narrow(rest));
    if (!decoded) return std::nullopt;
    std::wstring path = decoded->empty() ? L"index.html" : widen(*decoded);
    // Plain names only: nothing that climbs out of the folder, names a drive, a stream or a device, or is no file name.
    if (std::any_of(path.begin(), path.end(), [](wchar_t c) { return c < 0x20 || std::wcschr(L"\\:*?\"<>|", c); }))
        return std::nullopt;
    for (size_t start = 0;;) {
        size_t end = path.find(L'/', start);
        std::wstring_view segment = std::wstring_view(path).substr(start, end - start);
        if (segment.empty() || segment == L"." || segment == L"..") return std::nullopt;
        if (end == std::wstring::npos) break;
        start = end + 1;
    }
    bool cache = path.starts_with(L"cache/");
    std::wstring relative = cache ? path.substr(6) : path;
    std::replace(relative.begin(), relative.end(), L'/', L'\\');
    return ServedFile{(cache ? cacheFolder : uiFolder) + L"\\" + relative, cache};
}

void postToPage(std::string_view message) {
    if (!webview) return;
    warn(webview->PostWebMessageAsJson(widen(message).c_str()), "posting a message to the page");
}

void postWhenListening(std::string message) {
    if (pageListening) {
        postToPage(message);
    } else {
        waitingForPage.push_back(std::move(message));
    }
}

void bringToFront() {
    if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
    if (!SetForegroundWindow(window)) log("bringing the window to the front failed");
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
    const wchar_t* smokeVariable = _wgetenv(L"OMPCORE_SMOKE");
    smoke = smokeVariable && std::wstring_view(smokeVariable) == L"1";
    FILETIME created, exited, kernel, user;
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user))
        fail("reading the process's start time", lastError());
    startTicks = ticks(created);
    check(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED), "initializing COM");
    UINT32 packageNameLength = 0;
    packaged = GetCurrentPackageFullName(&packageNameLength, nullptr) != APPMODEL_ERROR_NO_PACKAGE;
    // Before any window: the taskbar groups the app's windows and toasts under it. A packaged app has its package's.
    if (!packaged) check(SetCurrentProcessExplicitAppUserModelID(kAppId), "setting the AppUserModelID");

    exePath = modulePath();
    uiFolder = exePath.substr(0, exePath.find_last_of(L'\\')) + L"\\ui";
    if (GetFileAttributesW((uiFolder + L"\\index.html").c_str()) == INVALID_FILE_ATTRIBUTES)
        fail("finding " + narrow(uiFolder) + "\\index.html", lastError());
    dataFolder = localAppData() + L"\\" + kAppId;
    cacheFolder = dataFolder + L"\\cache";
    userDataFolder = dataFolder + L"\\WebView2";
    // The core makes both folders when it first needs them.
    std::string dataDir = narrow(dataFolder);
    std::string cacheDir = narrow(cacheFolder);
    OmpCoreSetEnv(const_cast<char*>("OMPCORE_DATA_DIR"), dataDir.data());
    OmpCoreSetEnv(const_cast<char*>("OMPCORE_CACHE_DIR"), cacheDir.data());

    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof windowClass;
    windowClass.lpfnWndProc = windowProc;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
    windowClass.lpszClassName = L"Ompanion";
    if (!RegisterClassExW(&windowClass)) fail("registering the window class", lastError());
    window = CreateWindowExW(0, windowClass.lpszClassName, L"ompanion", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                             CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, nullptr, nullptr, instance, nullptr);
    if (!window) fail("creating the window", lastError());
    // After the window: the environment can arrive before CreateWindowExW returns (seen on Windows Server 2025), and
    // the controller needs the window.
    createWebView();
    applyTheme();
    placeWindow();
    ShowWindow(window, show);

    OmpCoreStart(emit, nullptr);

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return static_cast<int>(message.wParam);
}
