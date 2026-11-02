// The shell.* requests the shell answers itself (docs/contracts/bridge.md, Shell services), the file chooser behind
// the page's <input type=file>, and file drops.
#include "shell.h"

#include <libsecret/secret.h>

#include <algorithm>
#include <cstring>
#include <deque>
#include <initializer_list>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

JSCContext *context = nullptr;

// JSON values for the page. Each constructor returns a new reference.

JSCValue *jsonText(const char *text) {
    return text ? jsc_value_new_string(json(), text) : jsc_value_new_null(json());
}

JSCValue *jsonBool(bool value) {
    return jsc_value_new_boolean(json(), value);
}

JSCValue *jsonNumber(double value) {
    return jsc_value_new_number(json(), value);
}

// An object of `fields`; it takes over each value's reference.
JSCValue *jsonObject(std::initializer_list<std::pair<const char *, JSCValue *>> fields) {
    JSCValue *object = jsc_value_new_object(json(), nullptr, nullptr);
    for (const auto &[name, value] : fields) {
        jsc_value_object_set_property(object, name, value);
        g_object_unref(value);
    }
    return object;
}

// `items` as a null-terminated array of C strings, valid while `items` is.
std::vector<const char *> strv(const std::vector<std::string> &items) {
    std::vector<const char *> list;
    for (const std::string &item : items) {
        list.push_back(item.c_str());
    }
    list.push_back(nullptr);
    return list;
}

JSCValue *jsonStrings(const std::vector<std::string> &items) {
    return jsc_value_new_array_from_strv(json(), strv(items).data());
}

// `request` stands for a page's request until it is answered: {id, page}, the page it came from
// (answerShellRequest). An answer for an earlier page is dropped: its id may be one the next page uses.
void answerWith(JSCValue *request, const char *field, JSCValue *value) {
    g_autoptr(JSCValue) page = jsc_value_object_get_property(request, "page");
    g_autoptr(JSCValue) message = jsonObject({{"id", jsc_value_object_get_property(request, "id")}, {field, value}});
    if (static_cast<unsigned>(jsc_value_to_double(page)) != pageGeneration()) {
        return;
    }
    g_autofree char *text = jsc_value_to_json(message, 0);
    sendToPage(text);
}

// Takes over `result`'s reference.
void reply(JSCValue *request, JSCValue *result) {
    answerWith(request, "result", result);
}

void fail(JSCValue *request, const char *text) {
    answerWith(request, "error", jsonObject({{"message", jsonText(text)}}));
}

// Request params.

std::string text(JSCValue *params, const char *name) {
    g_autoptr(JSCValue) value = jsc_value_object_get_property(params, name);
    if (!jsc_value_is_string(value)) {
        throw RequestError(std::string(name) + " must be a string");
    }
    g_autofree char *chars = jsc_value_to_string(value);
    return chars;
}

// "" when the param is absent or null.
std::string optionalText(JSCValue *params, const char *name) {
    g_autoptr(JSCValue) value = jsc_value_object_get_property(params, name);
    return jsc_value_is_undefined(value) || jsc_value_is_null(value) ? std::string() : text(params, name);
}

double number(JSCValue *params, const char *name) {
    g_autoptr(JSCValue) value = jsc_value_object_get_property(params, name);
    if (!jsc_value_is_number(value)) {
        throw RequestError(std::string(name) + " must be a number");
    }
    return jsc_value_to_double(value);
}

// false when the param is absent or null.
bool flag(JSCValue *params, const char *name) {
    g_autoptr(JSCValue) value = jsc_value_object_get_property(params, name);
    if (jsc_value_is_undefined(value) || jsc_value_is_null(value)) {
        return false;
    }
    if (!jsc_value_is_boolean(value)) {
        throw RequestError(std::string(name) + " must be a boolean");
    }
    return jsc_value_to_boolean(value);
}

// The param as JSON text; "null" when it is absent.
std::string jsonParam(JSCValue *params, const char *name) {
    g_autoptr(JSCValue) value = jsc_value_object_get_property(params, name);
    g_autofree char *text = jsc_value_to_json(value, 0);
    return text ? text : "null";
}

// shell.info

void info(JSCValue *request) {
    g_autofree char *os = g_get_os_info(G_OS_INFO_KEY_PRETTY_NAME);
    reply(request, jsonObject({
                       {"platform", jsonText("linux")},
                       {"osVersion", jsonText(os)},
                       {"appVersion", jsonText(APP_VERSION)},
                       {"build", jsonText(APP_BUILD)},
                       {"device", jsonText(g_get_host_name())},
                       {"push", jsonBool(false)},
                       {"paths", jsonBool(true)},
                   }));
}

// shell.secret*: the desktop's secret service through libsecret, one item per key.

// The schema's reserved fields stay zero.
const SecretSchema kSecrets = [] {
    SecretSchema schema{};
    schema.name = kAppId;
    schema.flags = SECRET_SCHEMA_NONE;
    schema.attributes[0] = {"key", SECRET_SCHEMA_ATTRIBUTE_STRING};
    return schema;
}();

