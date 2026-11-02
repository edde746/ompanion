#include "secrets.h"

#include "app.h"
#include "util.h"

#include <dpapi.h>
#include <shlobj.h>
#include <wincred.h>

namespace {

std::wstring target(const std::string& key) { return std::wstring(kAppId) + L"/" + widen(key); }

std::wstring sealedFolder() { return dataFolder + L"\\secrets"; }

// The key in hex: a valid file name whatever the key holds.
std::wstring sealedPath(const std::string& key) {
    static constexpr wchar_t digits[] = L"0123456789abcdef";
    std::wstring name;
    for (unsigned char c : key) {
        name += digits[c >> 4];
        name += digits[c & 15];
    }
    return sealedFolder() + L"\\" + name;
}

// Written whole to a temporary file and renamed over the old one: a crash leaves the old value or the new.
void writeFile(const std::wstring& path, const std::string& bytes) {
    int created = SHCreateDirectoryExW(nullptr, sealedFolder().c_str(), nullptr);
    if (created != ERROR_SUCCESS && created != ERROR_ALREADY_EXISTS)
        ensure(HRESULT_FROM_WIN32(created), "creating " + narrow(sealedFolder()));
    std::wstring temporary = path + L".tmp";
    {
        File file(CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                              nullptr));
        if (!file.opened()) ensure(lastError(), "creating " + narrow(temporary));
        DWORD written;
        if (!WriteFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) ||
            !FlushFileBuffers(file.get()))
            ensure(lastError(), "writing " + narrow(temporary));
    }
    if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        ensure(lastError(), "replacing " + narrow(path));
}

void deleteCredential(const std::string& key) {
    if (!CredDeleteW(target(key).c_str(), CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND)
        ensure(lastError(), "deleting the credential " + key);
}

std::string seal(const std::string& value) {
    DATA_BLOB in{static_cast<DWORD>(value.size()), reinterpret_cast<BYTE*>(const_cast<char*>(value.data()))};
    DATA_BLOB out;
    if (!CryptProtectData(&in, L"ompanion secret", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out))
        ensure(lastError(), "encrypting a secret");
    std::string sealed(reinterpret_cast<const char*>(out.pbData), out.cbData);
    LocalFree(out.pbData);
    return sealed;
}

}  // namespace

std::string unseal(const std::string& sealed) {
    DATA_BLOB in{static_cast<DWORD>(sealed.size()), reinterpret_cast<BYTE*>(const_cast<char*>(sealed.data()))};
    DATA_BLOB out;
    if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out))
        ensure(lastError(), "decrypting a secret");
    std::string value(reinterpret_cast<const char*>(out.pbData), out.cbData);
    LocalFree(out.pbData);
    return value;
}

std::optional<std::string> secretGet(const std::string& key) {
    PCREDENTIALW credential;
    if (CredReadW(target(key).c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        std::string value;
        if (credential->CredentialBlobSize > 0)
            value.assign(reinterpret_cast<const char*>(credential->CredentialBlob), credential->CredentialBlobSize);
        CredFree(credential);
        return value;
    }
    if (GetLastError() != ERROR_NOT_FOUND) ensure(lastError(), "reading the credential " + key);
    std::optional<std::string> sealed = readFile(sealedPath(key));
    if (!sealed) return std::nullopt;
    return unseal(*sealed);
}

void secretSet(const std::string& key, const std::string& value) {
    if (value.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
        writeFile(sealedPath(key), seal(value));
        deleteCredential(key);
        return;
    }
    std::wstring name = target(key);
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = name.data();
    credential.CredentialBlobSize = static_cast<DWORD>(value.size());
    credential.CredentialBlob = reinterpret_cast<BYTE*>(const_cast<char*>(value.data()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (!CredWriteW(&credential, 0)) ensure(lastError(), "writing the credential " + key);
    removeFile(sealedPath(key));
}

void secretDelete(const std::string& key) {
    deleteCredential(key);
    removeFile(sealedPath(key));
}
