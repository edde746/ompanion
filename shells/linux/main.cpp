// The Linux shell: one GTK 4 window holding a WebKitGTK 6 web view that serves ui/ (next to the binary) and the core's
// cache directory as app://ompanion/, wires the page to the Go core, and answers the page's shell.* requests itself
// (services.cpp). Contract: docs/contracts/bridge.md.
#include "shell.h"

#include <unistd.h>

#include <atomic>
#include <cstring>
#include <ctime>
#include <format>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// The cgo header carries the binding's static C helper, which this file never calls.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include "libompcore.h"
#pragma GCC diagnostic pop

Shell shell;

namespace {

constexpr std::string_view kReceive = "window.ompCore.receive(";
constexpr std::string_view kCachePrefix = "/cache/";
constexpr const char *kPortal = "org.freedesktop.portal.Desktop";
constexpr const char *kPortalPath = "/org/freedesktop/portal/desktop";
constexpr const char *kPortalSettings = "org.freedesktop.portal.Settings";
constexpr const char *kAppearance = "org.freedesktop.appearance";

std::filesystem::path dataDir;
std::filesystem::path iconDir;

// Counts committed pages; a message for an earlier page is dropped, since its ids mean nothing to the next one. Core
// threads read it in emit.
std::atomic<unsigned> page = 0;

// Whether the loaded page has sent its first message; messages held for it until then (notification taps).
bool pageListening = false;
std::vector<std::string> held;

// Launch timing of a smoke run, in milliseconds since the process started, written once all three are known
// (docs/contracts/bridge.md, Smoke runs).
struct Timing {
    double startMs = 0;  // the process's start on CLOCK_BOOTTIME
    double webviewMs = -1;
    double domContentLoadedMs = -1;
    double coreInfoMs = -1;
    std::optional<double> infoId;  // the id of the page's first core.info request
};

std::optional<Timing> timing;

double bootTimeMs() {
    timespec now{};
    clock_gettime(CLOCK_BOOTTIME, &now);
    return static_cast<double>(now.tv_sec) * 1e3 + static_cast<double>(now.tv_nsec) / 1e6;
}

// The kernel's start time of this process (/proc/self/stat field 22, clock ticks since boot), so loading the
// libraries and the Go runtime before main counts too.
double processStartMs() {
    g_autofree char *stat = nullptr;
    g_autoptr(GError) error = nullptr;
    if (!g_file_get_contents("/proc/self/stat", &stat, nullptr, &error)) {
        g_error("reading /proc/self/stat: %s", error->message);
    }
    // Field 2, the command, is in parentheses and may hold spaces: field 3 starts after the last ')'.
    std::istringstream fields(strrchr(stat, ')') + 1);
    std::string skipped;
    for (int field = 3; field < 22; ++field) {
        fields >> skipped;
    }
    unsigned long long ticks = 0;
    fields >> ticks;
    return static_cast<double>(ticks) * 1e3 / static_cast<double>(sysconf(_SC_CLK_TCK));
}

void mark(double Timing::*moment) {
    if ((*timing).*moment >= 0) {
        return;
    }
    (*timing).*moment = bootTimeMs() - timing->startMs;
    if (timing->webviewMs < 0 || timing->domContentLoadedMs < 0 || timing->coreInfoMs < 0) {
        return;
    }
    const std::string line =
        std::format("shell timing {{\"webviewMs\":{:.1f},\"domContentLoadedMs\":{:.1f},\"coreInfoMs\":{:.1f}}}",
                    timing->webviewMs, timing->domContentLoadedMs, timing->coreInfoMs);
    g_printerr("%s\n", line.c_str());
    if (const char *path = g_getenv("OMPCORE_LOG")) {
        std::ofstream log(path, std::ios::app);
        log << line << '\n';
        if (!log) {
            g_warning("writing the timing line to %s failed", path);
        }
    }
}

// Notes the id of the page's first core.info request, whose answer ends the timing.
void noteInfoRequest(const char *message) {
    g_autoptr(JSCValue) request = jsonParse(message);
    if (!request) {
        return;
    }
    g_autoptr(JSCValue) method = jsc_value_object_get_property(request, "method");
    g_autoptr(JSCValue) id = jsc_value_object_get_property(request, "id");
    g_autofree char *name = jsc_value_is_string(method) ? jsc_value_to_string(method) : nullptr;
    if (g_strcmp0(name, "core.info") == 0 && jsc_value_is_number(id)) {
        timing->infoId = jsc_value_to_double(id);
    }
}

bool answersInfo(const std::string &script) {
    const std::string message = script.substr(kReceive.size(), script.size() - kReceive.size() - 1);
    g_autoptr(JSCValue) response = jsonParse(message.c_str());
    if (!response) {
        return false;
    }
    g_autoptr(JSCValue) id = jsc_value_object_get_property(response, "id");
    return jsc_value_is_number(id) && jsc_value_to_double(id) == *timing->infoId;
}

void onTimingMessage(WebKitUserContentManager *, JSCValue *, gpointer) {
    mark(&Timing::domContentLoadedMs);
}

const char *mimeType(const std::filesystem::path &file, GFileInfo *info) {
    static constexpr std::pair<std::string_view, const char *> types[] = {
        {".html", "text/html"},       {".js", "text/javascript"},   {".mjs", "text/javascript"},
        {".css", "text/css"},         {".json", "application/json"}, {".map", "application/json"},
        {".svg", "image/svg+xml"},    {".png", "image/png"},         {".jpg", "image/jpeg"},
        {".jpeg", "image/jpeg"},      {".gif", "image/gif"},         {".webp", "image/webp"},
        {".ico", "image/x-icon"},     {".woff", "font/woff"},        {".woff2", "font/woff2"},
        {".ttf", "font/ttf"},         {".otf", "font/otf"},          {".wasm", "application/wasm"},
        {".txt", "text/plain"},
    };
    const std::string extension = file.extension().string();
    for (const auto &[suffix, type] : types) {
        if (extension == suffix) {
            return type;
        }
    }
    // Any other file (the cache holds what machines and the web sent): GIO's guess from its name and first bytes.
    return g_file_info_get_content_type(info);
}

bool isPage(const char *uri) {
    g_autoptr(GUri) parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, nullptr);
    return parsed && g_strcmp0(g_uri_get_scheme(parsed), "app") == 0 &&
           g_strcmp0(g_uri_get_host(parsed), "ompanion") == 0;
}

