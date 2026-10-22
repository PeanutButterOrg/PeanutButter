# Windows CMakeLists.txt — uses an in-repo prebuilt DLL
# (prebuilt/windows/<arch>/libtorrent_flutter.dll) if present, otherwise
# builds from source against vcpkg's libtorrent. Upstream's GitHub prebuilt
# download is gone (404), so nothing is fetched here.
cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "libtorrent_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

set(_LTF_TARGET_ARCH "")
if(DEFINED CMAKE_GENERATOR_PLATFORM AND CMAKE_GENERATOR_PLATFORM)
  set(_LTF_TARGET_ARCH "${CMAKE_GENERATOR_PLATFORM}")
elseif(DEFINED CMAKE_VS_PLATFORM_NAME AND CMAKE_VS_PLATFORM_NAME)
  set(_LTF_TARGET_ARCH "${CMAKE_VS_PLATFORM_NAME}")
else()
  set(_LTF_TARGET_ARCH "$ENV{PROCESSOR_ARCHITECTURE}")
endif()

string(TOLOWER "${_LTF_TARGET_ARCH}" _LTF_TARGET_ARCH_LOWER)
if(_LTF_TARGET_ARCH_LOWER MATCHES "arm64|aarch64")
  set(LTF_WINDOWS_ARCH "arm64")
else()
  set(LTF_WINDOWS_ARCH "x64")
endif()

set(PREBUILT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../prebuilt/windows")
set(PREBUILT_DLL "${PREBUILT_DIR}/${LTF_WINDOWS_ARCH}/libtorrent_flutter.dll")

if(NOT EXISTS "${PREBUILT_DLL}" AND EXISTS "${PREBUILT_DIR}/libtorrent_flutter.dll")
  set(PREBUILT_DLL "${PREBUILT_DIR}/libtorrent_flutter.dll")
  set(PREBUILT_SEARCH_PATH "${PREBUILT_DIR}/*.dll")
else()
  set(PREBUILT_SEARCH_PATH "${PREBUILT_DIR}/${LTF_WINDOWS_ARCH}/*.dll")
endif()

if(EXISTS "${PREBUILT_DLL}")
  message(STATUS "Using prebuilt Windows native library from ${PREBUILT_DLL}")
  file(GLOB PREBUILT_DEPS "${PREBUILT_SEARCH_PATH}")
  set(libtorrent_flutter_bundled_libraries
    ${PREBUILT_DEPS}
    PARENT_SCOPE
  )
else()
  message(STATUS "Building from source (no prebuilt found at ${PREBUILT_DLL})")
  # Flutter owns the top-level toolchain, so point find_package() at a
  # vcpkg install tree instead: vcpkg install libtorrent:x64-windows-static-md
  set(_LTF_VCPKG_ROOT "$ENV{VCPKG_ROOT}")
  if(NOT _LTF_VCPKG_ROOT)
    set(_LTF_VCPKG_ROOT "$ENV{VCPKG_INSTALLATION_ROOT}")
  endif()
  set(LTF_VCPKG_TRIPLET "${LTF_WINDOWS_ARCH}-windows-static-md" CACHE STRING
    "vcpkg triplet providing static libtorrent + OpenSSL")
  if(_LTF_VCPKG_ROOT)
    file(TO_CMAKE_PATH "${_LTF_VCPKG_ROOT}/installed/${LTF_VCPKG_TRIPLET}" _LTF_VCPKG_PREFIX)
    list(APPEND CMAKE_PREFIX_PATH "${_LTF_VCPKG_PREFIX}")
    set(OPENSSL_ROOT_DIR "${_LTF_VCPKG_PREFIX}")
    set(Boost_INCLUDE_DIR "${_LTF_VCPKG_PREFIX}/include")
  endif()
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
  set(libtorrent_flutter_bundled_libraries
    $<TARGET_FILE:libtorrent_flutter>
    PARENT_SCOPE
  )
endif()