void onSecretRead(GObject *, GAsyncResult *result, gpointer data) {
    g_autoptr(JSCValue) request = JSC_VALUE(data);
    g_autoptr(GError) error = nullptr;
    char *value = secret_password_lookup_finish(result, &error);
    if (error) {
        fail(request, error->message);
        return;
    }
    reply(request, jsonObject({{"value", jsonText(value)}}));
    secret_password_free(value);
}

void onSecretStored(GObject *, GAsyncResult *result, gpointer data) {
    g_autoptr(JSCValue) request = JSC_VALUE(data);
    g_autoptr(GError) error = nullptr;
    if (!secret_password_store_finish(result, &error)) {
        fail(request, error->message);
        return;
    }
    reply(request, jsonObject({}));
}

void onSecretCleared(GObject *, GAsyncResult *result, gpointer data) {
    g_autoptr(JSCValue) request = JSC_VALUE(data);
    g_autoptr(GError) error = nullptr;
    // False without an error: there was no such secret, which is what delete wants.
    secret_password_clear_finish(result, &error);
    if (error) {
        fail(request, error->message);
        return;
    }
    reply(request, jsonObject({}));
}

void secretGet(JSCValue *request, JSCValue *params) {
    const std::string key = text(params, "key");
    secret_password_lookup(&kSecrets, nullptr, onSecretRead, g_object_ref(request), "key", key.c_str(), nullptr);
}

void secretSet(JSCValue *request, JSCValue *params) {
    const std::string key = text(params, "key");
    const std::string value = text(params, "value");
    const std::string label = "ompanion " + key;
    secret_password_store(&kSecrets, SECRET_COLLECTION_DEFAULT, label.c_str(), value.c_str(), nullptr, onSecretStored,
                          g_object_ref(request), "key", key.c_str(), nullptr);
}

void secretDelete(JSCValue *request, JSCValue *params) {
    const std::string key = text(params, "key");
    secret_password_clear(&kSecrets, nullptr, onSecretCleared, g_object_ref(request), "key", key.c_str(), nullptr);
}

// shell.flutterData, shell.flutterDataClear: what the Flutter app left (docs/contracts/bridge.md, Flutter data import).

// flutter_secure_storage_linux 3.0.3 keeps every entry in one item, a JSON object, with this attribute. The schema name
// it stores is a dangling pointer (Secret.hpp makes the schema from its label before renaming it), so the item is
// found by the attribute alone.
constexpr const char *kFlutterAccount = "com.edde746.ompanion.secureStorage";
const SecretSchema kFlutterSecrets = [] {
    SecretSchema schema{};
    schema.name = "flutter_secure_storage";
    schema.flags = SECRET_SCHEMA_DONT_MATCH_NAME;
    schema.attributes[0] = {"account", SECRET_SCHEMA_ATTRIBUTE_STRING};
    return schema;
}();

// The Flutter app's database: path_provider's application support directory, the app id's folder, else the one named
// after the executable (path_provider_linux 2.2.2). Empty when there is none.
std::filesystem::path flutterDatabase() {
    for (const char *folder : {kAppId, "ompanion"}) {
        const std::filesystem::path file = std::filesystem::path(g_get_user_data_dir()) / folder / "ompanion.sqlite";
        if (g_file_test(file.c_str(), G_FILE_TEST_IS_REGULAR)) {
            return file;
        }
    }
    return {};
}

void onFlutterSecretsRead(GObject *, GAsyncResult *result, gpointer data) {
    g_autoptr(JSCValue) request = JSC_VALUE(data);
    g_autoptr(GError) error = nullptr;
    char *stored = secret_password_lookup_finish(result, &error);
    if (error) {
        fail(request, error->message);
        return;
    }
    // The plugin reads an empty item as no entries.
    g_autoptr(JSCValue) entries = stored && *stored ? jsonParse(stored) : jsonObject({});
    secret_password_free(stored);
    if (!entries || jsc_value_is_array(entries)) {
        fail(request, "the Flutter app's secure storage item is not a JSON object");
        return;
    }
    g_autoptr(JSCValue) secrets = jsonObject({});
    g_auto(GStrv) keys = jsc_value_object_enumerate_properties(entries);
    for (char **key = keys; key && *key; ++key) {
        g_autoptr(JSCValue) value = jsc_value_object_get_property(entries, *key);
        // The plugin writes strings only, and reads anything else as no value.
        if (jsc_value_is_string(value)) {
            jsc_value_object_set_property(secrets, *key, value);
        }
    }
    const std::filesystem::path database = flutterDatabase();
    reply(request, jsonObject({
                       {"database", jsonText(database.empty() ? nullptr : database.c_str())},
                       {"secrets", static_cast<JSCValue *>(g_steal_pointer(&secrets))},
                   }));
}

void flutterData(JSCValue *request) {
    secret_password_lookup(&kFlutterSecrets, nullptr, onFlutterSecretsRead, g_object_ref(request), "account",
                           kFlutterAccount, nullptr);
}

