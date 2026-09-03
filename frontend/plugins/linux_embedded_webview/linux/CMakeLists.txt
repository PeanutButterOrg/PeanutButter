cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "linux_embedded_webview")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "linux_embedded_webview_plugin")

find_package(PkgConfig REQUIRED)
pkg_check_modules(WebKit IMPORTED_TARGET webkit2gtk-4.1)
if (NOT WebKit_FOUND)
  pkg_check_modules(WebKit REQUIRED IMPORTED_TARGET webkit2gtk-4.0)
endif()

add_library(${PLUGIN_NAME} SHARED
  "linux_embedded_webview_plugin.cc"
)
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::WebKit)

set(linux_embedded_webview_bundled_libraries
  ""
  PARENT_SCOPE
)
