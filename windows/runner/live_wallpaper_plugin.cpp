#define _CRT_SECURE_NO_WARNINGS
// Desktop window discovery and raised-desktop behavior adapted from Lively
// Wallpaper's WinDesktopCore.cs and DesktopUtil.cs (GPL-3.0).

#include "live_wallpaper_plugin.h"

#include <windows.h>
#include <dwmapi.h>
#include <powrprof.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr char kChannelName[] = "wallsync/live_wallpaper";
constexpr UINT kWorkerWMessage = 0x052C;
constexpr GUID kPowerSavingStatus = {
    0xE00958C0, 0xC213, 0x4ACE, {0xAC, 0x77, 0xFE, 0xCC, 0xED, 0x2E, 0xEE, 0xA5}};

struct DesktopWindows {
  HWND shell_owner = nullptr;
  HWND shell_view = nullptr;
  HWND worker = nullptr;
};

BOOL CALLBACK FindDesktopWindows(HWND window, LPARAM parameter) {
  auto* desktop_windows = reinterpret_cast<DesktopWindows*>(parameter);
  HWND shell_view =
      FindWindowExW(window, nullptr, L"SHELLDLL_DefView", nullptr);
  if (!shell_view) {
    return TRUE;
  }

  desktop_windows->shell_owner = window;
  desktop_windows->shell_view = shell_view;
  desktop_windows->worker =
      FindWindowExW(nullptr, window, L"WorkerW", nullptr);
  return FALSE;
}

HWND FindDesktopWallpaperTarget(HWND* insert_after, bool* raised_desktop,
                                bool* use_layered_window) {
  static HWND s_cached_target = nullptr;
  static HWND s_cached_insert_after = nullptr;
  static bool s_cached_raised = false;
  static bool s_cached_layered = false;

  if (s_cached_target && IsWindow(s_cached_target)) {
    *insert_after = s_cached_insert_after;
    *raised_desktop = s_cached_raised;
    *use_layered_window = s_cached_layered;
    return s_cached_target;
  }

  *insert_after = nullptr;
  *raised_desktop = false;
  *use_layered_window = false;
  HWND progman = FindWindowW(L"Progman", L"Program Manager");
  if (!progman) {
    progman = FindWindowW(L"Progman", nullptr);
  }
  if (!progman) {
    return nullptr;
  }

  DWORD_PTR result = 0;
  // Non-blocking timeout with enough margin for Explorer during logon
  SendMessageTimeoutW(progman, kWorkerWMessage, 0xD, 0x1,
                      SMTO_ABORTIFHUNG | SMTO_NORMAL, 250, &result);

  DesktopWindows windows;
  EnumWindows(FindDesktopWindows, reinterpret_cast<LPARAM>(&windows));
  const LONG_PTR progman_style = GetWindowLongPtrW(progman, GWL_EXSTYLE);
  if ((progman_style & WS_EX_NOREDIRECTIONBITMAP) != 0) {
    if (!windows.shell_view) {
      return nullptr;
    }
    *raised_desktop = true;
    *use_layered_window = true;
    *insert_after = windows.shell_view;
    s_cached_target = progman;
    s_cached_insert_after = windows.shell_view;
    s_cached_raised = true;
    s_cached_layered = true;
    return progman;
  }

  if (!windows.shell_owner) {
    s_cached_target = progman;
    s_cached_insert_after = nullptr;
    s_cached_raised = false;
    s_cached_layered = false;
    return progman;
  }

  if (windows.worker) {
    RECT rect{};
    if (GetClientRect(windows.worker, &rect) && rect.right - rect.left > 500 &&
        rect.bottom - rect.top > 500) {
      s_cached_target = windows.worker;
      s_cached_insert_after = nullptr;
      s_cached_raised = false;
      s_cached_layered = false;
      return windows.worker;
    }
  }

  *insert_after = windows.shell_view;
  s_cached_target = windows.shell_owner;
  s_cached_insert_after = windows.shell_view;
  s_cached_raised = false;
  s_cached_layered = false;
  return windows.shell_owner;
}

int GetIntFromEncodable(const flutter::EncodableValue& val, int default_val = 0) {
  if (std::holds_alternative<int>(val)) {
    return std::get<int>(val);
  }
  if (std::holds_alternative<int64_t>(val)) {
    return static_cast<int>(std::get<int64_t>(val));
  }
  if (std::holds_alternative<double>(val)) {
    return static_cast<int>(std::get<double>(val));
  }
  return default_val;
}

bool GetBoolFromEncodable(const flutter::EncodableValue& val, bool default_val = false) {
  if (std::holds_alternative<bool>(val)) {
    return std::get<bool>(val);
  }
  return default_val;
}

std::string GetStringFromEncodable(const flutter::EncodableValue& val, const std::string& default_val = "") {
  if (std::holds_alternative<std::string>(val)) {
    return std::get<std::string>(val);
  }
  return default_val;
}

std::wstring Utf8ToWide(const std::string& utf8_str) {
  if (utf8_str.empty()) return std::wstring();
  int size_needed = MultiByteToWideChar(CP_UTF8, 0, utf8_str.data(),
                                        static_cast<int>(utf8_str.size()),
                                        nullptr, 0);
  if (size_needed <= 0) return std::wstring();
  std::wstring result(size_needed, 0);
  MultiByteToWideChar(CP_UTF8, 0, utf8_str.data(),
                      static_cast<int>(utf8_str.size()),
                      &result[0], size_needed);
  return result;
}

}  // namespace

class LiveWallpaperPlugin::Impl {
 public:
  explicit Impl(flutter::PluginRegistrarWindows* registrar);
  ~Impl();

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool AttachToDesktop();
  bool IsFullscreenForegroundWindow() const;
  void RefreshBatterySaverStatus();
  std::optional<LRESULT> HandleWindowMessage(HWND hwnd,
                                             UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam);

  flutter::EncodableMap StartMpv(const flutter::EncodableMap* args);
  flutter::EncodableMap PollMpvStart();
  bool SetMpvSettings(const flutter::EncodableMap* args);
  bool StopMpv();

  std::wstring FindMpvExecutable();
  void SendMpvCommand(const std::string& json_cmd);
  HWND FindMpvWindow(DWORD pid, int timeout_ms);
  bool ReparentMpvWindow(HWND mpv_hwnd, int* out_width, int* out_height,
                         std::string* failure_reason,
                         double* out_desktop_target_lookup_ms);