// The database and its journal files keep their content as ompanion.sqlite.imported, …-wal.imported: the user's
// backup.
void flutterDataClear(JSCValue *request) {
    if (const std::filesystem::path database = flutterDatabase(); !database.empty()) {
        for (const char *suffix : {"", "-journal", "-wal", "-shm"}) {
            const std::string file = database.string() + suffix;
            std::error_code error;
            std::filesystem::rename(file, file + ".imported", error);
            if (error && error != std::errc::no_such_file_or_directory) {
                throw RequestError("renaming " + file + ": " + error.message());
            }
        }
    }
    secret_password_clear(&kFlutterSecrets, nullptr, onSecretCleared, g_object_ref(request), "account",
                          kFlutterAccount, nullptr);
}

// shell.openUrl, shell.clipboardWrite

void onUrlOpened(GObject *launcher, GAsyncResult *result, gpointer data) {
    g_autoptr(JSCValue) request = JSC_VALUE(data);
    g_autoptr(GError) error = nullptr;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(launcher), result, &error)) {
        fail(request, error->message);
        return;
    }
    reply(request, jsonObject({}));
}

void openUrl(JSCValue *request, JSCValue *params) {
    const std::string url = text(params, "url");
    g_autoptr(GtkUriLauncher) launcher = gtk_uri_launcher_new(url.c_str());
    gtk_uri_launcher_launch(launcher, shell.window, nullptr, onUrlOpened, g_object_ref(request));
}

void clipboardWrite(JSCValue *request, JSCValue *params) {
    const std::string value = text(params, "text");
    gdk_clipboard_set_text(gtk_widget_get_clipboard(GTK_WIDGET(shell.window)), value.c_str());
    reply(request, jsonObject({}));
}

// shell.saveFile

// A saveFile request while its panel is open and its copy runs.
struct Save {
    JSCValue *request;
    GFile *source;

    ~Save() {
        g_object_unref(request);
        g_object_unref(source);
    }
};

void onSaved(GObject *source, GAsyncResult *result, gpointer data) {
    const std::unique_ptr<Save> save(static_cast<Save *>(data));
    g_autoptr(GError) error = nullptr;
    if (!g_file_copy_finish(G_FILE(source), result, &error)) {
        fail(save->request, error->message);
        return;
    }
    reply(save->request, jsonObject({{"saved", jsonBool(true)}}));
}

void onSaveChosen(GObject *dialog, GAsyncResult *result, gpointer data) {
    std::unique_ptr<Save> save(static_cast<Save *>(data));
    g_autoptr(GError) error = nullptr;
    g_autoptr(GFile) target = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(dialog), result, &error);
    if (!target) {
        if (g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) {
            reply(save->request, jsonObject({{"saved", jsonBool(false)}}));
        } else {
            fail(save->request, error->message);
        }
        return;
    }
    // Read before release(): the order a call's arguments are evaluated in is unspecified.
    GFile *source = save->source;
    g_file_copy_async(source, target, G_FILE_COPY_OVERWRITE, G_PRIORITY_DEFAULT, nullptr, nullptr, nullptr, onSaved,
                      save.release());
}

void saveFile(JSCValue *request, JSCValue *params) {
    const std::string name = text(params, "name");
    const std::string url = text(params, "url");
    g_autoptr(GError) error = nullptr;
    g_autofree char *absolute = g_uri_resolve_relative(kStartUri, url.c_str(), G_URI_FLAGS_NONE, &error);
    if (!absolute) {
        throw RequestError(error->message);
    }
    const std::filesystem::path file = servedFile(absolute).path;
    if (!g_file_test(file.c_str(), G_FILE_TEST_IS_REGULAR)) {
        throw RequestError("no file at " + url);
    }
    g_autoptr(GtkFileDialog) dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_initial_name(dialog, name.c_str());
    gtk_file_dialog_save(dialog, shell.window, nullptr, onSaveChosen,
                         new Save{g_object_ref(request), g_file_new_for_path(file.c_str())});
}

// shell.pickFiles, shell.clipboardFiles (docs/contracts/bridge.md, Desktop file paths)

void addPath(std::vector<std::string> &paths, GFile *file) {
    g_autofree char *path = g_file_get_path(file);
    if (path) {
        paths.emplace_back(path);
    } else {
        g_autofree char *uri = g_file_get_uri(file);
        g_warning("file chooser: %s has no local path", uri);
    }
}

void addPaths(std::vector<std::string> &paths, GListModel *files) {
    for (guint i = 0; files && i < g_list_model_get_n_items(files); ++i) {
        g_autoptr(GFile) file = G_FILE(g_list_model_get_item(files, i));
        addPath(paths, file);
    }
}

enum class Pick { file, files, folder, folders };

// A pickFiles request while its panel is open.
struct Picking {
    JSCValue *request;
    Pick pick;

    ~Picking() {
        g_object_unref(request);
    }
};

