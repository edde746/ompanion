cmake_minimum_required(VERSION 3.25)
project(ompanion LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(OMPCORE_DIR "" CACHE PATH "Directory holding libompcore.so and libompcore.h (go build -buildmode=c-shared ./capi)")
if(NOT EXISTS "${OMPCORE_DIR}/libompcore.so" OR NOT EXISTS "${OMPCORE_DIR}/libompcore.h")
  message(FATAL_ERROR "OMPCORE_DIR (${OMPCORE_DIR}) must hold libompcore.so and libompcore.h")
endif()
# shell.info's appVersion and build: the repository's VERSION, <semver>+<build>.
set(VERSION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION" CACHE FILEPATH "The app's VERSION file")
file(STRINGS "${VERSION_FILE}" version LIMIT_COUNT 1)
if(NOT version MATCHES "^([0-9]+\\.[0-9]+\\.[0-9]+)\\+([0-9]+)$")
  message(FATAL_ERROR "${VERSION_FILE} holds '${version}', not <semver>+<build>")
endif()
set(app_version "${CMAKE_MATCH_1}")
set(app_build "${CMAKE_MATCH_2}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${VERSION_FILE}")

find_package(PkgConfig REQUIRED)
pkg_check_modules(DEPS REQUIRED IMPORTED_TARGET gtk4 webkitgtk-6.0 libsecret-1)

add_executable(ompanion main.cpp services.cpp)
target_compile_options(ompanion PRIVATE -Wall -Wextra -Werror)
target_compile_definitions(ompanion PRIVATE APP_VERSION="${app_version}" APP_BUILD="${app_build}")
target_include_directories(ompanion PRIVATE "${OMPCORE_DIR}")
target_link_libraries(ompanion PRIVATE PkgConfig::DEPS "${OMPCORE_DIR}/libompcore.so")
# libompcore.so ships next to the binary; no build-tree runpath.
set_target_properties(ompanion PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "$ORIGIN")