 private:
  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  HWND root_window_;
  HPOWERNOTIFY power_notification_ = nullptr;
  int window_proc_delegate_id_ = 0;
  bool battery_saver_enabled_ = false;

  HANDLE mpv_process_handle_ = nullptr;
  DWORD mpv_pid_ = 0;
  HWND mpv_hwnd_ = nullptr;
  bool mpv_window_attached_ = false;
  bool mpv_window_visible_ = false;
  int mpv_width_ = 0;
  int mpv_height_ = 0;
  std::string mpv_pipe_name_;
  std::string mpv_ipc_read_buffer_;
  HANDLE mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
  bool mpv_frame_decoded_ = false;
  std::chrono::steady_clock::time_point mpv_launch_started_{};
  double mpv_previous_cleanup_ms_ = 0.0;
  double mpv_executable_lookup_ms_ = 0.0;
  double mpv_process_launch_ms_ = 0.0;
  double mpv_window_discovered_ms_ = -1.0;
  double mpv_window_discovery_call_ms_ = -1.0;
  double mpv_window_attach_ms_ = -1.0;
  double mpv_window_attachment_call_ms_ = -1.0;
  double mpv_desktop_target_lookup_ms_ = -1.0;
  double mpv_visible_request_ms_ = -1.0;
  double mpv_visible_confirmed_ms_ = -1.0;
  double mpv_ipc_connect_ms_ = -1.0;
  double mpv_output_configured_ms_ = -1.0;
  double mpv_frame_ready_ms_ = -1.0;
  double mpv_dwm_flush_ms_ = -1.0;
  std::chrono::steady_clock::time_point mpv_last_frame_query_{};
};

LiveWallpaperPlugin::Impl::Impl(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      window_(registrar->GetView()
                  ? registrar->GetView()->GetNativeWindow()
                  : nullptr) {
  root_window_ = window_ ? GetAncestor(window_, GA_ROOT) : nullptr;
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar_->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowMessage(hwnd, message, wparam, lparam);
      });
  if (window_) {
    power_notification_ =
        RegisterPowerSettingNotification(root_window_, &kPowerSavingStatus,
                                         DEVICE_NOTIFY_WINDOW_HANDLE);
    RefreshBatterySaverStatus();
  }
}

LiveWallpaperPlugin::Impl::~Impl() {
  channel_->SetMethodCallHandler(nullptr);
  if (window_proc_delegate_id_ != 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
  }
  if (power_notification_) {
    UnregisterPowerSettingNotification(power_notification_);
  }
  StopMpv();
}

void LiveWallpaperPlugin::Impl::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "startMpv") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    flutter::EncodableMap res = StartMpv(args);
    if (res.empty()) {
      result->Error("MPV_START_FAILED", "Failed to start or attach MPV live wallpaper.");
    } else {
      result->Success(flutter::EncodableValue(res));
    }
    return;
  }
  if (call.method_name() == "pollMpvStart") {
    flutter::EncodableMap res = PollMpvStart();
    if (res.empty()) {
      result->Error("MPV_START_FAILED", "MPV exited or could not attach to the desktop.");
    } else {
      result->Success(flutter::EncodableValue(res));
    }
    return;
  }
  if (call.method_name() == "setMpvSettings") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    result->Success(flutter::EncodableValue(SetMpvSettings(args)));
    return;
  }
  if (call.method_name() == "stopMpv") {
    result->Success(flutter::EncodableValue(StopMpv()));
    return;
  }
  if (call.method_name() == "attachToDesktop") {
    result->Success(flutter::EncodableValue(AttachToDesktop()));
    return;
  }
  if (call.method_name() == "getPlaybackPolicy") {
    RefreshBatterySaverStatus();
    flutter::EncodableMap policy;
    policy[flutter::EncodableValue("fullscreen")] =
        flutter::EncodableValue(IsFullscreenForegroundWindow());
    policy[flutter::EncodableValue("batterySaver")] =
        flutter::EncodableValue(battery_saver_enabled_);
    result->Success(flutter::EncodableValue(policy));
    return;
  }
  result->NotImplemented();
}

std::wstring LiveWallpaperPlugin::Impl::FindMpvExecutable() {
  wchar_t buffer[MAX_PATH];
  GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  std::filesystem::path exe_path(buffer);
  std::filesystem::path bin_dir = exe_path.parent_path();
  std::filesystem::path parent_bin = bin_dir.parent_path();

  std::vector<std::filesystem::path> candidates = {
      bin_dir / L"plugins" / L"mpv" / L"mpv.exe",
      bin_dir / L"runtime" / L"mpv" / L"mpv.exe",
      bin_dir / L"mpv.exe",
      parent_bin / L"plugins" / L"mpv" / L"mpv.exe",
      parent_bin / L"runtime" / L"mpv" / L"mpv.exe",
      parent_bin / L"mpv.exe",
  };

  wchar_t env_buf[MAX_PATH];
  if (GetEnvironmentVariableW(L"WALLSYNC_MPV_PATH", env_buf, MAX_PATH) > 0) {
    candidates.insert(candidates.begin(), std::filesystem::path(env_buf));
  }
  if (GetEnvironmentVariableW(L"LOCALAPPDATA", env_buf, MAX_PATH) > 0) {
    candidates.push_back(std::filesystem::path(env_buf) / L"WallSync" / L"plugins" / L"mpv" / L"mpv.exe");
    candidates.push_back(std::filesystem::path(env_buf) / L"WallSync" / L"runtime" / L"mpv" / L"mpv.exe");
    candidates.push_back(std::filesystem::path(env_buf) / L"Lively Wallpaper" / L"plugins" / L"mpv" / L"mpv.exe");
  }
  if (GetEnvironmentVariableW(L"ProgramFiles", env_buf, MAX_PATH) > 0) {
    candidates.push_back(std::filesystem::path(env_buf) / L"Lively Wallpaper" / L"plugins" / L"mpv" / L"mpv.exe");
  }

  for (const auto& p : candidates) {
    std::error_code ec;
    if (std::filesystem::exists(p, ec)) {
      return p.wstring();
    }
  }

  return L"";
}

