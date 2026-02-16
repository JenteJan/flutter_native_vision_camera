# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(flutter_native_vision_camera_library VERSION 0.0.1 LANGUAGES C CXX)

add_library(flutter_native_vision_camera SHARED
  "flutter_native_vision_camera.c"
  "VisionCamera_NativePluginExample.cpp"
)

set_target_properties(flutter_native_vision_camera PROPERTIES
  PUBLIC_HEADER flutter_native_vision_camera.h
  OUTPUT_NAME "flutter_native_vision_camera"
)

target_compile_definitions(flutter_native_vision_camera PUBLIC DART_SHARED_LIB)

if (ANDROID)
  find_library(log-lib log)
  target_link_libraries(flutter_native_vision_camera PRIVATE ${log-lib})
  # Support Android 15 16k page size
  target_link_options(flutter_native_vision_camera PRIVATE "-Wl,-z,max-page-size=16384")
endif()
