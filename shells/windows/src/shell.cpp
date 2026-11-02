#include "shell.h"

#include "app.h"
#include "flutter_data.h"
#include "json.h"
#include "notifications.h"
#include "secrets.h"
#include "util.h"

#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cctype>
#include <cstring>
#include <deque>
#include <iterator>
#include <optional>
#include <stdexcept>

using Microsoft::WRL::ComPtr;

// CMakeLists.txt defines APP_VERSION and APP_BUILD unquoted.
#define TEXT_OF_(x) #x
#define TEXT_OF(x) TEXT_OF_(x)

namespace {

std::deque<std::string> requests;
unsigned page;  // counts the pages forgetShellRequests saw go: a reply goes only to the page that asked
bool panelOpen;  // a save or open panel is open
std::optional<bool> appActive;

const Json& param(const Json& params, std::string_view key, Json::Kind kind) {
    const Json* value = params.find(key);
    if (!value || value->kind != kind) throw std::runtime_error("missing or invalid param " + std::string(key));
    return *value;
}

const std::string& text(const Json& params, std::string_view key) {
    return param(params, key, Json::Kind::String).string;
}

// An optional boolean param: absent is false.
bool flag(const Json& params, std::string_view key) {
    const Json* value = params.find(key);
    return value && value->kind == Json::Kind::Bool && value->boolean;
}

std::string info() {
    // The manifest's supportedOS entry makes GetVersionEx report Windows 10 and 11 as they are.
    OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof version;
    if (!GetVersionExW(&version)) ensure(lastError(), "reading the Windows version");
    // The DNS host name: the app names the local machine and new keys after it.
    wchar_t host[256];
    DWORD length = std::size(host);
    if (!GetComputerNameExW(ComputerNameDnsHostname, host, &length)) ensure(lastError(), "reading the host name");
    std::string osVersion = std::to_string(version.dwMajorVersion) + "." + std::to_string(version.dwMinorVersion) +
                            "." + std::to_string(version.dwBuildNumber);
    return R"({"platform":"windows","osVersion":)" + quote(osVersion) + R"(,"appVersion":)" +
           quote(TEXT_OF(APP_VERSION)) + R"(,"build":)" + quote(TEXT_OF(APP_BUILD)) + R"(,"device":)" +
           quote(narrow(std::wstring_view(host, length))) + R"(,"push":false,"paths":true})";
}

// Anything with a scheme of two or more characters: "C:\…" is a path. ShellExecute runs a program a file: URL names, so
// those are refused.
void openUrl(const std::string& url) {
    size_t colon = url.find(':');
    bool scheme = colon != std::string::npos && colon >= 2 && std::isalpha(static_cast<unsigned char>(url[0]));
    for (size_t i = 1; scheme && i < colon; ++i) {
        unsigned char c = url[i];
        scheme = std::isalnum(c) || c == '+' || c == '-' || c == '.';
    }
    if (!scheme || _strnicmp(url.c_str(), "file:", 5) == 0) throw std::runtime_error("not a URL to open: " + url);
    auto opened = reinterpret_cast<INT_PTR>(
        ShellExecuteW(window, L"open", widen(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL));
    if (opened <= 32) throw std::runtime_error("opening " + url + " failed: " + std::to_string(opened));
}

// The clipboard, open while this lives. It has one owner at a time, and clipboard managers hold it for moments.
class Clipboard {
public:
    Clipboard() {
        bool opened = false;
        for (int attempt = 0; attempt < 5 && !opened; ++attempt) {
            if (attempt > 0) Sleep(20);
            opened = OpenClipboard(window);
        }
        if (!opened) ensure(lastError(), "opening the clipboard");
    }
    ~Clipboard() { CloseClipboard(); }
    Clipboard(const Clipboard&) = delete;
    Clipboard& operator=(const Clipboard&) = delete;
};

void clipboardWrite(const std::string& text) {
    // Text on the Windows clipboard ends its lines with CR LF: classic edit controls show a lone LF as no break.
    std::wstring wide;
    for (wchar_t c : widen(text)) {
        if (c == L'\n' && (wide.empty() || wide.back() != L'\r')) wide += L'\r';
        wide += c;
    }
    Clipboard clipboard;
    if (!EmptyClipboard()) ensure(lastError(), "emptying the clipboard");
    size_t bytes = (wide.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!memory) ensure(lastError(), "allocating the clipboard's text");
    void* target = GlobalLock(memory);
    if (!target) {
        HRESULT error = lastError();
        GlobalFree(memory);
        ensure(error, "locking the clipboard's text");
    }
    std::memcpy(target, wide.c_str(), bytes);
    GlobalUnlock(memory);
    if (!SetClipboardData(CF_UNICODETEXT, memory)) {
        HRESULT error = lastError();
        GlobalFree(memory);
        ensure(error, "writing the clipboard");
    }
}

// Adds path to a JSON array's items.
void appendPath(std::string& items, std::wstring_view path) {
    if (!items.empty()) items += ',';
    items += quote(narrow(path));
}

// The files and folders copied in Explorer (CF_HDROP).
std::string clipboardFiles() {
    Clipboard clipboard;
    std::string paths;
    if (IsClipboardFormatAvailable(CF_HDROP)) {
        auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
        if (!drop) ensure(lastError(), "reading the clipboard's files");
        UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < count; ++i) {
            std::wstring path(DragQueryFileW(drop, i, nullptr, 0), L'\0');
            DragQueryFileW(drop, i, path.data(), static_cast<UINT>(path.size() + 1));
            appendPath(paths, path);
        }
    }
    return R"({"paths":[)" + paths + "]}";
}

// The open panel for files or a folder; no paths when the user cancelled.
std::string pickFiles(bool directory, bool multiple, const std::string& startIn) {
    if (panelOpen) throw std::runtime_error("a file panel is already open");
    ComPtr<IFileOpenDialog> dialog;
    ensure(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(dialog.GetAddressOf())),
           "creating the open panel");
    FILEOPENDIALOGOPTIONS options;
    ensure(dialog->GetOptions(&options), "reading the open panel's options");
    options |= FOS_FORCEFILESYSTEM;
    if (directory) options |= FOS_PICKFOLDERS;
    if (multiple) options |= FOS_ALLOWMULTISELECT;
    ensure(dialog->SetOptions(options), "setting the open panel's options");
    if (!startIn.empty()) {
        ComPtr<IShellItem> folder;
        // A start folder that is not there leaves the panel where it was last.
        std::wstring folderPath = widen(startIn);
        if (SUCCEEDED(SHCreateItemFromParsingName(folderPath.c_str(), nullptr, IID_PPV_ARGS(folder.GetAddressOf()))))
            ensure(dialog->SetFolder(folder.Get()), "setting the open panel's folder");
    }
    panelOpen = true;
    HRESULT shown = dialog->Show(window);
    panelOpen = false;
    if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return R"({"paths":[]})";
    ensure(shown, "showing the open panel");
    ComPtr<IShellItemArray> items;
    ensure(dialog->GetResults(items.GetAddressOf()), "reading the chosen files");
    DWORD count;
    ensure(items->GetCount(&count), "counting the chosen files");
    std::string paths;
    for (DWORD i = 0; i < count; ++i) {
        ComPtr<IShellItem> item;
        ensure(items->GetItemAt(i, item.GetAddressOf()), "reading a chosen file");
        LPWSTR raw;
        ensure(item->GetDisplayName(SIGDN_FILESYSPATH, &raw), "reading a chosen file's path");
        appendPath(paths, take(raw));
    }
    return R"({"paths":[)" + paths + "]}";
}