void LiveWallpaperPlugin::Impl::SendMpvCommand(const std::string& json_cmd) {
  if (mpv_pipe_name_.empty()) return;
  std::wstring full_pipe = LR"(\\.\pipe\)" + Utf8ToWide(mpv_pipe_name_);

  if (mpv_pipe_handle_ == nullptr || mpv_pipe_handle_ == INVALID_HANDLE_VALUE) {
    // Method-channel handlers run on the platform thread. Do a single
    // non-waiting connection attempt; startup polling will retry when MPV is
    // ready, without pausing Flutter's message loop here.
    mpv_pipe_handle_ = CreateFileW(
        full_pipe.c_str(), GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, 0, nullptr);
  }

  if (mpv_pipe_handle_ != INVALID_HANDLE_VALUE && mpv_pipe_handle_ != nullptr) {
    std::string payload = json_cmd + "\n";
    DWORD written = 0;
    BOOL ok = WriteFile(mpv_pipe_handle_, payload.c_str(),
                        static_cast<DWORD>(payload.length()), &written, nullptr);
    if (ok) {
    } else {
      CloseHandle(mpv_pipe_handle_);
      mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
    }
  }
}

namespace {
struct MpvEnumContext {
  DWORD target_pid;
  HWND found_hwnd;
};

BOOL CALLBACK EnumMpvWindowsCallback(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<MpvEnumContext*>(lparam);
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == ctx->target_pid) {
    wchar_t class_name[256];
    if (GetClassNameW(hwnd, class_name, 256) > 0) {
      // Strictly match MPV's window class to avoid hooking system IME/UAC windows
      if (wcscmp(class_name, L"mpv") == 0 || wcscmp(class_name, L"mpv2") == 0) {
        ctx->found_hwnd = hwnd;
        return FALSE; // Found primary MPV window, stop enumerating
      }
    }
  }
  return TRUE;
}
}  // namespace

HWND LiveWallpaperPlugin::Impl::FindMpvWindow(DWORD pid, int timeout_ms) {
  auto start = std::chrono::steady_clock::now();
  do {
    MpvEnumContext ctx{pid, nullptr};
    EnumWindows(EnumMpvWindowsCallback, reinterpret_cast<LPARAM>(&ctx));
    if (ctx.found_hwnd && IsWindow(ctx.found_hwnd)) {
      return ctx.found_hwnd;
    }
    if (timeout_ms <= 0) {
      break;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - start)
                             .count();
    const auto remaining = timeout_ms - static_cast<int>(elapsed);
    if (remaining <= 0) {
      break;
    }
    std::this_thread::sleep_for(
        std::chrono::milliseconds(remaining < 50 ? remaining : 50));
  } while (std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now() - start)
               .count() < timeout_ms);
  return nullptr;
}

