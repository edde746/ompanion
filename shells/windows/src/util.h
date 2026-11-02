// Logging, failure, text conversion and files for every part of the shell.
#pragma once

#include <windows.h>

#include <optional>
#include <string>
#include <string_view>

extern bool smoke;  // OMPCORE_SMOKE=1: a harness runs the app, so failures show no dialog

// Shell lines go to stderr: smoke.ps1 redirects it to a file. A GUI app started from Explorer has none.
void log(const std::string& line);

std::string hex(HRESULT result);
// The calling thread's last error, for right after a call failed. Never S_OK: some calls fail without setting it.
HRESULT lastError();

// Startup and webview failures the app cannot run without: logs, shows a dialog outside smoke runs, exits.
[[noreturn]] void fail(const std::string& what, HRESULT result);
void check(HRESULT result, const std::string& what);

// For calls whose failure the app outlives, such as one on a webview whose browser process just died.
void warn(HRESULT result, const std::string& what);

// For a shell request: throws std::runtime_error, which becomes the request's error response.
void ensure(HRESULT result, const std::string& what);

std::wstring widen(std::string_view text);
std::string narrow(std::wstring_view text);

// Copies a string a COM API allocated, and frees it.
std::wstring take(LPWSTR text);

class File {
public:
    explicit File(HANDLE handle) : handle_(handle) {}
    ~File() {
        if (handle_ != INVALID_HANDLE_VALUE) CloseHandle(handle_);
    }
    File(const File&) = delete;
    File& operator=(const File&) = delete;

    HANDLE get() const { return handle_; }
    bool opened() const { return handle_ != INVALID_HANDLE_VALUE; }

private:
    HANDLE handle_;
};

// The error a file call failed with says the file or its folder is not there.
bool missing(DWORD error);

// The file's bytes, or nothing when there is no such file. Shell-request helpers: they throw for other failures.
std::optional<std::string> readFile(const std::wstring& path);
// Removing a file that is not there is no failure.
void removeFile(const std::wstring& path);