bool hasScheme(const char *uri, const char *scheme) {
    return g_strcmp0(g_uri_peek_scheme(uri), scheme) == 0;
}

void failRequest(WebKitURISchemeRequest *request, GError *error) {
    g_warning("app: %s: %s", webkit_uri_scheme_request_get_uri(request), error->message);
    webkit_uri_scheme_request_finish_error(request, error);
}

// Serves app://ompanion/<path> (servedFile).
void serve(WebKitURISchemeRequest *request, gpointer) {
    const char *uri = webkit_uri_scheme_request_get_uri(request);
    Served served;
    try {
        served = servedFile(uri);
    } catch (const RequestError &refused) {
        g_autoptr(GError) error = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, refused.what());
        failRequest(request, error);
        return;
    }
    g_autoptr(GError) error = nullptr;
    g_autoptr(GFile) file = g_file_new_for_path(served.path.c_str());
    g_autoptr(GFileInfo) info =
        g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_SIZE "," G_FILE_ATTRIBUTE_STANDARD_CONTENT_TYPE,
                          G_FILE_QUERY_INFO_NONE, nullptr, &error);
    g_autoptr(GFileInputStream) stream = info ? g_file_read(file, nullptr, &error) : nullptr;
    if (!stream) {
        failRequest(request, error);
        return;
    }
    g_autoptr(WebKitURISchemeResponse) response =
        webkit_uri_scheme_response_new(G_INPUT_STREAM(stream), g_file_info_get_size(info));
    const char *type = mimeType(served.path, info);
    webkit_uri_scheme_response_set_content_type(response, type);
    // Without headers a response's Content-Type is invisible to fetch(), unlike over HTTP.
    SoupMessageHeaders *headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    soup_message_headers_replace(headers, "Content-Type", type);
    if (served.cached) {
        // Cache files come from machines and the web: a document among them must not run as the app. The core may
        // write a name again.
        soup_message_headers_replace(headers, "Content-Security-Policy", "sandbox");
        soup_message_headers_replace(headers, "X-Content-Type-Options", "nosniff");
        soup_message_headers_replace(headers, "Cache-Control", "no-cache");
    }
    webkit_uri_scheme_response_set_http_headers(response, headers);
    webkit_uri_scheme_request_finish_with_response(request, response);
}