bool LiveWallpaperPlugin::Impl::ReparentMpvWindow(
    HWND mpv_hwnd, int* out_width, int* out_height,
    std::string* failure_reason, double* out_desktop_target_lookup_ms) {
  auto fail = [failure_reason](const std::string& message) {
    if (failure_reason) *failure_reason = message;
    return false;
  };
  if (!mpv_hwnd || !IsWindow(mpv_hwnd)) {
    return fail("MPV window handle is invalid");
  }

  HWND insert_after = nullptr;
  bool raised_desktop = false;
  bool use_layered_window = false;
  const auto desktop_target_lookup_started = std::chrono::steady_clock::now();
  HWND desktop_target = FindDesktopWallpaperTarget(&insert_after, &raised_desktop, &use_layered_window);
  if (out_desktop_target_lookup_ms) {
    *out_desktop_target_lookup_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - desktop_target_lookup_started).count();
  }
  if (!desktop_target || !IsWindow(desktop_target)) {
    return fail("desktop wallpaper host window was not found");
  }

  RECT rect{};
  if (!GetClientRect(desktop_target, &rect)) {
    return fail("GetClientRect failed with Win32 error " +
                std::to_string(GetLastError()));
  }
  int width = rect.right - rect.left;
  int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) {
    width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  }
  if (width <= 0 || height <= 0) {
    width = GetSystemMetrics(SM_CXSCREEN);
    height = GetSystemMetrics(SM_CYSCREEN);
  }
  if (width <= 0 || height <= 0) {
    return fail("desktop host has no usable display dimensions");
  }

  if (out_width) *out_width = width;
  if (out_height) *out_height = height;

  if (raised_desktop) {
    SetWindowLongPtrW(mpv_hwnd, GWL_STYLE, WS_CHILD);
  } else {
    LONG_PTR style = GetWindowLongPtrW(mpv_hwnd, GWL_STYLE);
    style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
               WS_MAXIMIZEBOX | WS_SYSMENU);
    style |= WS_CHILD;
    SetWindowLongPtrW(mpv_hwnd, GWL_STYLE, style);
  }

  LONG_PTR extended_style = GetWindowLongPtrW(mpv_hwnd, GWL_EXSTYLE);
  extended_style &= ~WS_EX_APPWINDOW;
  extended_style |= WS_EX_TOOLWINDOW;
  SetWindowLongPtrW(mpv_hwnd, GWL_EXSTYLE, extended_style);

  SetLastError(ERROR_SUCCESS);
  SetParent(mpv_hwnd, desktop_target);
  if (GetParent(mpv_hwnd) != desktop_target) {
    return fail("SetParent failed with Win32 error " +
                std::to_string(GetLastError()));
  }

  const UINT flags = SWP_SHOWWINDOW | (raised_desktop ? SWP_NOACTIVATE : 0) |
                     (insert_after ? 0 : SWP_NOZORDER);
  if (!SetWindowPos(mpv_hwnd, insert_after, 0, 0, width, height, flags)) {
    return fail("SetWindowPos failed with Win32 error " +
                std::to_string(GetLastError()));
  }
  return true;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::StartMpv(const flutter::EncodableMap* args) {
  const auto start_call = std::chrono::steady_clock::now();
  if (!StopMpv()) {
    flutter::EncodableMap failure;
    failure[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Previous WallSync MPV process did not shut down.");
    return failure;
  }
  mpv_previous_cleanup_ms_ = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - start_call).count();

  const auto lookup_started = std::chrono::steady_clock::now();
  std::wstring mpv_path;
  if (args) {
    auto it_mpv = args->find(flutter::EncodableValue("mpvPath"));
    if (it_mpv != args->end()) {
      std::string requested = GetStringFromEncodable(it_mpv->second);
      if (!requested.empty()) {
        std::wstring wide_requested = Utf8ToWide(requested);
        std::error_code ec;
        if (std::filesystem::exists(wide_requested, ec)) {
          mpv_path = wide_requested;
        }
      }
    }
  }
  if (mpv_path.empty()) {
    mpv_path = FindMpvExecutable();
  }
  mpv_executable_lookup_ms_ = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - lookup_started).count();
  if (mpv_path.empty()) {
    flutter::EncodableMap failure;
    failure[flutter::EncodableValue("stage")] = flutter::EncodableValue("executable_lookup");
    failure[flutter::EncodableValue("error")] = flutter::EncodableValue("Bundled MPV runtime executable not found.");
    failure[flutter::EncodableValue("cleanupMs")] = flutter::EncodableValue(mpv_previous_cleanup_ms_);
    failure[flutter::EncodableValue("lookupMs")] = flutter::EncodableValue(mpv_executable_lookup_ms_);
    return failure;
  }

  std::string video_path;
  int volume = 100;
  bool is_muted = false;
  std::string fit = "fill";
  bool is_loop = true;

  if (args) {
    auto it_path = args->find(flutter::EncodableValue("path"));
    if (it_path != args->end()) {
      video_path = GetStringFromEncodable(it_path->second);
    }
    auto it_vol = args->find(flutter::EncodableValue("volume"));
    if (it_vol != args->end()) {
      volume = GetIntFromEncodable(it_vol->second, 100);
    }
    auto it_muted = args->find(flutter::EncodableValue("muted"));
    if (it_muted != args->end()) {
      is_muted = GetBoolFromEncodable(it_muted->second, false);
    }
    auto it_fit = args->find(flutter::EncodableValue("fit"));
    if (it_fit != args->end()) {
      fit = GetStringFromEncodable(it_fit->second, "fill");
    }
    auto it_loop = args->find(flutter::EncodableValue("loop"));
    if (it_loop != args->end()) {
      is_loop = GetBoolFromEncodable(it_loop->second, true);
    }
  }

  if (video_path.empty()) {
    return {};
  }

  auto now = std::chrono::steady_clock::now().time_since_epoch().count();
  mpv_pipe_name_ = "wallsync_mpv_ipc_" + std::to_string(now);
  mpv_ipc_read_buffer_.clear();

  std::wstring wide_pipe = LR"(\\.\pipe\)" + Utf8ToWide(mpv_pipe_name_);

  std::wstringstream cmd_stream;
  cmd_stream << L"\"" << mpv_path << L"\""
             << (is_muted || volume <= 0 ? L" --mute=yes" : L" --mute=no")
             << L" --volume=" << std::clamp(volume, 0, 100)
             << L" --volume-max=100"
             << L" --ao=wasapi"
             << L" --audio-client-name=WallSync"
             << L" --aid=auto"
             << (is_loop ? L" --loop-file=inf" : L" --loop-file=no")
             << L" --keep-open=yes"
             << L" --media-controls=no"
             << L" --geometry=-9999:0"
             << L" --force-window=yes"
             << L" --no-window-dragging"
             << L" --cursor-autohide=no"
             << L" --stop-screensaver=no"
             << L" --input-default-bindings=no"
             << L" --no-border"
             << L" --input-cursor=no"
             << L" --no-osc"
             << L" --input-ipc-server=" << wide_pipe
             << L" --gpu-api=d3d11"
             << L" --hwdec=d3d11va,auto-safe"
             << L" --demuxer-max-bytes=24MiB"
             << L" --demuxer-max-back-bytes=8MiB"
             << L" --cache-secs=4"
             << L" --hr-seek=no"
             << L" --priority=normal"
             << L" --script-opts=osc-visibility=never"
             << L" --no-config";

  if (fit == "stretch") {
    cmd_stream << L" --keepaspect=no --panscan=0.0";
  } else if (fit == "fit") {
    cmd_stream << L" --keepaspect=yes --panscan=0.0";
  } else {
    cmd_stream << L" --keepaspect=yes --panscan=1.0";
  }

  std::wstring wide_video = Utf8ToWide(video_path);
  std::replace(wide_video.begin(), wide_video.end(), L'\\', L'/');
  cmd_stream << L" -- \"" << wide_video << L"\"";

  std::wstring cmd_line = cmd_stream.str();
  std::vector<wchar_t> cmd_line_writable(cmd_line.begin(), cmd_line.end());
  cmd_line_writable.push_back(L'\0');

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  const std::wstring mpv_directory =
      std::filesystem::path(mpv_path).parent_path().wstring();
  mpv_launch_started_ = std::chrono::steady_clock::now();
  mpv_process_launch_ms_ = 0.0;
  mpv_window_discovered_ms_ = -1.0;
  mpv_window_discovery_call_ms_ = -1.0;
  mpv_window_attach_ms_ = -1.0;
  mpv_window_attachment_call_ms_ = -1.0;
  mpv_desktop_target_lookup_ms_ = -1.0;
  mpv_visible_request_ms_ = -1.0;
  mpv_visible_confirmed_ms_ = -1.0;
  mpv_ipc_connect_ms_ = -1.0;
  mpv_output_configured_ms_ = -1.0;
  mpv_frame_ready_ms_ = -1.0;
  mpv_dwm_flush_ms_ = -1.0;
  mpv_last_frame_query_ = std::chrono::steady_clock::now() - std::chrono::milliseconds(100);

  BOOL success = CreateProcessW(
      nullptr, cmd_line_writable.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, mpv_directory.c_str(), &si, &pi);

  if (!success) {
    DWORD err = GetLastError();
    std::string err_desc;
    if (err == ERROR_FILE_NOT_FOUND) {
      err_desc = "MPV executable not found on disk.";
    } else if (err == ERROR_MOD_NOT_FOUND) {
      err_desc = "Required MPV DLL dependency not found (Win32 Error 126).";
    } else if (err == ERROR_BAD_EXE_FORMAT) {
      err_desc = "MPV executable architecture mismatch or corrupted binary (Win32 Error 193).";
    } else if (err == ERROR_ACCESS_DENIED) {
      err_desc = "Access denied when launching MPV executable (Win32 Error 5).";
    } else {
      err_desc = "Failed to launch MPV process (Win32 Error " + std::to_string(err) + ").";
    }
    flutter::EncodableMap failure;
    failure[flutter::EncodableValue("stage")] = flutter::EncodableValue("process_launch");
    failure[flutter::EncodableValue("error")] = flutter::EncodableValue(err_desc);
    failure[flutter::EncodableValue("win32Error")] = flutter::EncodableValue(static_cast<int>(err));
    failure[flutter::EncodableValue("launchMs")] = flutter::EncodableValue(0.0);
    failure[flutter::EncodableValue("cleanupMs")] = flutter::EncodableValue(mpv_previous_cleanup_ms_);
    failure[flutter::EncodableValue("lookupMs")] = flutter::EncodableValue(mpv_executable_lookup_ms_);
    return failure;
  }
  mpv_process_launch_ms_ = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - mpv_launch_started_).count();

  CloseHandle(pi.hThread);
  mpv_process_handle_ = pi.hProcess;
  mpv_pid_ = pi.dwProcessId;

  flutter::EncodableMap result;
  result[flutter::EncodableValue("pending")] = flutter::EncodableValue(true);
  result[flutter::EncodableValue("pid")] = flutter::EncodableValue(static_cast<int>(mpv_pid_));
  result[flutter::EncodableValue("cleanupMs")] = flutter::EncodableValue(mpv_previous_cleanup_ms_);
  result[flutter::EncodableValue("lookupMs")] = flutter::EncodableValue(mpv_executable_lookup_ms_);
  result[flutter::EncodableValue("launchMs")] = flutter::EncodableValue(mpv_process_launch_ms_);
  return result;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::PollMpvStart() {
  if (!mpv_process_handle_ || mpv_pid_ == 0) return {};
  auto add_phase_times = [this](flutter::EncodableMap& result) {
    const double elapsed = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - mpv_launch_started_).count();
    result[flutter::EncodableValue("launchMs")] = flutter::EncodableValue(mpv_process_launch_ms_);
    result[flutter::EncodableValue("cleanupMs")] = flutter::EncodableValue(mpv_previous_cleanup_ms_);
    result[flutter::EncodableValue("lookupMs")] = flutter::EncodableValue(mpv_executable_lookup_ms_);
    result[flutter::EncodableValue("windowFoundMs")] = flutter::EncodableValue(mpv_window_discovered_ms_);
    result[flutter::EncodableValue("windowDiscoveryCallMs")] = flutter::EncodableValue(mpv_window_discovery_call_ms_);
    result[flutter::EncodableValue("attachMs")] = flutter::EncodableValue(mpv_window_attach_ms_);
    result[flutter::EncodableValue("windowAttachmentCallMs")] = flutter::EncodableValue(mpv_window_attachment_call_ms_);
    result[flutter::EncodableValue("desktopTargetLookupMs")] = flutter::EncodableValue(mpv_desktop_target_lookup_ms_);
    result[flutter::EncodableValue("visibleRequestMs")] = flutter::EncodableValue(mpv_visible_request_ms_);
    result[flutter::EncodableValue("visibleConfirmedMs")] = flutter::EncodableValue(mpv_visible_confirmed_ms_);
    result[flutter::EncodableValue("ipcMs")] = flutter::EncodableValue(mpv_ipc_connect_ms_);
    result[flutter::EncodableValue("outputConfiguredMs")] = flutter::EncodableValue(mpv_output_configured_ms_);
    result[flutter::EncodableValue("frameReadyMs")] = flutter::EncodableValue(mpv_frame_ready_ms_);
    result[flutter::EncodableValue("dwmFlushMs")] = flutter::EncodableValue(mpv_dwm_flush_ms_);
    result[flutter::EncodableValue("elapsedMs")] = flutter::EncodableValue(elapsed);
    result[flutter::EncodableValue("windowAttached")] = flutter::EncodableValue(mpv_window_attached_);
    result[flutter::EncodableValue("windowVisible")] = flutter::EncodableValue(mpv_window_visible_);
    result[flutter::EncodableValue("ipcConnected")] = flutter::EncodableValue(mpv_pipe_handle_ != INVALID_HANDLE_VALUE && mpv_pipe_handle_ != nullptr);
    result[flutter::EncodableValue("frameDecoded")] = flutter::EncodableValue(mpv_frame_decoded_);
  };

  DWORD exit_code = 0;
  if (!GetExitCodeProcess(mpv_process_handle_, &exit_code) || exit_code != STILL_ACTIVE) {
    flutter::EncodableMap fail_res;
    fail_res[flutter::EncodableValue("error")] = flutter::EncodableValue(
        "MPV process exited prematurely with exit code: " + std::to_string(exit_code));
    add_phase_times(fail_res);
    StopMpv();
    return fail_res;
  }

  if (!mpv_hwnd_ || !IsWindow(mpv_hwnd_)) {
    // Keep each platform-thread call short. Dart polls this method
    // asynchronously while Flutter continues processing frames and input.
    const auto discovery_call_started = std::chrono::steady_clock::now();
    mpv_hwnd_ = FindMpvWindow(mpv_pid_, 0);
    mpv_window_discovery_call_ms_ = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - discovery_call_started).count();
    if (mpv_hwnd_) {
      mpv_window_discovered_ms_ = std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - mpv_launch_started_).count();
    }
  }

  // Connect without a retry loop here; a later poll can retry if MPV has not
  // opened its IPC pipe yet.
  if (mpv_pipe_handle_ == INVALID_HANDLE_VALUE || mpv_pipe_handle_ == nullptr) {
    std::wstring full_pipe = LR"(\\.\pipe\)" + Utf8ToWide(mpv_pipe_name_);
    mpv_pipe_handle_ = CreateFileW(
        full_pipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, 0, nullptr);
    if (mpv_pipe_handle_ == INVALID_HANDLE_VALUE) {
      flutter::EncodableMap pending;
      pending[flutter::EncodableValue("pending")] = flutter::EncodableValue(true);
      add_phase_times(pending);
      return pending;
    }
    mpv_ipc_connect_ms_ = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - mpv_launch_started_).count();
  }

  // Do not treat a discovered window or configured video output as playback.
  // video-frame-info becomes an object only after MPV has decoded a frame.
  if (!mpv_frame_decoded_) {
    DWORD bytes_avail = 0;
    if (PeekNamedPipe(mpv_pipe_handle_, nullptr, 0, nullptr, &bytes_avail, nullptr) && bytes_avail > 0) {
      std::vector<char> buffer(bytes_avail + 1, 0);
      DWORD bytes_read = 0;
      if (ReadFile(mpv_pipe_handle_, buffer.data(), bytes_avail, &bytes_read, nullptr) && bytes_read > 0) {
        mpv_ipc_read_buffer_.append(buffer.data(), bytes_read);
        size_t newline = std::string::npos;
        while ((newline = mpv_ipc_read_buffer_.find('\n')) != std::string::npos) {
          const std::string response = mpv_ipc_read_buffer_.substr(0, newline);
          mpv_ipc_read_buffer_.erase(0, newline + 1);
          if (response.find("\"request_id\":2") != std::string::npos &&
              response.find("\"data\":true") != std::string::npos &&
              mpv_output_configured_ms_ < 0.0) {
            mpv_output_configured_ms_ = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - mpv_launch_started_).count();
          }
          const auto frame_info_data = response.find("\"data\":");
          if (response.find("\"request_id\":4") != std::string::npos &&
              response.find("\"error\":\"success\"") != std::string::npos &&
              frame_info_data != std::string::npos &&
              response.find("\"picture-type\"", frame_info_data) !=
                  std::string::npos) {
            mpv_frame_decoded_ = true;
            mpv_frame_ready_ms_ = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - mpv_launch_started_).count();
          }
        }
      }
    }

    if (!mpv_frame_decoded_) {
      const auto now = std::chrono::steady_clock::now();
      if (now - mpv_last_frame_query_ >= std::chrono::milliseconds(100)) {
        const std::string output_query =
            "{\"command\":[\"get_property\",\"vo-configured\"],\"request_id\":2}\n";
        DWORD written = 0;
        WriteFile(mpv_pipe_handle_, output_query.c_str(),
                  static_cast<DWORD>(output_query.length()), &written, nullptr);
        const std::string frame_info_query =
            "{\"command\":[\"get_property\",\"video-frame-info\"],\"request_id\":4}\n";
        WriteFile(mpv_pipe_handle_, frame_info_query.c_str(),
                  static_cast<DWORD>(frame_info_query.length()), &written, nullptr);
        mpv_last_frame_query_ = now;
      }

      flutter::EncodableMap pending;
      pending[flutter::EncodableValue("pending")] = flutter::EncodableValue(true);
      add_phase_times(pending);
      return pending;
    }
  }

  // Keep the current desktop visible while MPV initializes off-screen. Only
  // expose the owned window after playback has advanced beyond its first frame.
  if (!mpv_window_attached_) {
    if (!mpv_hwnd_ || !IsWindow(mpv_hwnd_)) {
      flutter::EncodableMap pending;
      pending[flutter::EncodableValue("pending")] = flutter::EncodableValue(true);
      add_phase_times(pending);
      return pending;
    }
    std::string attach_failure;
    const auto attachment_call_started = std::chrono::steady_clock::now();
    if (!ReparentMpvWindow(mpv_hwnd_, &mpv_width_, &mpv_height_,
                           &attach_failure, &mpv_desktop_target_lookup_ms_)) {
      mpv_window_attachment_call_ms_ =
          std::chrono::duration<double, std::milli>(
              std::chrono::steady_clock::now() - attachment_call_started)
              .count();
      const double elapsed = std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - mpv_launch_started_).count();
      if (elapsed < 15000.0) {
        flutter::EncodableMap pending;
        pending[flutter::EncodableValue("pending")] = flutter::EncodableValue(true);
        add_phase_times(pending);
        return pending;
      }
      flutter::EncodableMap fail_res;
      fail_res[flutter::EncodableValue("error")] = flutter::EncodableValue(
          "Failed to reparent MPV window to desktop target: " +
          attach_failure);
      add_phase_times(fail_res);
      StopMpv();
      return fail_res;
    }
    mpv_window_attachment_call_ms_ =
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - attachment_call_started)
            .count();
    mpv_window_attached_ = true;
    mpv_window_attach_ms_ = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - mpv_launch_started_).count();
    mpv_visible_request_ms_ = mpv_window_attach_ms_;
    const auto dwm_flush_started = std::chrono::steady_clock::now();
    const HRESULT composition_result = DwmFlush();
    mpv_dwm_flush_ms_ = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - dwm_flush_started).count();
    mpv_window_visible_ =
        SUCCEEDED(composition_result) && IsWindowVisible(mpv_hwnd_);
    if (!mpv_window_visible_) {
      flutter::EncodableMap fail_res;
      fail_res[flutter::EncodableValue("error")] = flutter::EncodableValue(
          "MPV window attached but desktop composition did not confirm visibility.");
      add_phase_times(fail_res);
      StopMpv();
      return fail_res;
    }
    mpv_visible_confirmed_ms_ = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - mpv_launch_started_).count();
  }

  flutter::EncodableMap result;
  result[flutter::EncodableValue("success")] = flutter::EncodableValue(true);
  result[flutter::EncodableValue("pid")] = flutter::EncodableValue(static_cast<int>(mpv_pid_));
  result[flutter::EncodableValue("width")] = flutter::EncodableValue(mpv_width_);
  result[flutter::EncodableValue("height")] = flutter::EncodableValue(mpv_height_);
  add_phase_times(result);
  return result;
}

