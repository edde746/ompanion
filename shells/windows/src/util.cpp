#include "util.h"

#include <cstdio>
#include <stdexcept>

bool smoke;

void log(const std::string& line) {
    std::fprintf(stderr, "shell: %s\n", line.c_str());
    std::fflush(stderr);
}

std::string hex(HRESULT result) {
    char text[16];
    std::snprintf(text, sizeof text, "0x%08lX", static_cast<unsigned long>(result));
    return text;
}

HRESULT lastError() {
    DWORD error = GetLastError();
    return error ? HRESULT_FROM_WIN32(error) : E_FAIL;
}

void fail(const std::string& what, HRESULT result) {
    std::string text = what + " failed: " + hex(result);
    log(text);
    if (!smoke) MessageBoxW(nullptr, widen(text).c_str(), L"ompanion", MB_ICONERROR);
    ExitProcess(1);
}

void check(HRESULT result, const std::string& what) {
    if (FAILED(result)) fail(what, result);
}

void warn(HRESULT result, const std::string& what) {
    if (FAILED(result)) log(what + " failed: " + hex(result));
}

void ensure(HRESULT result, const std::string& what) {
    if (FAILED(result)) throw std::runtime_error(what + " failed: " + hex(result));
}

std::wstring widen(std::string_view text) {
    if (text.empty()) return {};
    int size = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (size == 0) fail("decoding UTF-8", lastError());
    std::wstring wide(size, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), wide.data(), size);
    return wide;
}

std::string narrow(std::wstring_view text) {
    if (text.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (size == 0) fail("encoding UTF-8", lastError());
    std::string utf8(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), utf8.data(), size, nullptr, nullptr);
    return utf8;
}

std::wstring take(LPWSTR text) {
    std::wstring copy = text ? text : L"";
    CoTaskMemFree(text);
    return copy;
}

bool missing(DWORD error) { return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND; }

std::optional<std::string> readFile(const std::wstring& path) {
    File file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                          nullptr));
    if (!file.opened()) {
        if (missing(GetLastError())) return std::nullopt;
        ensure(lastError(), "opening " + narrow(path));
    }
    LARGE_INTEGER size;
    if (!GetFileSizeEx(file.get(), &size)) ensure(lastError(), "reading the size of " + narrow(path));
    std::string bytes(static_cast<size_t>(size.QuadPart), '\0');
    DWORD read;
    if (!ReadFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()), &read, nullptr))
        ensure(lastError(), "reading " + narrow(path));
    bytes.resize(read);
    return bytes;
}

void removeFile(const std::wstring& path) {
    if (!DeleteFileW(path.c_str()) && !missing(GetLastError())) ensure(lastError(), "removing " + narrow(path));
}