void onPicked(GObject *source, GAsyncResult *result, gpointer data) {
    const std::unique_ptr<Picking> picking(static_cast<Picking *>(data));
    auto *dialog = GTK_FILE_DIALOG(source);
    g_autoptr(GError) error = nullptr;
    std::vector<std::string> paths;
    switch (picking->pick) {
    case Pick::file: {
        g_autoptr(GFile) file = gtk_file_dialog_open_finish(dialog, result, &error);
        if (file) {
            addPath(paths, file);
        }
        break;
    }
    case Pick::folder: {
        g_autoptr(GFile) folder = gtk_file_dialog_select_folder_finish(dialog, result, &error);
        if (folder) {
            addPath(paths, folder);
        }
        break;
    }
    case Pick::files: {
        g_autoptr(GListModel) files = gtk_file_dialog_open_multiple_finish(dialog, result, &error);
        addPaths(paths, files);
        break;
    }
    case Pick::folders: {
        g_autoptr(GListModel) folders = gtk_file_dialog_select_multiple_folders_finish(dialog, result, &error);
        addPaths(paths, folders);
        break;
    }
    }
    if (error && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) {
        fail(picking->request, error->message);
        return;
    }
    reply(picking->request, jsonObject({{"paths", jsonStrings(paths)}}));
}

void pickFiles(JSCValue *request, JSCValue *params) {
    const bool directory = flag(params, "directory");
    const bool multiple = flag(params, "multiple");
    const std::string startIn = optionalText(params, "startIn");
    g_autoptr(GtkFileDialog) dialog = gtk_file_dialog_new();
    if (g_file_test(startIn.c_str(), G_FILE_TEST_IS_DIR)) {
        g_autoptr(GFile) folder = g_file_new_for_path(startIn.c_str());
        gtk_file_dialog_set_initial_folder(dialog, folder);
    }
    auto *picking = new Picking{g_object_ref(request), directory ? (multiple ? Pick::folders : Pick::folder)
                                                                 : (multiple ? Pick::files : Pick::file)};
    switch (picking->pick) {
    case Pick::file:
        gtk_file_dialog_open(dialog, shell.window, nullptr, onPicked, picking);
        break;
    case Pick::files:
        gtk_file_dialog_open_multiple(dialog, shell.window, nullptr, onPicked, picking);
        break;
    case Pick::folder:
        gtk_file_dialog_select_folder(dialog, shell.window, nullptr, onPicked, picking);
        break;
    case Pick::folders:
        gtk_file_dialog_select_multiple_folders(dialog, shell.window, nullptr, onPicked, picking);
        break;
    }
}

// Files copied in a file manager: GNOME's own type (an action line, then URIs) or a URI list.
constexpr const char *kCopiedFiles = "x-special/gnome-copied-files";
constexpr const char *kUriList = "text/uri-list";

// A clipboardFiles request while the clipboard's content is read.
struct ClipboardRead {
    JSCValue *request;
    bool copiedFiles;  // the content is kCopiedFiles, else kUriList

    ~ClipboardRead() {
        g_object_unref(request);
    }
};

void onClipboardContent(GObject *target, GAsyncResult *result, gpointer data) {
    const std::unique_ptr<ClipboardRead> read(static_cast<ClipboardRead *>(data));
    g_autoptr(GError) error = nullptr;
    if (g_output_stream_splice_finish(G_OUTPUT_STREAM(target), result, &error) < 0) {
        fail(read->request, error->message);
        return;
    }
    auto *memory = G_MEMORY_OUTPUT_STREAM(target);
    std::string content(static_cast<const char *>(g_memory_output_stream_get_data(memory)),
                        g_memory_output_stream_get_data_size(memory));
    if (read->copiedFiles) {
        const auto lineEnd = content.find('\n');
        content.erase(0, lineEnd == std::string::npos ? content.size() : lineEnd + 1);
    }
    std::vector<std::string> paths;
    g_auto(GStrv) uris = g_uri_list_extract_uris(content.c_str());
    for (char **uri = uris; *uri; ++uri) {
        // Only files on this computer have a path.
        g_autofree char *path = g_filename_from_uri(*uri, nullptr, nullptr);
        if (path) {
            paths.emplace_back(path);
        }
    }
    reply(read->request, jsonObject({{"paths", jsonStrings(paths)}}));
}

void onClipboardOpened(GObject *clipboard, GAsyncResult *result, gpointer data) {
    std::unique_ptr<ClipboardRead> read(static_cast<ClipboardRead *>(data));
    g_autoptr(GError) error = nullptr;
    const char *type = nullptr;
    g_autoptr(GInputStream) stream = gdk_clipboard_read_finish(GDK_CLIPBOARD(clipboard), result, &type, &error);
    if (!stream) {
        fail(read->request, error->message);
        return;
    }
    read->copiedFiles = g_strcmp0(type, kCopiedFiles) == 0;
    g_autoptr(GOutputStream) memory = g_memory_output_stream_new_resizable();
    g_output_stream_splice_async(
        memory, stream,
        static_cast<GOutputStreamSpliceFlags>(G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET),
        G_PRIORITY_DEFAULT, nullptr, onClipboardContent, read.release());
}