void onEvaluated(GObject *view, GAsyncResult *result, gpointer) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(view), result, &error);
    if (!value) {
        g_warning("core: delivering a message to the page: %s", error->message);
    }
}

void evaluate(const std::string &script) {
    if (shell.view) {
        webkit_web_view_evaluate_javascript(shell.view, script.data(), static_cast<gssize>(script.size()), nullptr,
                                            nullptr, nullptr, onEvaluated, nullptr);
    }
}

// A core message on its way to the page, and the page it was emitted for.
struct Delivery {
    std::string script;
    unsigned page;
};

gboolean deliver(gpointer data) {
    const auto &delivery = *static_cast<const Delivery *>(data);
    if (delivery.page != pageGeneration()) {
        return G_SOURCE_REMOVE;
    }
    if (timing && timing->infoId && timing->coreInfoMs < 0 && answersInfo(delivery.script)) {
        mark(&Timing::coreInfoMs);
    }
    evaluate(delivery.script);
    return G_SOURCE_REMOVE;
}

// Runs on a core goroutine's thread; message is valid only during the call.
void emit(const char *message, void *) {
    auto *delivery = new Delivery{std::string(kReceive).append(message).append(")"), pageGeneration()};
    g_main_context_invoke_full(nullptr, G_PRIORITY_DEFAULT, deliver, delivery,
                               [](gpointer data) { delete static_cast<Delivery *>(data); });
}

void onScriptMessage(WebKitUserContentManager *, JSCValue *value, gpointer) {
    if (!jsc_value_is_string(value)) {
        g_warning("core: dropped a page message that is not text");
        return;
    }
    g_autofree char *message = jsc_value_to_string(value);
    if (timing && !timing->infoId && strstr(message, "\"core.info\"")) {
        noteInfoRequest(message);
    }
    // Only a message holding "shell. can be a shell request: the core's traffic passes unparsed.
    if (!strstr(message, "\"shell.") || !answerShellRequest(message)) {
        OmpCoreSend(message);
    }
    if (!pageListening) {
        pageListening = true;
        for (const std::string &waiting : held) {
            sendToPage(waiting.c_str());
        }
        held.clear();
    }
}

void onLaunched(GObject *launcher, GAsyncResult *result, gpointer) {
    g_autoptr(GError) error = nullptr;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(launcher), result, &error)) {
        g_warning("opening a link: %s", error->message);
    }
}

void openExternally(const char *uri) {
    g_autoptr(GtkUriLauncher) launcher = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(launcher, shell.window, nullptr, onLaunched, nullptr);
}

// Only app://ompanion runs in the main frame. Subframes may also hold about: documents; the agent-HTML iframe loads
// app://ompanion/frame.html. Navigation actions carry no frame, so they admit both; the response decision, which
// knows the main frame, keeps other pages out of it, and onLoadChanged catches about: pages, which have no response.
gboolean decidePolicy(WebKitWebView *, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, gpointer) {
    if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
        auto *response = WEBKIT_RESPONSE_POLICY_DECISION(decision);
        const char *uri = webkit_uri_request_get_uri(webkit_response_policy_decision_get_request(response));
        if (isPage(uri) ||
            (!webkit_response_policy_decision_is_main_frame_main_resource(response) && hasScheme(uri, "about"))) {
            return FALSE;
        }
        g_warning("navigation: blocked loading %s", uri);
        webkit_policy_decision_ignore(decision);
        return TRUE;
    }
    WebKitNavigationAction *action =
        webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
    const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
    if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION && (isPage(uri) || hasScheme(uri, "about"))) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }
    webkit_policy_decision_ignore(decision);
    if ((hasScheme(uri, "https") || hasScheme(uri, "http")) && webkit_navigation_action_is_user_gesture(action)) {
        openExternally(uri);
    } else {
        g_warning("navigation: blocked %s", uri);
    }
    return TRUE;
}

