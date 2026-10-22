# Linux CMakeLists.txt — always builds the bridge from source against the
# system libtorrent-rasterbar (apt: libtorrent-rasterbar-dev).
#
# Upstream's GitHub prebuilt .so was ABI-mismatched (garbage torrent status,
# streams never opened) and is no longer downloadable. pkg-config carries
# libtorrent's ABI defines, so the bridge always matches the library it links.
cmake_minimum_required(VERSION 3.21)

set(PROJECT_NAME "libtorrent_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")
set_target_properties(libtorrent_flutter PROPERTIES
  BUILD_RPATH "$ORIGIN"
  INSTALL_RPATH "$ORIGIN"
)

# Ship libtorrent-rasterbar next to the bridge so the portable folder /
# AppImage / .deb run on machines without the -dev package. Resolve the real
# SONAME file (not the unversioned dev symlink) from pkg-config's lib dirs.
set(_ltf_bundled $<TARGET_FILE:libtorrent_flutter>)
find_package(PkgConfig REQUIRED)
pkg_check_modules(_LTF_LT REQUIRED libtorrent-rasterbar)
find_library(_LTF_RASTERBAR NAMES torrent-rasterbar
  HINTS ${_LTF_LT_LIBRARY_DIRS} NO_CACHE)
if(_LTF_RASTERBAR)
  get_filename_component(_ltf_dir "${_LTF_RASTERBAR}" DIRECTORY)
  file(GLOB _ltf_sonames "${_ltf_dir}/libtorrent-rasterbar.so.*")
  foreach(_so IN LISTS _ltf_sonames)
    # The SONAME link (e.g. libtorrent-rasterbar.so.2.0) is what the loader
    # asks for; copy its real file under that name (install() would copy the
    # symlink itself).
    if(_so MATCHES "libtorrent-rasterbar\\.so\\.[0-9]+\\.[0-9]+$")
      get_filename_component(_soname "${_so}" NAME)
      file(REAL_PATH "${_so}" _real)
      file(COPY_FILE "${_real}" "${CMAKE_CURRENT_BINARY_DIR}/${_soname}" ONLY_IF_DIFFERENT)
      list(APPEND _ltf_bundled "${CMAKE_CURRENT_BINARY_DIR}/${_soname}")
    endif()
  endforeach()
else()
  message(WARNING "libtorrent_flutter: libtorrent-rasterbar not found to bundle")
endif()

set(libtorrent_flutter_bundled_libraries
  ${_ltf_bundled}
  PARENT_SCOPE
)
