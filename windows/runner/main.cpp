#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <timeapi.h>

// Request high-performance GPU profile from NVIDIA / AMD drivers
extern "C" {
  __declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
  __declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
    return EXIT_FAILURE;
  }

  // Request 1ms system timer precision to eliminate scheduling jitter and jank
  ::timeBeginPeriod(1);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  bool is_overlay = false;
  bool is_wallpaper = false;
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
          return EXIT_SUCCESS;
        }
      }
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  int exit_code = EXIT_SUCCESS;
  {
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    const wchar_t* title =
        is_overlay ? L"WallSyncOverlay"
                   : (is_wallpaper ? L"WallSyncWallpaper"
                                   : L"WallSync Pro");
    if (!window.Create(title, origin, size)) {
      exit_code = EXIT_FAILURE;
    } else {
      if (is_startup_bootstrap) {
        ::ShowWindow(window.GetHandle(), SW_HIDE);
      }
      if (is_overlay || is_wallpaper) {
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
      while ((get_message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      }
      if (get_message_result == -1) {
        exit_code = EXIT_FAILURE;
      }
    }
  }

  ::timeEndPeriod(1);
  ::CoUninitialize();
  return exit_code;
}