// Every page that commits, whether after a crashed web process, the page's own reload or a navigation back to the
// app, starts the core again: that releases the streams and machines the old page opened, whose ids the new one never
// knows (docs/contracts/bridge.md, Core bindings). At commit the old document has stopped running, so nothing of it
// follows. Start returns after the core's last message for the old page; whatever of that is still queued is dropped.
// On the first load there is nothing to release.
void onLoadChanged(WebKitWebView *view, WebKitLoadEvent event, gpointer) {
    if (event != WEBKIT_LOAD_COMMITTED) {
        return;
    }
    pageListening = false;
    OmpCoreStart(emit, nullptr);
    ++page;
    if (!isPage(webkit_web_view_get_uri(view))) {
        g_warning("navigation: %s reached the main frame; loading the app again", webkit_web_view_get_uri(view));
        webkit_web_view_load_uri(view, kStartUri);
    }
}

void onWebProcessTerminated(WebKitWebView *view, WebKitWebProcessTerminationReason reason, gpointer) {
    g_warning("web process terminated (reason %d); reloading", reason);
    webkit_web_view_reload(view);
}

// Dropped until the page has sent its first message: before that nothing in it listens.
void onActiveChanged(GtkWindow *window, GParamSpec *, gpointer) {
    if (!pageListening) {
        return;
    }
    const std::string event =
        std::format("{{\"event\":\"shell.appState\",\"params\":{{\"active\":{}}}}}", gtk_window_is_active(window) != 0);
    sendToPage(event.c_str());
}

// Appearance. WebKit takes the page's prefers-color-scheme from GTK's settings (prefer-dark, or a "-dark" theme), and
// GTK before 4.20 does not follow the desktop's dark style by itself: the shell reads it from the settings portal. The
// web view's background is the theme's (design.md: black, or white in light), so nothing flashes before the page
// paints.

// WebKit's own rule for GTK before 4.20 (SystemSettingsManagerProxyGtk.cpp).
bool darkAppearance() {
    gboolean preferDark = FALSE;
    g_autofree char *theme = nullptr;
    g_object_get(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &preferDark, "gtk-theme-name",
                 &theme, nullptr);
    const std::string_view name = theme ? theme : "";
    const std::string_view forced = g_getenv("GTK_THEME") ? g_getenv("GTK_THEME") : "";
    return preferDark || (forced.empty() ? name.ends_with("-dark") || name.ends_with("-Dark")
                                         : forced.ends_with("-dark") || forced.ends_with("-Dark") ||
                                               forced.ends_with(":dark"));
}

void paintBackground() {
    const float level = darkAppearance() ? 0 : 1;
    const GdkRGBA background = {level, level, level, 1};
    if (shell.view) {
        webkit_web_view_set_background_color(shell.view, &background);
    }
}

void onAppearanceChanged(GtkSettings *, GParamSpec *, gpointer) {
    paintBackground();
}

// The portal's color-scheme: 1 prefers dark, 2 prefers light, 0 has no preference.
void setColorScheme(GVariant *value) {
    if (g_variant_is_of_type(value, G_VARIANT_TYPE_UINT32)) {
        g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", g_variant_get_uint32(value) == 1,
                     nullptr);
    }
}

void onSettingsRead(GObject *bus, GAsyncResult *result, gpointer) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) returned = g_dbus_connection_call_finish(G_DBUS_CONNECTION(bus), result, &error);
    if (!returned) {
        g_message("settings portal: %s; colors follow GTK's theme", error->message);
        return;
    }
    g_autoptr(GVariant) namespaces = g_variant_get_child_value(returned, 0);
    g_autoptr(GVariant) appearance = g_variant_lookup_value(namespaces, kAppearance, G_VARIANT_TYPE_VARDICT);
    g_autoptr(GVariant) scheme =
        appearance ? g_variant_lookup_value(appearance, "color-scheme", G_VARIANT_TYPE_UINT32) : nullptr;
    if (scheme) {
        setColorScheme(scheme);
    }
}