void clipboardFiles(JSCValue *request) {
    GdkClipboard *clipboard = gtk_widget_get_clipboard(GTK_WIDGET(shell.window));
    GdkContentFormats *formats = gdk_clipboard_get_formats(clipboard);
    if (!gdk_content_formats_contain_mime_type(formats, kCopiedFiles) &&
        !gdk_content_formats_contain_mime_type(formats, kUriList)) {
        reply(request, jsonObject({{"paths", jsonStrings({})}}));
        return;
    }
    const char *types[] = {kCopiedFiles, kUriList, nullptr};
    gdk_clipboard_read_async(clipboard, types, G_PRIORITY_DEFAULT, nullptr, onClipboardOpened,
                             new ClipboardRead{g_object_ref(request), false});
}

// shell.notify*: the desktop's notification server (org.freedesktop.Notifications, specification 1.2).

constexpr const char *kNotifications = "org.freedesktop.Notifications";
constexpr const char *kNotificationsPath = "/org/freedesktop/Notifications";

// What one notification shows.
struct Post {
    std::string title;
    std::string body;
    std::string data;  // the page's data as JSON, for the tap event
};

// A notification the server shows, by the page's id.
struct Shown {
    guint32 serverId;
    std::string data;
};

// A notifySchedule notification until it is due.
struct Scheduled {
    gint64 atMs;
    Post post;
    guint source;
};

// A Notify (with a post) or CloseNotification (without) call, and the page's request it answers (null for a scheduled
// post).
struct Call {
    std::string id;
    std::optional<Post> post;
    JSCValue *request;
};

std::map<std::string, Shown> shown;
std::map<std::string, Scheduled> scheduled;
// Calls run one at a time, so a replacement always knows the server id of the notification it replaces.
std::deque<Call> calls;
bool calling = false;
// Whether the server reads bodies as markup, once asked: then the body's text is escaped.
std::optional<bool> markup;
// The activation token of the latest ActivationToken signal, which comes just before its ActionInvoked.
std::string activationToken;

void callNotifications(const char *method, GVariant *parameters, const char *replyType, GAsyncReadyCallback done,
                       gpointer data) {
    g_dbus_connection_call(shell.bus, kNotifications, kNotificationsPath, kNotifications, method, parameters,
                           G_VARIANT_TYPE(replyType), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, done, data);
}

bool readsMarkup(GVariant *capabilities) {
    g_autofree const char **names = nullptr;
    g_variant_get(capabilities, "(^a&s)", &names);
    for (const char **name = names; *name; ++name) {
        if (strcmp(*name, "body-markup") == 0) {
            return true;
        }
    }
    return false;
}

void runNext();

// Ends the call at the head of the queue, answers its request, and starts the next.
void endCall(const GError *error) {
    Call call = std::move(calls.front());
    calls.pop_front();
    calling = false;
    if (call.request) {
        g_autoptr(JSCValue) request = call.request;
        if (error) {
            fail(request, error->message);
        } else {
            reply(request, jsonObject({}));
        }
    } else if (error) {
        g_warning("notification %s: %s", call.id.c_str(), error->message);
    }
    runNext();
}

void onCapabilities(GObject *bus, GAsyncResult *result, gpointer) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) returned = g_dbus_connection_call_finish(G_DBUS_CONNECTION(bus), result, &error);
    if (!returned) {
        endCall(error);
        return;
    }
    markup = readsMarkup(returned);
    calling = false;
    runNext();
}

void onNotified(GObject *bus, GAsyncResult *result, gpointer) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) returned = g_dbus_connection_call_finish(G_DBUS_CONNECTION(bus), result, &error);
    if (returned) {
        const Call &call = calls.front();
        guint32 serverId = 0;
        g_variant_get(returned, "(u)", &serverId);
        shown[call.id] = {serverId, call.post->data};
    }
    endCall(error);
}

void onClosed(GObject *bus, GAsyncResult *result, gpointer) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) returned = g_dbus_connection_call_finish(G_DBUS_CONNECTION(bus), result, &error);
    if (returned) {
        shown.erase(calls.front().id);
    }
    endCall(error);
}

void runNext() {
    if (calling || calls.empty()) {
        return;
    }
    calling = true;
    const Call &call = calls.front();
    if (call.post && !markup) {
        callNotifications("GetCapabilities", nullptr, "(as)", onCapabilities, nullptr);
        return;
    }
    const auto current = shown.find(call.id);
    const guint32 serverId = current == shown.end() ? 0 : current->second.serverId;
    if (call.post) {
        g_autofree char *body =
            *markup ? g_markup_escape_text(call.post->body.c_str(), -1) : g_strdup(call.post->body.c_str());
        const char *actions[] = {"default", "Open", nullptr};
        callNotifications("Notify",
                          g_variant_new("(susss^asa{sv}i)", "ompanion", serverId, shell.notificationIcon.c_str(),
                                        call.post->title.c_str(), body, actions, nullptr, -1),
                          "(u)", onNotified, nullptr);
    } else if (serverId) {
        callNotifications("CloseNotification", g_variant_new("(u)", serverId), "()", onClosed, nullptr);
    } else {
        endCall(nullptr);
    }
}

