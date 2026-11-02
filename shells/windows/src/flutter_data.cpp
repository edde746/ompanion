#include "flutter_data.h"

#include "json.h"
#include "secrets.h"
#include "util.h"

#include <shlobj.h>

#include <optional>
#include <stdexcept>

namespace {

std::wstring folder() {
    PWSTR raw;
    ensure(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr, &raw), "finding %APPDATA%");
    return take(raw) + L"\\com.edde746\\ompanion\\";
}

bool exists(const std::wstring& path) {
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return true;
    if (!missing(GetLastError())) ensure(lastError(), "looking for " + narrow(path));
    return false;
}

}  // namespace

std::string flutterData() {
    std::wstring base = folder();
    std::wstring database = base + L"ompanion.sqlite";
    std::string result = R"({"database":)" + (exists(database) ? quote(narrow(database)) : "null") + R"(,"secrets":{)";
    if (std::optional<std::string> sealed = readFile(base + L"flutter_secure_storage.dat")) {
        std::string text = unseal(*sealed);
        std::optional<Json> secrets = parseJson(text);
        if (!secrets || secrets->kind != Json::Kind::Object)
            throw std::runtime_error("flutter_secure_storage.dat holds no JSON object");
        bool first = true;
        // flutter_secure_storage itself reads only the string values.
        for (const auto& [key, value] : secrets->members) {
            if (value.kind != Json::Kind::String) continue;
            if (!first) result += ',';
            first = false;
            result += quote(key) + ":" + quote(value.string);
        }
    }
    return result + "}}";
}

void flutterDataClear() {
    std::wstring base = folder();
    for (const wchar_t* name :
         {L"ompanion.sqlite", L"ompanion.sqlite-journal", L"ompanion.sqlite-wal", L"ompanion.sqlite-shm"}) {
        std::wstring path = base + name;
        if (!MoveFileExW(path.c_str(), (path + L".imported").c_str(), MOVEFILE_REPLACE_EXISTING) &&
            !missing(GetLastError()))
            ensure(lastError(), "renaming " + narrow(path));
    }
    removeFile(base + L"flutter_secure_storage.dat");
}
