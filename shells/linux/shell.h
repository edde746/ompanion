// What the window and page (main.cpp) and the shell services (services.cpp) share.
#pragma once

#include <gtk/gtk.h>
#include <webkit/webkit.h>

#include <filesystem>
#include <stdexcept>
#include <string>

inline constexpr const char *kAppId = "com.edde746.ompanion";
inline constexpr const char *kStartUri = "app://ompanion/index.html";

struct Shell {
    std::filesystem::path ui;     // the page's files, served as app://ompanion/
    std::filesystem::path cache;  // the core's cache directory, served as app://ompanion/cache/
    // The app icon for notifications: its file URI, or inside a Flatpak the icon name the Flatpak exports to the host,
    // whose notification server cannot read the sandbox's files.
    std::string notificationIcon;
    GtkWindow *window = nullptr;
    // Cleared by a weak pointer once the view is gone: messages for the page after that are dropped.
    WebKitWebView *view = nullptr;
    GDBusConnection *bus = nullptr;  // the session bus; null when there is none
};

extern Shell shell;

// A request the shell cannot carry out; its message becomes the error the page gets.
struct RequestError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// main.cpp

// The page now loaded, counted from 0; a message for an earlier one is dropped. Any thread may ask.
unsigned pageGeneration();
// Hands one bridge message (JSON text) to the page.
void sendToPage(const char *message);
// The same, but held until the page has sent its first message when no page listens yet.
void sendWhenListening(const char *message);
// The file behind app://ompanion/<path>: cache/<name> from the core's cache directory, any other path from ui/.
struct Served {
    std::filesystem::path path;
    bool cached;
};
// Throws RequestError for another host or a path outside the served folders.
Served servedFile(const char *uri);

// services.cpp

// The shell's JSON is read and written by a JavaScriptCore context of its own, made on first use; nothing of the page
// runs in it.
JSCContext *json();
// The object `text` holds, or nullptr when it is not JSON or not an object.
JSCValue *jsonParse(const char *text);
// Answers `message` when it is a shell.* request; false when it is not one.
bool answerShellRequest(const char *message);
// Subscribes to the notification server's signals: taps and closes.
void watchNotifications();
gboolean onRunFileChooser(WebKitWebView *view, WebKitFileChooserRequest *request, gpointer);
// Takes files dragged onto the view from other apps for the page's shell.drag and shell.drop events.
void watchFileDrops(WebKitWebView *view);