void requireBus() {
    if (!shell.bus) {
        throw RequestError("no session bus");
    }
}

Post postParams(JSCValue *params) {
    const std::string subtitle = optionalText(params, "subtitle");
    std::string body = text(params, "body");
    // Linux notifications have no subtitle line: it is the body's first line (design.md, System notification).
    if (!subtitle.empty()) {
        body = body.empty() ? subtitle : subtitle + "\n" + body;
    }
    return {text(params, "title"), std::move(body), jsonParam(params, "data")};
}

gboolean onDue(gpointer data);

// GLib's timeouts run on the monotonic clock, which stops while the computer sleeps, so a scheduled notification
// looks at the wall clock again at least once a minute: after a wake it is at most a minute late.
void arm(const std::string &id, Scheduled &entry) {
    const gint64 remainingMs = entry.atMs - g_get_real_time() / 1000;
    entry.source = g_timeout_add_full(G_PRIORITY_DEFAULT, static_cast<guint>(std::clamp<gint64>(remainingMs, 0, 60000)),
                                      onDue, new std::string(id),
                                      [](gpointer data) { delete static_cast<std::string *>(data); });
}

gboolean onDue(gpointer data) {
    const std::string &id = *static_cast<const std::string *>(data);
    const auto entry = scheduled.find(id);
    if (g_get_real_time() / 1000 < entry->second.atMs) {
        arm(id, entry->second);
        return G_SOURCE_REMOVE;
    }
    calls.push_back({id, std::move(entry->second.post), nullptr});
    scheduled.erase(entry);
    runNext();
    return G_SOURCE_REMOVE;
}

void unschedule(const std::string &id) {
    if (const auto entry = scheduled.find(id); entry != scheduled.end()) {
        g_source_remove(entry->second.source);
        scheduled.erase(entry);
    }
}

void notify(JSCValue *request, JSCValue *params) {
    requireBus();
    std::string id = text(params, "id");
    Post post = postParams(params);
    calls.push_back({std::move(id), std::move(post), g_object_ref(request)});
    runNext();
}

void notifySchedule(JSCValue *request, JSCValue *params) {
    requireBus();
    const std::string id = text(params, "id");
    const auto atMs = static_cast<gint64>(number(params, "atMs"));
    Post post = postParams(params);
    unschedule(id);
    arm(id, scheduled[id] = {atMs, std::move(post), 0});
    reply(request, jsonObject({}));
}

void notifyCancel(JSCValue *request, JSCValue *params) {
    requireBus();
    std::string id = text(params, "id");
    unschedule(id);
    calls.push_back({std::move(id), std::nullopt, g_object_ref(request)});
    runNext();
}

void onPermission(GObject *bus, GAsyncResult *result, gpointer data) {
    g_autoptr(JSCValue) request = JSC_VALUE(data);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GVariant) returned = g_dbus_connection_call_finish(G_DBUS_CONNECTION(bus), result, &error);
    if (returned) {
        markup = readsMarkup(returned);
    } else {
        g_message("no notification server: %s", error->message);
    }
    reply(request, jsonObject({{"granted", jsonBool(returned != nullptr)}}));
}

// Linux desktops have no permission an app asks for: notifications are granted when a server takes them.
void notifyPermission(JSCValue *request, JSCValue *) {
    if (!shell.bus) {
        reply(request, jsonObject({{"granted", jsonBool(false)}}));
        return;
    }
    callNotifications("GetCapabilities", nullptr, "(as)", onPermission, g_object_ref(request));
}

// Brings the window forward. Wayland compositors give a window in the background focus only with an activation token,
// which the server sends just before the tap; GTK hands it to the compositor (xdg-activation).
void present(const std::string &token) {
    if (!token.empty()) {
        gtk_window_set_startup_id(shell.window, token.c_str());
    }
    gtk_window_present(shell.window);
}

void tap(const std::string &id, const std::string &data) {
    present(std::exchange(activationToken, {}));
    g_autoptr(JSCValue) event = jsonObject({
        {"event", jsonText("shell.notificationTap")},
        {"params", jsonObject({{"id", jsonText(id.c_str())}, {"data", jsc_value_new_from_json(json(), data.c_str())}})},
    });
    g_autofree char *message = jsc_value_to_json(event, 0);
    sendWhenListening(message);
}

void onNotificationSignal(GDBusConnection *, const char *, const char *, const char *, const char *signal,
                          GVariant *parameters, gpointer) {
    const std::string_view name = signal;
    guint32 serverId = 0;
    const auto ours = [&serverId] {
        return std::find_if(shown.begin(), shown.end(),
                            [serverId](const auto &entry) { return entry.second.serverId == serverId; });
    };
    if (name == "NotificationClosed" && g_variant_is_of_type(parameters, G_VARIANT_TYPE("(uu)"))) {
        g_variant_get(parameters, "(uu)", &serverId, nullptr);
        if (const auto entry = ours(); entry != shown.end()) {
            shown.erase(entry);
        }
        return;
    }
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(us)"))) {
        return;
    }
    const char *value = nullptr;
    g_variant_get(parameters, "(u&s)", &serverId, &value);
    const auto entry = ours();
    if (entry == shown.end()) {
        return;
    }
    if (name == "ActivationToken") {
        activationToken = value;
    } else if (name == "ActionInvoked" && strcmp(value, "default") == 0) {
        tap(entry->first, entry->second.data);
    }
}