void onSettingChanged(GDBusConnection *, const char *, const char *, const char *, const char *, GVariant *parameters,
                      gpointer) {
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ssv)"))) {
        return;
    }
    const char *space = nullptr;
    const char *key = nullptr;
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(parameters, "(&s&sv)", &space, &key, &value);
    if (strcmp(space, kAppearance) == 0 && strcmp(key, "color-scheme") == 0) {
        setColorScheme(value);
    }
}

void followColorScheme() {
    g_dbus_connection_signal_subscribe(shell.bus, kPortal, kPortalSettings, "SettingChanged", kPortalPath, kAppearance,
                                       G_DBUS_SIGNAL_FLAGS_NONE, onSettingChanged, nullptr, nullptr);
    const char *namespaces[] = {kAppearance, nullptr};
    g_dbus_connection_call(shell.bus, kPortal, kPortalPath, kPortalSettings, "ReadAll",
                           g_variant_new("(^as)", namespaces), G_VARIANT_TYPE("(a{sa{sv}})"), G_DBUS_CALL_FLAGS_NONE,
                           -1, nullptr, onSettingsRead, nullptr);
    GtkSettings *settings = gtk_settings_get_default();
    g_signal_connect(settings, "notify::gtk-application-prefer-dark-theme", G_CALLBACK(onAppearanceChanged), nullptr);
    g_signal_connect(settings, "notify::gtk-theme-name", G_CALLBACK(onAppearanceChanged), nullptr);
}

// The page starts loading before the window is built; the core already runs (main).
void activate(GtkApplication *app, gpointer) {
    g_autoptr(GError) error = nullptr;
    shell.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (shell.bus) {
        followColorScheme();
    } else {
        g_warning("no session bus: %s", error->message);
    }

    WebKitWebContext *context = webkit_web_context_get_default();
    webkit_web_context_register_uri_scheme(context, "app", serve, nullptr, nullptr);
    // Secure and CORS-enabled, so the page's ES modules load from app://.
    WebKitSecurityManager *security = webkit_web_context_get_security_manager(context);
    webkit_security_manager_register_uri_scheme_as_secure(security, "app");
    webkit_security_manager_register_uri_scheme_as_cors_enabled(security, "app");

    g_autoptr(WebKitUserContentManager) content = webkit_user_content_manager_new();
    g_signal_connect(content, "script-message-received::core", G_CALLBACK(onScriptMessage), nullptr);
    if (!webkit_user_content_manager_register_script_message_handler(content, "core", nullptr)) {
        g_error("registering the core script message handler failed");
    }
    if (timing) {
        g_signal_connect(content, "script-message-received::timing", G_CALLBACK(onTimingMessage), nullptr);
        if (!webkit_user_content_manager_register_script_message_handler(content, "timing", nullptr)) {
            g_error("registering the timing script message handler failed");
        }
        g_autoptr(WebKitUserScript) script = webkit_user_script_new(
            "document.addEventListener('DOMContentLoaded', () => "
            "window.webkit.messageHandlers.timing.postMessage(''), {once: true});",
            WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, nullptr, nullptr);
        webkit_user_content_manager_add_script(content, script);
    }
    // Persistent, so the page's localStorage (its first-frame snapshot) survives a restart.
    g_autoptr(WebKitNetworkSession) session =
        webkit_network_session_new((dataDir / "webkit").c_str(), (shell.cache / "webkit").c_str());

    auto *view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", context, "network-session", session,
                                              "user-content-manager", content, nullptr));
    shell.view = view;
    g_object_add_weak_pointer(G_OBJECT(view), reinterpret_cast<gpointer *>(&shell.view));
    if (timing) {
        mark(&Timing::webviewMs);
    }
    paintBackground();
    webkit_settings_set_enable_write_console_messages_to_stdout(webkit_web_view_get_settings(view), TRUE);
    g_signal_connect(view, "decide-policy", G_CALLBACK(decidePolicy), nullptr);
    g_signal_connect(view, "load-changed", G_CALLBACK(onLoadChanged), nullptr);
    g_signal_connect(view, "web-process-terminated", G_CALLBACK(onWebProcessTerminated), nullptr);
    g_signal_connect(view, "run-file-chooser", G_CALLBACK(onRunFileChooser), nullptr);
    watchFileDrops(view);
    webkit_web_view_load_uri(view, kStartUri);

    // The window: 1280 × 800, its content at least 360 × 480, in the desktop's own frame; Windows and macOS match.
    gtk_widget_set_size_request(GTK_WIDGET(view), 360, 480);
    gtk_icon_theme_add_search_path(gtk_icon_theme_get_for_display(gdk_display_get_default()), iconDir.c_str());
    gtk_window_set_default_icon_name(kAppId);
    shell.window = GTK_WINDOW(gtk_application_window_new(app));
    gtk_window_set_title(shell.window, "ompanion");
    gtk_window_set_default_size(shell.window, 1280, 800);
    gtk_window_set_child(shell.window, GTK_WIDGET(view));
    g_signal_connect(shell.window, "notify::is-active", G_CALLBACK(onActiveChanged), nullptr);
    if (shell.bus) {
        watchNotifications();
    }
    gtk_window_present(shell.window);
}

