#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <timeapi.h>

#include <cstdio>

// Request high-performance GPU profile from NVIDIA / AMD drivers
extern "C" {
  __declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
  __declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}

#include "flutter_window.h"
#include "process_diagnostics.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  if (!InitializeProcessDiagnostics(command_line_arguments)) {
    std::fprintf(stderr,
                 "WallSync could not create its process diagnostics log.\n");
    std::fflush(stderr);
    return EXIT_FAILURE;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com_result)) {
    LogProcessDiagnostic("com_initialization",
                         "result=failed hresult=" + std::to_string(com_result));
    CloseProcessDiagnostics(EXIT_FAILURE);
    return EXIT_FAILURE;
  }
  LogProcessDiagnostic("com_initialization", "result=success");

  // Request 1ms system timer precision to eliminate scheduling jitter and jank
  ::timeBeginPeriod(1);

  flutter::DartProject project(L"data");

  bool is_overlay = false;
  bool is_wallpaper = false;
  const bool is_taskbar_dock = GetProcessModeName() == "taskbar_dock";
  bool is_startup_bootstrap = false;
  bool is_startup_registration = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--overlay") is_overlay = true;
    if (arg == "--wallpaper") is_wallpaper = true;
    if (arg == "--sync-startup-registration") {
      is_startup_registration = true;
      is_startup_bootstrap = true;
    } else if (arg == "--startup-trigger=windows-logon") {
      is_startup_bootstrap = true;
    }
  }

  if (GetProcessModeName() == "invalid") {
    LogProcessDiagnostic(
        "process_mode_validation",
        "result=invalid error=Contradictory or unsupported overlay mode arguments");
    ::timeEndPeriod(1);
    ::CoUninitialize();
    CloseProcessDiagnostics(EXIT_FAILURE);
    return EXIT_FAILURE;
  }
  if (!CreateProcessReadinessEvent(command_line_arguments)) {
    LogProcessDiagnostic("ipc_server_startup",
                         "result=failed error=Could not create readiness event");
    ::timeEndPeriod(1);
    ::CoUninitialize();
    CloseProcessDiagnostics(EXIT_FAILURE);
    return EXIT_FAILURE;
  }
  LogProcessDiagnostic("window_class_registration",
                       "result=pending class=FLUTTER_RUNNER_WIN32_WINDOW");

  // If another dashboard instance is already running, activate and restore it
  if (!is_overlay && !is_wallpaper) {
    bool is_debug_or_flutter = ::IsDebuggerPresent();
    for (const auto& arg : command_line_arguments) {
      if (arg.find("--vm-service-port") != std::string::npos ||
          arg.find("--observatory-port") != std::string::npos ||
          arg.find("--flutter-assets-dir") != std::string::npos) {
        is_debug_or_flutter = true;
        break;
      }
    }

    if (!is_debug_or_flutter) {
      HWND existing_window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"WallSync Pro");
      if (existing_window) {
        if (!is_startup_bootstrap) {
          UINT show_msg = ::RegisterWindowMessageW(L"WallSyncPro_ShowDashboard");
          ::PostMessageW(existing_window, show_msg, 0, 0);
          ::ShowWindow(existing_window, SW_SHOW);
          ::ShowWindow(existing_window, SW_RESTORE);
          ::SetForegroundWindow(existing_window);
        }
        if (!is_startup_registration) {
          ::CoUninitialize();
          CloseProcessDiagnostics(EXIT_SUCCESS);
          return EXIT_SUCCESS;
        }
      }
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
  LogProcessDiagnostic("flutter_engine_initialization",
                       "result=pending runtimePath=data");

  int exit_code = EXIT_SUCCESS;
  {
    FlutterWindow window(project);
    Win32Window::Point origin(is_taskbar_dock ? 0 : 10,
                              is_taskbar_dock ? 0 : 10);
    Win32Window::Size size(is_taskbar_dock ? 1 : 1280,
                           is_taskbar_dock ? 1 : 720);
    const wchar_t* title =
        is_taskbar_dock ? L"WallSyncTaskbar"
                   : is_overlay ? L"WallSyncOverlay"
                   : (is_wallpaper ? L"WallSyncWallpaper"
                                   : L"WallSync Pro");
    LogProcessDiagnostic("native_window_initialization",
                         std::string("result=started title=") +
                             (is_taskbar_dock
                                  ? "WallSyncTaskbar"
                                  : is_overlay
                                  ? "WallSyncOverlay"
                                  : (is_wallpaper ? "WallSyncWallpaper"
                                                  : "WallSync Pro")));
    if (!window.Create(title, origin, size)) {
      LogProcessDiagnostic("native_window_initialization",
                           "result=failed lastError=" +
                               std::to_string(::GetLastError()));
      exit_code = EXIT_FAILURE;
    } else {
      LogProcessDiagnostic(
          "native_window_initialization",
          "result=success hwnd=" +
              std::to_string(reinterpret_cast<intptr_t>(window.GetHandle())));
      if (is_startup_bootstrap) {
        ::ShowWindow(window.GetHandle(), SW_HIDE);
      }
      if ((is_overlay && !is_taskbar_dock) || is_wallpaper) {
        HWND hwnd = window.GetHandle();
        LONG_PTR exStyle = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        exStyle |= WS_EX_TOOLWINDOW;
        exStyle &= ~WS_EX_APPWINDOW;
        ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE, exStyle);

        LONG_PTR style = ::GetWindowLongPtrW(hwnd, GWL_STYLE);
        style &= ~WS_OVERLAPPEDWINDOW;
        style |= WS_POPUP;
        ::SetWindowLongPtrW(hwnd, GWL_STYLE, style);

        ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
      }
      window.SetQuitOnClose(true);

      ::MSG msg;
      BOOL get_message_result = 0;
      LogProcessDiagnostic("window_message_loop", "result=started");
      while ((get_message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      }
      if (get_message_result == -1) {
        exit_code = EXIT_FAILURE;
        LogProcessDiagnostic("window_message_loop",
                             "result=failed error=" +
                                 std::to_string(::GetLastError()));
      }
      LogProcessDiagnostic("window_message_loop",
                           "result=stopped messageResult=" +
                               std::to_string(get_message_result));
    }
  }

  ::timeEndPeriod(1);
  ::CoUninitialize();
  CloseProcessDiagnostics(exit_code);
  return exit_code;
}