// shell.insets: a desktop window has none.

void insets(JSCValue *request) {
    reply(request, jsonObject({
                       {"top", jsonNumber(0)},
                       {"right", jsonNumber(0)},
                       {"bottom", jsonNumber(0)},
                       {"left", jsonNumber(0)},
                       {"keyboard", jsonNumber(0)},
                   }));
}

void answer(JSCValue *request, std::string_view method, JSCValue *params) {
    if (method == "shell.info") {
        info(request);
    } else if (method == "shell.secretGet") {
        secretGet(request, params);
    } else if (method == "shell.secretSet") {
        secretSet(request, params);
    } else if (method == "shell.secretDelete") {
        secretDelete(request, params);
    } else if (method == "shell.openUrl") {
        openUrl(request, params);
    } else if (method == "shell.clipboardWrite") {
        clipboardWrite(request, params);
    } else if (method == "shell.notify") {
        notify(request, params);
    } else if (method == "shell.notifySchedule") {
        notifySchedule(request, params);
    } else if (method == "shell.notifyCancel") {
        notifyCancel(request, params);
    } else if (method == "shell.notifyPermission") {
        notifyPermission(request, params);
    } else if (method == "shell.saveFile") {
        saveFile(request, params);
    } else if (method == "shell.insets") {
        insets(request);
    } else if (method == "shell.flutterData") {
        flutterData(request);
    } else if (method == "shell.flutterDataClear") {
        flutterDataClear(request);
    } else if (method == "shell.pickFiles") {
        pickFiles(request, params);
    } else if (method == "shell.clipboardFiles") {
        clipboardFiles(request);
    } else if (method == "shell.timing") {
        // The page's startup stages as epoch ms (docs/contracts/bridge.md); a smoke run's own `shell timing` line has
        // the shell's.
        g_autofree char *stages = jsc_value_to_json(params, 0);
        g_printerr("shell timing page %s\n", stages);
        reply(request, jsonObject({}));
    } else {
        throw RequestError("not available on Linux");
    }
}

// <input type=file>

// Hands the chosen files to the page; none cancels the choice.
void choose(WebKitFileChooserRequest *request, const std::vector<std::string> &paths, const GError *error) {
    if (error && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)) {
        g_warning("file chooser: %s", error->message);
    }
    if (paths.empty()) {
        webkit_file_chooser_request_cancel(request);
        return;
    }
    webkit_file_chooser_request_select_files(request, strv(paths).data());
}

void onFileOpened(GObject *dialog, GAsyncResult *result, gpointer data) {
    g_autoptr(WebKitFileChooserRequest) request = WEBKIT_FILE_CHOOSER_REQUEST(data);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GFile) file = gtk_file_dialog_open_finish(GTK_FILE_DIALOG(dialog), result, &error);
    std::vector<std::string> paths;
    if (file) {
        addPath(paths, file);
    }
    choose(request, paths, error);
}

void onFilesOpened(GObject *dialog, GAsyncResult *result, gpointer data) {
    g_autoptr(WebKitFileChooserRequest) request = WEBKIT_FILE_CHOOSER_REQUEST(data);
    g_autoptr(GError) error = nullptr;
    g_autoptr(GListModel) files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(dialog), result, &error);
    std::vector<std::string> paths;
    addPaths(paths, files);
    choose(request, paths, error);
}

// File drops (docs/contracts/bridge.md, Desktop file paths). A drop target in the capture phase sees a drag before
// WebKit's own does and reads the dragged file list while it hovers. When that holds files on this computer the shell
// keeps the drag: the page hears shell.drag and shell.drop, and WebKit never gets the drop. Anything else (a link
// dragged from a browser) it rejects, and WebKit takes the drag as before. Drags out of the page itself never stop here.

bool draggingFiles = false;

// Takes over `params`' reference.
void sendEvent(const char *name, JSCValue *params) {
    g_autoptr(JSCValue) event = jsonObject({{"event", jsonText(name)}, {"params", params}});
    g_autofree char *message = jsc_value_to_json(event, 0);
    sendToPage(message);
}

void dragging(bool active) {
    if (draggingFiles != active) {
        draggingFiles = active;
        sendEvent("shell.drag", jsonObject({{"active", jsonBool(active)}}));
    }
}

// The dragged files' paths; empty unless every one of them is on this computer.
std::vector<std::string> localPaths(const GValue *value) {
    std::vector<std::string> paths;
    GSList *files = gdk_file_list_get_files(static_cast<GdkFileList *>(g_value_get_boxed(value)));
    for (GSList *file = files; file; file = file->next) {
        g_autofree char *path = g_file_get_path(G_FILE(file->data));
        if (!path) {
            paths.clear();
            break;
        }
        paths.emplace_back(path);
    }
    g_slist_free(files);
    return paths;
}

