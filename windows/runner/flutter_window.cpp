#include "flutter_window.h"

#include <appmodel.h>

#include <optional>
#include <thread>

#include <flutter/plugin_registrar_windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/base.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

using StartupTaskResult =
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

std::string StartupTaskStateName(
    winrt::Windows::ApplicationModel::StartupTaskState state) {
  using winrt::Windows::ApplicationModel::StartupTaskState;
  switch (state) {
    case StartupTaskState::Enabled:
      return "enabled";
    case StartupTaskState::Disabled:
      return "disabled";
    case StartupTaskState::DisabledByUser:
      return "disabledByUser";
    case StartupTaskState::DisabledByPolicy:
      return "disabledByPolicy";
    case StartupTaskState::EnabledByPolicy:
      return "enabledByPolicy";
    default:
      return "unknown";
  }
}

void SyncPackageStartupTask(bool enabled, StartupTaskResult result) {
  std::thread([enabled, result = std::move(result)]() mutable {
    bool apartment_initialized = false;
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      apartment_initialized = true;
      winrt::Windows::ApplicationModel::StartupTask task{nullptr};
      try {
        task = winrt::Windows::ApplicationModel::StartupTask::GetAsync(L"WallSyncPro").get();
      } catch (...) {
        task = winrt::Windows::ApplicationModel::StartupTask::GetAsync(L"WallSync").get();
      }
      auto state = task.State();
      if (enabled && state == winrt::Windows::ApplicationModel::StartupTaskState::
                                 Disabled) {
        state = task.RequestEnableAsync().get();
      } else if (!enabled &&
                 state == winrt::Windows::ApplicationModel::StartupTaskState::
                              Enabled) {
        task.Disable();
        state = task.State();
      }
      result->Success(flutter::EncodableValue(StartupTaskStateName(state)));
    } catch (const winrt::hresult_error& error) {
      result->Error("STARTUP_TASK_FAILED", winrt::to_string(error.message()));
    } catch (...) {
      result->Error("STARTUP_TASK_FAILED",
                    "An unexpected error occurred while synchronizing the "
                    "packaged Windows startup task.");
    }
    if (apartment_initialized) {
      winrt::uninit_apartment();
    }
  }).detach();
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  live_wallpaper_plugin_ = std::make_unique<LiveWallpaperPlugin>(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(
              flutter_controller_->engine()->GetRegistrarForPlugin(
                  "LiveWallpaperPlugin")));
  startup_task_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "com.wallsync/startup",
          &flutter::StandardMethodCodec::GetInstance());
  startup_task_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() != "sync") {
          result->NotImplemented();
          return;
        }
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("INVALID_ARGUMENT", "Expected a startup settings map.");
          return;
        }
        const auto enabled_entry =
            arguments->find(flutter::EncodableValue("enabled"));
        if (enabled_entry == arguments->end()) {
          result->Error("INVALID_ARGUMENT", "Missing the enabled setting.");
          return;
        }
        const auto* enabled = std::get_if<bool>(&enabled_entry->second);
        if (enabled == nullptr) {
          result->Error("INVALID_ARGUMENT", "The enabled setting must be bool.");
          return;
        }

        UINT32 package_name_length = 0;
        const LONG package_status =
            GetCurrentPackageFullName(&package_name_length, nullptr);
        if (package_status == APPMODEL_ERROR_NO_PACKAGE) {
          result->Success(flutter::EncodableValue("unpackaged"));
          return;
        }
        if (package_status != ERROR_INSUFFICIENT_BUFFER) {
          result->Error("PACKAGE_IDENTITY_FAILED",
                        "Could not determine the Windows package identity.");
          return;
        }
        SyncPackageStartupTask(*enabled, std::move(result));
      });

  return true;
}

void FlutterWindow::OnDestroy() {
  if (startup_task_channel_) {
    startup_task_channel_->SetMethodCallHandler(nullptr);
    startup_task_channel_.reset();
  }
  live_wallpaper_plugin_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

static const UINT kTaskbarCreatedMessage = RegisterWindowMessageW(L"TaskbarCreated");
static const UINT kShowDashboardMessage = RegisterWindowMessageW(L"WallSyncPro_ShowDashboard");

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kTaskbarCreatedMessage) {
    if (startup_task_channel_) {
      startup_task_channel_->InvokeMethod("taskbarCreated", nullptr);
    }
  } else if (message == kShowDashboardMessage) {
    ::ShowWindow(hwnd, SW_SHOW);
    ::ShowWindow(hwnd, SW_RESTORE);
    ::SetForegroundWindow(hwnd);
    if (startup_task_channel_) {
      startup_task_channel_->InvokeMethod("showDashboard", nullptr);
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
