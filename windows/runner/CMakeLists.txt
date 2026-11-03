cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "live_wallpaper_plugin.cpp"
  "main.cpp"
  "process_diagnostics.cpp"
  "taskbar_appbar.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app
  flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "psapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "dxgi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "winmm.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

add_custom_command(
  TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/resources/app_icon.ico"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/WallSync.ico"
)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/cnativeapi.dll")
  add_custom_command(
    TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CMAKE_CURRENT_SOURCE_DIR}/cnativeapi.dll"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/cnativeapi.dll"
  )
endif()

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/native_assets.json")
  add_custom_command(
    TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CMAKE_CURRENT_SOURCE_DIR}/native_assets.json"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/native_assets.json"
  )
endif()

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../plugins")
  add_custom_command(
    TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/plugins/mpv"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CMAKE_CURRENT_SOURCE_DIR}/../../plugins/mpv/mpv.exe"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/plugins/mpv/mpv.exe"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CMAKE_CURRENT_SOURCE_DIR}/../../plugins/mpv/d3dcompiler_43.dll"
      "$<TARGET_FILE_DIR:${BINARY_NAME}>/plugins/mpv/d3dcompiler_43.dll"
  )
endif()