// The file url names on the page's origin, written where the user chooses. False when the user cancelled.
bool saveFile(const std::string& name, const std::string& url) {
    if (panelOpen) throw std::runtime_error("a file panel is already open");
    std::wstring absolute = widen(url);
    if (!absolute.starts_with(kOrigin)) absolute = kOrigin + absolute;
    std::optional<ServedFile> source = servedFile(absolute);
    if (!source || GetFileAttributesW(source->path.c_str()) == INVALID_FILE_ATTRIBUTES)
        throw std::runtime_error("no file at " + url);

    ComPtr<IFileSaveDialog> dialog;
    ensure(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(dialog.GetAddressOf())),
           "creating the save panel");
    std::wstring fileName = widen(name);
    ensure(dialog->SetFileName(fileName.c_str()), "naming the file");
    // Keeps the extension when the user types a name without one.
    size_t dot = fileName.rfind(L'.');
    if (dot != std::wstring::npos && dot + 1 < fileName.size())
        ensure(dialog->SetDefaultExtension(fileName.c_str() + dot + 1), "setting the file's extension");
    panelOpen = true;
    HRESULT shown = dialog->Show(window);
    panelOpen = false;
    if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return false;
    ensure(shown, "showing the save panel");
    ComPtr<IShellItem> item;
    ensure(dialog->GetResult(item.GetAddressOf()), "reading the chosen file");
    LPWSTR raw;
    ensure(item->GetDisplayName(SIGDN_FILESYSPATH, &raw), "reading the chosen file's path");
    std::wstring destination = take(raw);
    if (!CopyFileW(source->path.c_str(), destination.c_str(), FALSE))
        ensure(lastError(), "copying " + url + " to " + narrow(destination));
    return true;
}