bool LiveWallpaperPlugin::Impl::SetMpvSettings(const flutter::EncodableMap* args) {
  if (!args || mpv_pipe_name_.empty()) return false;

  auto it_muted = args->find(flutter::EncodableValue("muted"));
  bool is_muted = false;
  if (it_muted != args->end()) {
    is_muted = GetBoolFromEncodable(it_muted->second, false);
  }

  auto it_vol = args->find(flutter::EncodableValue("volume"));
  int volume = 100;
  if (it_vol != args->end()) {
    volume = GetIntFromEncodable(it_vol->second, 100);
  }
  volume = std::clamp(volume, 0, 100);

  if (is_muted || volume <= 0) {
    SendMpvCommand(R"({"command":["set_property","mute",true]})");
  } else {
    SendMpvCommand(R"({"command":["set_property","mute",false]})");
    std::string vol_cmd = R"({"command":["set_property","volume",)" + std::to_string(volume) + "]}";
    SendMpvCommand(vol_cmd);
  }

  auto it_loop = args->find(flutter::EncodableValue("loop"));
  if (it_loop != args->end()) {
    bool loop = GetBoolFromEncodable(it_loop->second, true);
    SendMpvCommand(loop ? R"({"command":["set_property","loop-file","inf"]})"
                        : R"({"command":["set_property","loop-file","no"]})");
  }

  auto it_fit = args->find(flutter::EncodableValue("fit"));
  if (it_fit != args->end()) {
    std::string fit = GetStringFromEncodable(it_fit->second, "fill");
    if (fit == "fill") {
      SendMpvCommand(R"({"command":["set_property","video-unscaled",false]})");
      SendMpvCommand(R"({"command":["set_property","keepaspect",true]})");
      SendMpvCommand(R"({"command":["set_property","panscan",1.0]})");
    } else if (fit == "fit") {
      SendMpvCommand(R"({"command":["set_property","video-unscaled",false]})");
      SendMpvCommand(R"({"command":["set_property","keepaspect",true]})");
      SendMpvCommand(R"({"command":["set_property","panscan",0.0]})");
    } else if (fit == "stretch") {
      SendMpvCommand(R"({"command":["set_property","video-unscaled",false]})");
      SendMpvCommand(R"({"command":["set_property","keepaspect",false]})");
      SendMpvCommand(R"({"command":["set_property","panscan",0.0]})");
    }
  }

  auto it_speed = args->find(flutter::EncodableValue("speed"));
  if (it_speed != args->end()) {
    double speed = 1.0;
    if (std::holds_alternative<double>(it_speed->second)) {
      speed = std::get<double>(it_speed->second);
    } else if (std::holds_alternative<int64_t>(it_speed->second)) {
      speed = static_cast<double>(std::get<int64_t>(it_speed->second));
    }
    if (speed >= 0.25 && speed <= 3.0) {
      std::string speed_cmd = R"({"command":["set_property","speed",)" + std::to_string(speed) + "]}";
      SendMpvCommand(speed_cmd);
    }
  }

  auto it_paused = args->find(flutter::EncodableValue("paused"));
  if (it_paused != args->end()) {
    bool paused = GetBoolFromEncodable(it_paused->second, false);
    SendMpvCommand(paused ? R"({"command":["set_property","pause",true]})"
                          : R"({"command":["set_property","pause",false]})");
  }

  return true;
}