// One of the core's directories: the environment's, else <base>/com.edde746.ompanion, set for the core. Go copied the
// environment when libompcore.so loaded, so a setenv here would never reach it: OmpCoreSetEnv does.
std::filesystem::path coreDirectory(const char *variable, const char *base) {
    if (const char *set = g_getenv(variable)) {
        return std::filesystem::path(set).lexically_normal();
    }
    const std::filesystem::path directory = std::filesystem::path(base) / kAppId;
    // cgo declares the parameters char *; the core only reads them.
    OmpCoreSetEnv(const_cast<char *>(variable), const_cast<char *>(directory.c_str()));
    return directory;
}

}  // namespace

unsigned pageGeneration() {
    return page.load();
}

void sendToPage(const char *message) {
    evaluate(std::string(kReceive).append(message).append(")"));
}

void sendWhenListening(const char *message) {
    if (pageListening) {
        sendToPage(message);
    } else {
        held.emplace_back(message);
    }
}

Served servedFile(const char *uri) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GUri) parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, &error);
    if (!parsed) {
        throw RequestError(error->message);
    }
    if (g_strcmp0(g_uri_get_scheme(parsed), "app") != 0 || g_strcmp0(g_uri_get_host(parsed), "ompanion") != 0) {
        throw RequestError("not a file of the app");
    }
    std::string_view path = g_uri_get_path(parsed);
    const bool cached = path.starts_with(kCachePrefix);
    const std::filesystem::path &root = cached ? shell.cache : shell.ui;
    if (cached) {
        path.remove_prefix(kCachePrefix.size());
    }
    const std::filesystem::path file = (root / std::filesystem::path(path).relative_path()).lexically_normal();
    const std::filesystem::path inside = file.lexically_relative(root);
    if (inside.empty() || *inside.begin() == "..") {
        throw RequestError("outside the served folders");
    }
    return {file, cached};
}

int main(int argc, char **argv) {
    if (g_strcmp0(g_getenv("OMPCORE_SMOKE"), "1") == 0) {
        timing.emplace().startMs = processStartMs();
    }
    const std::filesystem::path bundle = std::filesystem::read_symlink("/proc/self/exe").parent_path();
    shell.ui = std::filesystem::canonical(bundle / "ui");
    iconDir = bundle / "icons";
    if (g_file_test("/.flatpak-info", G_FILE_TEST_EXISTS)) {
        shell.notificationIcon = kAppId;
    } else {
        g_autofree char *icon =
            g_filename_to_uri((iconDir / (std::string(kAppId) + ".png")).c_str(), nullptr, nullptr);
        shell.notificationIcon = icon;
    }
    dataDir = coreDirectory("OMPCORE_DATA_DIR", g_get_user_data_dir());
    shell.cache = coreDirectory("OMPCORE_CACHE_DIR", g_get_user_cache_dir());
    // The core starts before GTK, so it is ready by the time the page asks.
    OmpCoreStart(emit, nullptr);

    // The program name is the Wayland app id and the X11 WM_CLASS desktops match the app's .desktop file by.
    g_set_prgname(kAppId);
    g_autoptr(GtkApplication) app = gtk_application_new(kAppId, G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), nullptr);
    return g_application_run(G_APPLICATION(app), argc, argv);
}