Toast toast(const Json& params) {
    const Json* subtitle = params.find("subtitle");
    const Json* data = params.find("data");
    return Toast{
        .id = text(params, "id"),
        .title = text(params, "title"),
        .subtitle = subtitle && subtitle->kind == Json::Kind::String ? subtitle->string : "",
        .body = text(params, "body"),
        .data = data ? std::string(data->raw) : "null",
    };
}

// The request's result as JSON text; throws for its error.
std::string handle(const std::string& method, const Json& params) {
    if (method == "shell.info") return info();
    if (method == "shell.secretGet") {
        std::optional<std::string> value = secretGet(text(params, "key"));
        return value ? R"({"value":)" + quote(*value) + "}" : R"({"value":null})";
    }
    if (method == "shell.secretSet") {
        secretSet(text(params, "key"), text(params, "value"));
        return "{}";
    }
    if (method == "shell.secretDelete") {
        secretDelete(text(params, "key"));
        return "{}";
    }
    if (method == "shell.openUrl") {
        openUrl(text(params, "url"));
        return "{}";
    }
    if (method == "shell.clipboardWrite") {
        clipboardWrite(text(params, "text"));
        return "{}";
    }
    if (method == "shell.notify") {
        notify(toast(params));
        return "{}";
    }
    if (method == "shell.notifySchedule") {
        schedule(toast(params), static_cast<int64_t>(param(params, "atMs", Json::Kind::Number).number));
        return "{}";
    }
    if (method == "shell.notifyCancel") {
        cancelNotification(text(params, "id"));
        return "{}";
    }
    // Windows asks no permission: the user turns an app's notifications off in Settings.
    if (method == "shell.notifyPermission") return R"({"granted":true})";
    if (method == "shell.saveFile")
        return saveFile(text(params, "name"), text(params, "url")) ? R"({"saved":true})" : R"({"saved":false})";
    if (method == "shell.pickFiles") {
        const Json* startIn = params.find("startIn");
        return pickFiles(flag(params, "directory"), flag(params, "multiple"),
                         startIn && startIn->kind == Json::Kind::String ? startIn->string : "");
    }
    if (method == "shell.clipboardFiles") return clipboardFiles();
    if (method == "shell.flutterData") return flutterData();
    if (method == "shell.flutterDataClear") {
        flutterDataClear();
        return "{}";
    }
    if (method == "shell.insets") return R"({"top":0,"right":0,"bottom":0,"left":0,"keyboard":0})";
    // The page's startup stages (docs/contracts/bridge.md): a Windows GUI app has no stderr to log them to.
    if (method == "shell.timing") return "{}";
    throw std::runtime_error(method + " is not available on Windows");
}

}  // namespace

bool takeShellRequest(std::string& message) {
    // Only a message that names shell. at all is parsed: most are not shell requests, and some are megabytes.
    if (message.find("\"shell.") == std::string::npos) return false;
    std::optional<Json> request = parseJson(message);
    const Json* method = request ? request->find("method") : nullptr;
    if (!method || method->kind != Json::Kind::String || !method->string.starts_with("shell.")) return false;
    if (requests.empty() && !PostMessageW(window, kShellRequests, 0, 0)) fail("waking the UI thread", lastError());
    requests.push_back(std::move(message));
    return true;
}

void runShellRequests() {
    static const Json none;
    // A save panel's nested message loop runs this again: each request leaves the queue before it is handled.
    while (!requests.empty()) {
        std::string message = std::move(requests.front());
        requests.pop_front();
        unsigned asked = page;
        Json request = *parseJson(message);
        const Json* id = request.find("id");
        const Json* params = request.find("params");
        std::string reply = "{\"id\":" + std::string(id ? id->raw : "null") + ",";
        try {
            reply += "\"result\":" + handle(request.find("method")->string, params ? *params : none) + "}";
        } catch (const std::exception& error) {
            reply += R"("error":{"message":)" + quote(error.what()) + "}}";
        }
        if (asked == page) postToPage(reply);
    }
}

void forgetShellRequests() {
    requests.clear();
    ++page;
}

void sendAppState(bool active) {
    if (appActive == active) return;
    appActive = active;
    postToPage(std::string(R"({"event":"shell.appState","params":{"active":)") + (active ? "true" : "false") + "}}");
}