bool LiveWallpaperPlugin::Impl::StopMpv() {
  if (mpv_hwnd_ && IsWindow(mpv_hwnd_)) {
    ShowWindow(mpv_hwnd_, SW_HIDE);
  }

  if (mpv_process_handle_) {
    DWORD exit_code = 0;
    const BOOL got_code = GetExitCodeProcess(mpv_process_handle_, &exit_code);
    if (!got_code || exit_code == STILL_ACTIVE) {
      if (!mpv_pipe_name_.empty()) {
        SendMpvCommand(R"({"command":["quit"]})");
      }

      // Close the pipe handle promptly after sending quit so MPV detects EOF
      // and does not block its IPC thread on active connection buffers.
      if (mpv_pipe_handle_ != INVALID_HANDLE_VALUE && mpv_pipe_handle_ != nullptr) {
        CloseHandle(mpv_pipe_handle_);
        mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
      }

      // Allow up to 2500ms for graceful direct3d / hardware teardown.
      DWORD wait_status = WaitForSingleObject(mpv_process_handle_, 2500);
      if (wait_status == WAIT_TIMEOUT) {
        // Graceful shutdown timed out; forcefully terminate only this owned process.
        TerminateProcess(mpv_process_handle_, 0);
        wait_status = WaitForSingleObject(mpv_process_handle_, 2000);
      }

      // Verify that the process has actually terminated before confirming shutdown.
      if (wait_status != WAIT_OBJECT_0) {
        DWORD final_code = 0;
        if (GetExitCodeProcess(mpv_process_handle_, &final_code) &&
            final_code == STILL_ACTIVE) {
          return false;
        }
      }
    }

    CloseHandle(mpv_process_handle_);
    mpv_process_handle_ = nullptr;
  }

  if (mpv_pipe_handle_ != INVALID_HANDLE_VALUE && mpv_pipe_handle_ != nullptr) {
    CloseHandle(mpv_pipe_handle_);
    mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
  }

  mpv_pid_ = 0;
  mpv_hwnd_ = nullptr;
  mpv_window_attached_ = false;
  mpv_window_visible_ = false;
  mpv_width_ = 0;
  mpv_height_ = 0;
  mpv_pipe_name_.clear();
  mpv_ipc_read_buffer_.clear();
  mpv_frame_decoded_ = false;
  mpv_process_launch_ms_ = 0.0;
  mpv_window_discovered_ms_ = -1.0;
  mpv_window_discovery_call_ms_ = -1.0;
  mpv_window_attach_ms_ = -1.0;
  mpv_window_attachment_call_ms_ = -1.0;
  mpv_desktop_target_lookup_ms_ = -1.0;
  mpv_visible_request_ms_ = -1.0;
  mpv_visible_confirmed_ms_ = -1.0;
  mpv_ipc_connect_ms_ = -1.0;
  mpv_output_configured_ms_ = -1.0;
  mpv_frame_ready_ms_ = -1.0;
  mpv_dwm_flush_ms_ = -1.0;

  // Do NOT call SystemParametersInfoW(SPI_SETDESKWALLPAPER, 0, nullptr, ...) here.
  // Modern Windows 11 shell (Windows.UI.Xaml.dll) throws E_INVALIDARG (0x80070057)
  // causing Explorer.EXE to crash when passed a nullptr wallpaper path.
  return true;
}

