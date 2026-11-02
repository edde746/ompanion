# The Windows shell, cross-built by build.sh with llvm-mingw. WEBVIEW2_DIR is the unpacked Microsoft.Web.WebView2 NuGet
# package; OMPCORE_DIR holds libompcore.dll's import library (libompcore.dll.a) and libompcore.h.
cmake_minimum_required(VERSION 3.25)

# The repo's VERSION, <major>.<minor>.<patch>+<build>, is the app's version: shell.info's appVersion and build, and
# VERSIONINFO's major.minor.patch.0.
set(version_file "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${version_file}")
file(STRINGS "${version_file}" version_line LIMIT_COUNT 1)
if(NOT version_line MATCHES "^([0-9]+\\.[0-9]+\\.[0-9]+)\\+([0-9]+)$")
  message(FATAL_ERROR "VERSION must be <major>.<minor>.<patch>+<build>, not '${version_line}'")
endif()
set(app_build "${CMAKE_MATCH_2}")
project(ompanion_windows VERSION "${CMAKE_MATCH_1}" LANGUAGES CXX RC)

set(WEBVIEW2_DIR "" CACHE PATH "The unpacked Microsoft.Web.WebView2 NuGet package")
set(OMPCORE_DIR "" CACHE PATH "libompcore.dll.a and libompcore.h")
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
  set(webview2_arch arm64)
else()
  set(webview2_arch x64)
endif()

# WebView2.h includes "EventToken.h"; mingw-w64 names it eventtoken.h, and Linux file systems are case-sensitive.
# include_next: on a case-insensitive mount (Docker on macOS) <eventtoken.h> would find this file again.
file(WRITE "${CMAKE_BINARY_DIR}/shim/EventToken.h" "#include_next <eventtoken.h>\n")

# The app's icon, which app.rc embeds.
set(icon_resources "${CMAKE_CURRENT_SOURCE_DIR}/resources")
set_property(SOURCE src/app.rc APPEND PROPERTY INCLUDE_DIRECTORIES "${icon_resources}")
set_property(SOURCE src/app.rc APPEND PROPERTY OBJECT_DEPENDS
  "${icon_resources}/app_icon.ico" "${CMAKE_CURRENT_SOURCE_DIR}/src/app.manifest")

add_executable(ompanion WIN32
  src/main.cpp src/flutter_data.cpp src/json.cpp src/notifications.cpp src/secrets.cpp src/shell.cpp src/util.cpp
  src/app.rc)
target_compile_features(ompanion PRIVATE cxx_std_20)
# Windows 10 APIs (GetDpiForWindow); mingw-w64 defaults to Windows 7. APP_VERSION and APP_BUILD go unquoted and the
# sources stringize them: windres drops the quotes of a string define.
target_compile_definitions(ompanion PRIVATE UNICODE _UNICODE WINVER=0x0A00 _WIN32_WINNT=0x0A00
  APP_VERSION=${PROJECT_VERSION} APP_BUILD=${app_build}
  APP_VERSION_NUMBER=${PROJECT_VERSION_MAJOR},${PROJECT_VERSION_MINOR},${PROJECT_VERSION_PATCH},0)
target_compile_options(ompanion PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra>")
target_include_directories(ompanion SYSTEM PRIVATE
  "${CMAKE_BINARY_DIR}/shim" "${WEBVIEW2_DIR}/build/native/include" "${OMPCORE_DIR}")
target_link_libraries(ompanion PRIVATE
  "${OMPCORE_DIR}/libompcore.dll.a"
  "${WEBVIEW2_DIR}/build/native/${webview2_arch}/WebView2Loader.dll.lib"
  advapi32 crypt32 dwmapi ole32 runtimeobject shell32 shlwapi user32 uuid)
# -static: libc++ and libunwind go into the exe instead of being two more DLLs to ship.
target_link_options(ompanion PRIVATE -municode -static -s)