// GtkDropTarget's own test, for drags from other apps only.
gboolean onDropAccept(GtkDropTarget *target, GdkDrop *drop, gpointer) {
    return !gdk_drop_get_drag(drop) && (gdk_drop_get_actions(drop) & GDK_ACTION_COPY) &&
           gdk_content_formats_match(gtk_drop_target_get_formats(target), gdk_drop_get_formats(drop));
}

// The dragged file list arrived (or was dropped: then null).
void onDropValue(GtkDropTarget *target, GParamSpec *, gpointer) {
    const GValue *value = gtk_drop_target_get_value(target);
    if (!value) {
        return;
    }
    if (localPaths(value).empty()) {
        gtk_drop_target_reject(target);
    } else {
        dragging(true);
    }
}

// Until the file list has arrived WebKit answers the drag.
GdkDragAction onDropMotion(GtkDropTarget *, double, double, gpointer) {
    return draggingFiles ? GDK_ACTION_COPY : static_cast<GdkDragAction>(0);
}

void onDropLeave(GtkDropTarget *, gpointer) {
    dragging(false);
}

gboolean onDrop(GtkDropTarget *, const GValue *value, double, double, gpointer) {
    dragging(false);
    const std::vector<std::string> paths = localPaths(value);
    if (paths.empty()) {
        return FALSE;
    }
    sendEvent("shell.drop", jsonObject({{"paths", jsonStrings(paths)}}));
    return TRUE;
}

}  // namespace

JSCContext *json() {
    if (!context) {
        context = jsc_context_new();
    }
    return context;
}

JSCValue *jsonParse(const char *text) {
    JSCValue *value = jsc_value_new_from_json(json(), text);
    if (!value) {
        jsc_context_clear_exception(json());
        return nullptr;
    }
    if (!jsc_value_is_object(value)) {
        g_object_unref(value);
        return nullptr;
    }
    return value;
}

bool answerShellRequest(const char *message) {
    g_autoptr(JSCValue) request = jsonParse(message);
    if (!request) {
        return false;
    }
    g_autoptr(JSCValue) method = jsc_value_object_get_property(request, "method");
    if (!jsc_value_is_string(method)) {
        return false;
    }
    g_autofree char *name = jsc_value_to_string(method);
    if (!g_str_has_prefix(name, "shell.")) {
        return false;
    }
    g_autoptr(JSCValue) handle = jsonObject({
        {"id", jsc_value_object_get_property(request, "id")},
        {"page", jsonNumber(pageGeneration())},
    });
    g_autoptr(JSCValue) given = jsc_value_object_get_property(request, "params");
    g_autoptr(JSCValue) params = jsc_value_is_object(given) ? g_object_ref(given) : jsonObject({});
    try {
        answer(handle, name, params);
    } catch (const RequestError &error) {
        fail(handle, (std::string(name) + ": " + error.what()).c_str());
    }
    return true;
}

void watchNotifications() {
    g_dbus_connection_signal_subscribe(shell.bus, kNotifications, kNotifications, nullptr, kNotificationsPath, nullptr,
                                       G_DBUS_SIGNAL_FLAGS_NONE, onNotificationSignal, nullptr, nullptr);
}

gboolean onRunFileChooser(WebKitWebView *, WebKitFileChooserRequest *request, gpointer) {
    g_autoptr(GtkFileDialog) dialog = gtk_file_dialog_new();
    if (GtkFileFilter *filter = webkit_file_chooser_request_get_mime_types_filter(request)) {
        g_autoptr(GListStore) filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
        g_list_store_append(filters, filter);
        gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
    }
    if (webkit_file_chooser_request_get_select_multiple(request)) {
        gtk_file_dialog_open_multiple(dialog, shell.window, nullptr, onFilesOpened, g_object_ref(request));
    } else {
        gtk_file_dialog_open(dialog, shell.window, nullptr, onFileOpened, g_object_ref(request));
    }
    return TRUE;
}

void watchFileDrops(WebKitWebView *view) {
    GtkDropTarget *target = gtk_drop_target_new(GDK_TYPE_FILE_LIST, GDK_ACTION_COPY);
    gtk_drop_target_set_preload(target, TRUE);
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(target), GTK_PHASE_CAPTURE);
    g_signal_connect(target, "accept", G_CALLBACK(onDropAccept), nullptr);
    g_signal_connect(target, "notify::value", G_CALLBACK(onDropValue), nullptr);
    g_signal_connect(target, "enter", G_CALLBACK(onDropMotion), nullptr);
    g_signal_connect(target, "motion", G_CALLBACK(onDropMotion), nullptr);
    g_signal_connect(target, "leave", G_CALLBACK(onDropLeave), nullptr);
    g_signal_connect(target, "drop", G_CALLBACK(onDrop), nullptr);
    gtk_widget_add_controller(GTK_WIDGET(view), GTK_EVENT_CONTROLLER(target));
}
