// What the window and webview code (main.cpp) offers the shell services.
#pragma once

#include <windows.h>

#include <optional>
#include <string>
#include <string_view>

constexpr UINT kCoreMessages = WM_APP;      // the core queued messages for the page
constexpr UINT kRecreate = WM_APP + 1;      // the browser process is gone: a new environment and controller
constexpr UINT kShellRequests = WM_APP + 2; // the page sent shell.* requests
constexpr wchar_t kOrigin[] = L"https://app.ompanion/";
// The AppUserModelID of the zip's unpackaged app, the data folder's name under %LOCALAPPDATA% and the prefix of the
// secrets' credentials. The MSIX package's app has the package's AppUserModelID instead.
constexpr wchar_t kAppId[] = L"com.edde746.ompanion";

extern HWND window;
extern std::wstring exePath;
extern std::wstring dataFolder;  // %LOCALAPPDATA%\com.edde746.ompanion, the core's OMPCORE_DATA_DIR
extern bool packaged;            // the app runs from its MSIX package, with the package's identity

// A file the page's origin serves: ui\ next to the exe, or under cache/ the core's cache directory.
struct ServedFile {
    std::wstring path;
    bool cache;
};
std::optional<ServedFile> servedFile(std::wstring_view url);

void postToPage(std::string_view message);

// For an event the page must not miss, such as the notification tap that launched the app: until the page has sent
// its first message, it waits for that.
void postWhenListening(std::string message);

void bringToFront();