bool LiveWallpaperPlugin::Impl::AttachToDesktop() {
  if (!window_ || !IsWindow(window_)) {
    return false;
  }

  HWND insert_after = nullptr;
  bool raised_desktop = false;
  bool use_layered_window = false;
  HWND desktop_target = FindDesktopWallpaperTarget(
      &insert_after, &raised_desktop, &use_layered_window);
  if (!desktop_target || !IsWindow(desktop_target)) {
    return false;
  }

  RECT rect{};
  if (!GetClientRect(desktop_target, &rect)) {
    return false;
  }
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) {
    return false;
  }

  if (raised_desktop) {
    SetWindowLongPtrW(window_, GWL_STYLE, WS_CHILD);
  } else {
    LONG_PTR style = GetWindowLongPtrW(window_, GWL_STYLE);
    style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
               WS_MAXIMIZEBOX | WS_SYSMENU);
    style |= WS_CHILD;
    SetWindowLongPtrW(window_, GWL_STYLE, style);
  }

  LONG_PTR extended_style = GetWindowLongPtrW(window_, GWL_EXSTYLE);
  extended_style &= ~WS_EX_APPWINDOW;
  extended_style |= WS_EX_TOOLWINDOW;
  if (use_layered_window) {
    extended_style |= WS_EX_LAYERED;
  }
  SetWindowLongPtrW(window_, GWL_EXSTYLE, extended_style);
  if (use_layered_window &&
      !SetLayeredWindowAttributes(window_, 0, 255, LWA_ALPHA)) {
    return false;
  }

  SetLastError(ERROR_SUCCESS);
  SetParent(window_, desktop_target);
  if (GetParent(window_) != desktop_target) {
    return false;
  }

  const UINT flags =
      SWP_SHOWWINDOW | (raised_desktop ? SWP_NOACTIVATE : 0) |
      (insert_after ? 0 : SWP_NOZORDER);
  if (!SetWindowPos(window_, insert_after, 0, 0, width, height, flags)) {
    return false;
  }

  if (root_window_ && root_window_ != window_) {
    ShowWindow(root_window_, SW_HIDE);
  }
  return true;
}

bool LiveWallpaperPlugin::Impl::IsFullscreenForegroundWindow() const {
  HWND foreground = GetForegroundWindow();
  if (!foreground || !IsWindow(foreground) || !IsWindowVisible(foreground) || IsIconic(foreground)) {
    return false;
  }

  // Exclude WallSync's own application window
  if (root_window_ && (foreground == root_window_ || GetAncestor(foreground, GA_ROOT) == root_window_)) {
    return false;
  }

  // Exclude MPV live wallpaper window itself
  if (mpv_hwnd_ && (foreground == mpv_hwnd_ || GetAncestor(foreground, GA_ROOT) == mpv_hwnd_)) {
    return false;
  }

  // Exclude Windows desktop and shell components
  HWND root_fg = GetAncestor(foreground, GA_ROOT);
  if (!root_fg) root_fg = foreground;

  wchar_t root_class[64]{};
  if (GetClassNameW(root_fg, root_class, 64) > 0) {
    if (wcscmp(root_class, L"Progman") == 0 ||
        wcscmp(root_class, L"WorkerW") == 0 ||
        wcscmp(root_class, L"Shell_TrayWnd") == 0 ||
        wcscmp(root_class, L"Shell_SecondaryTrayWnd") == 0 ||
        wcscmp(root_class, L"Windows.UI.Core.CoreWindow") == 0 ||
        wcscmp(root_class, L"XamlExplorerHostIslandWindow") == 0 ||
        wcscmp(root_class, L"Shell_InputSwitchTopLevel") == 0 ||
        wcscmp(root_class, L"TopLevelWindowForOverflowXamlIsland") == 0) {
      return false;
    }
  }

  wchar_t fg_class[64]{};
  if (GetClassNameW(foreground, fg_class, 64) > 0) {
    if (wcscmp(fg_class, L"Progman") == 0 ||
        wcscmp(fg_class, L"WorkerW") == 0 ||
        wcscmp(fg_class, L"SHELLDLL_DefView") == 0 ||
        wcscmp(fg_class, L"SysListView32") == 0 ||
        wcscmp(fg_class, L"Shell_TrayWnd") == 0 ||
        wcscmp(fg_class, L"Shell_SecondaryTrayWnd") == 0 ||
        wcscmp(fg_class, L"Windows.UI.Core.CoreWindow") == 0 ||
        wcscmp(fg_class, L"XamlExplorerHostIslandWindow") == 0) {
      return false;
    }
  }

  // Check if foreground or root_fg is an owned popup/tool/menu window. If its owner is maximized,
  // the user is interacting with a child popup of the maximized app.
  HWND owner = GetWindow(root_fg, GW_OWNER);
  if (!owner) owner = GetWindow(foreground, GW_OWNER);
  if (owner && IsWindow(owner) && IsWindowVisible(owner) && !IsIconic(owner)) {
    if (IsZoomed(owner)) {
      return true;
    }
  }

  // Ignore transient tooltip or menu windows from flipping policy
  if (wcscmp(fg_class, L"tooltips_class32") == 0 ||
      wcscmp(fg_class, L"#32768") == 0 ||
      wcscmp(root_class, L"tooltips_class32") == 0 ||
      wcscmp(root_class, L"#32768") == 0) {
    if (owner && IsWindow(owner) && IsZoomed(owner)) {
      return true;
    }
    return false;
  }

  // 1. Direct Maximized check: If the foreground window is maximized, it completely covers the work area
  if (IsZoomed(root_fg) || IsZoomed(foreground)) {
    return true;
  }

  // 2. Fullscreen or work area coverage check via monitor coordinates
  RECT window_rect{};
  if (!GetWindowRect(root_fg, &window_rect)) {
    if (!GetWindowRect(foreground, &window_rect)) {
      return false;
    }
  }

  HMONITOR monitor = MonitorFromWindow(root_fg, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfoW(monitor, &monitor_info)) {
    return false;
  }

  const RECT& mon = monitor_info.rcMonitor;
  const RECT& work = monitor_info.rcWork;

  // Tolerant bounds check (handles DWM drop shadows, invisible resizing borders, and DPI rounding)
  constexpr int kTolerance = 12;

  // Check if covering full physical monitor (games, video player fullscreen, F11 browser)
  const bool covers_monitor =
      (window_rect.left <= mon.left + kTolerance &&
       window_rect.top <= mon.top + kTolerance &&
       window_rect.right >= mon.right - kTolerance &&
       window_rect.bottom >= mon.bottom - kTolerance);

  if (covers_monitor) {
    return true;
  }

  // Check if covering monitor work area (e.g. apps maximized without WS_MAXIMIZE, or custom borderless layouts)
  const bool covers_work_area =
      (window_rect.left <= work.left + kTolerance &&
       window_rect.top <= work.top + kTolerance &&
       window_rect.right >= work.right - kTolerance &&
       window_rect.bottom >= work.bottom - kTolerance);

  return covers_work_area;
}

void LiveWallpaperPlugin::Impl::RefreshBatterySaverStatus() {
  SYSTEM_POWER_STATUS status{};
  if (GetSystemPowerStatus(&status) && status.SystemStatusFlag == 1) {
    battery_saver_enabled_ = true;
  } else {
    battery_saver_enabled_ = false;
  }
}

std::optional<LRESULT> LiveWallpaperPlugin::Impl::HandleWindowMessage(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) {
  if (message == WM_POWERBROADCAST && wparam == PBT_POWERSETTINGCHANGE &&
      lparam != 0) {
    const auto* setting =
        reinterpret_cast<const POWERBROADCAST_SETTING*>(lparam);
    if (IsEqualGUID(setting->PowerSetting, kPowerSavingStatus) &&
        setting->DataLength >= sizeof(DWORD)) {
      DWORD enabled = 0;
      memcpy(&enabled, setting->Data, sizeof(enabled));
      battery_saver_enabled_ = enabled != 0;
    }
  } else if (message == WM_POWERBROADCAST &&
             wparam == PBT_APMPOWERSTATUSCHANGE) {
    RefreshBatterySaverStatus();
  }
  return std::nullopt;
}

LiveWallpaperPlugin::LiveWallpaperPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : impl_(std::make_unique<Impl>(registrar)) {}

LiveWallpaperPlugin::~LiveWallpaperPlugin() = default;
