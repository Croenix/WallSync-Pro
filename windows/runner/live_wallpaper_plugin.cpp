#define _CRT_SECURE_NO_WARNINGS
// Desktop window discovery and raised-desktop behavior adapted from Lively
// Wallpaper's WinDesktopCore.cs and DesktopUtil.cs (GPL-3.0).

#include "live_wallpaper_plugin.h"
#include "process_diagnostics.h"
#include "taskbar_appbar.h"

#include <windows.h>
#include <dwmapi.h>
#include <powrprof.h>
#include <psapi.h>
#include <processthreadsapi.h>
#include <shellapi.h>
#include <dxgi.h>
#include <shobjidl_core.h>
#include <shobjidl.h>
#include <tlhelp32.h>
#include <wincodec.h>
#include <atomic>
#include <winrt/base.h>
#include <wrl/client.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Control.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <endpointvolume.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

constexpr char kChannelName[] = "wallsync/live_wallpaper";
constexpr UINT kWorkerWMessage = 0x052C;
constexpr GUID kPowerSavingStatus = {
    0xE00958C0, 0xC213, 0x4ACE, {0xAC, 0x77, 0xFE, 0xCC, 0xED, 0x2E, 0xEE, 0xA5}};

struct ApartmentScope {
  explicit ApartmentScope(winrt::apartment_type type = winrt::apartment_type::multi_threaded) {
    try {
      winrt::init_apartment(type);
      initialized_ = true;
    } catch (...) {
      initialized_ = false;
    }
  }
  ~ApartmentScope() {
    if (initialized_) {
      try {
        winrt::uninit_apartment();
      } catch (...) {}
    }
  }
  bool initialized_ = false;
};

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

  // Search through WorkerW windows in Z-order after window to locate the
  // full desktop background host, skipping 0x0 virtual desktop transition windows.
  HWND current_worker = window;
  while ((current_worker = FindWindowExW(nullptr, current_worker, L"WorkerW", nullptr)) != nullptr) {
    RECT rect{};
    if (GetClientRect(current_worker, &rect) &&
        (rect.right - rect.left > 100) && (rect.bottom - rect.top > 100)) {
      desktop_windows->worker = current_worker;
      break;
    }
  }
  return FALSE;
}

HWND FindDesktopWallpaperTarget(HWND* insert_after, bool* raised_desktop,
                                bool* use_layered_window) {
  static HWND s_cached_target = nullptr;
  static HWND s_cached_insert_after = nullptr;
  static bool s_cached_raised = false;
  static bool s_cached_layered = false;

  // Ensure target is valid, visible, and insert_after is intact (handles virtual desktop changes)
  if (s_cached_target && IsWindow(s_cached_target) && IsWindowVisible(s_cached_target) &&
      (!s_cached_insert_after || IsWindow(s_cached_insert_after))) {
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
  // Send 0x052C to Progman to request creation of the WorkerW desktop background.
  // We send both standard 0x052C (0,0) and Windows 11 legacy (0xD, 0x1) to cover all OS versions.
  SendMessageTimeoutW(progman, kWorkerWMessage, 0, 0,
                      SMTO_ABORTIFHUNG | SMTO_NORMAL, 500, &result);
  SendMessageTimeoutW(progman, kWorkerWMessage, 0xD, 0x1,
                      SMTO_ABORTIFHUNG | SMTO_NORMAL, 500, &result);

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
    return progman;
  }

  if (windows.worker) {
    s_cached_target = windows.worker;
    s_cached_insert_after = nullptr;
    s_cached_raised = false;
    s_cached_layered = false;
    return windows.worker;
  }

  *insert_after = windows.shell_view;
  return windows.shell_owner;
}

HWND FindDesktopDefView() {
  HWND progman = FindWindowW(L"Progman", nullptr);
  HWND def_view = FindWindowExW(progman, nullptr, L"SHELLDLL_DefView", nullptr);
  if (!def_view) {
    HWND worker = nullptr;
    do {
      worker = FindWindowExW(nullptr, worker, L"WorkerW", nullptr);
      if (worker) {
        def_view = FindWindowExW(worker, nullptr, L"SHELLDLL_DefView", nullptr);
        if (def_view) break;
      }
    } while (worker);
  }
  return def_view;
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

std::string WideToUtf8(const std::wstring& wide_str) {
  if (wide_str.empty()) return std::string();
  int size_needed = WideCharToMultiByte(CP_UTF8, 0, wide_str.data(),
                                        static_cast<int>(wide_str.size()),
                                        nullptr, 0, nullptr, nullptr);
  if (size_needed <= 0) return std::string();
  std::string result(size_needed, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide_str.data(),
                      static_cast<int>(wide_str.size()),
                      &result[0], size_needed, nullptr, nullptr);
  return result;
}

std::vector<uint8_t> GetExecutableIconPng(const std::wstring& executable) {
  if (executable.empty()) return {};

  static std::mutex cache_mutex;
  static std::unordered_map<std::wstring, std::vector<uint8_t>> icon_cache;
  {
    std::lock_guard<std::mutex> lock(cache_mutex);
    const auto cached = icon_cache.find(executable);
    if (cached != icon_cache.end()) return cached->second;
  }

  SHFILEINFOW file_info{};
  if (SHGetFileInfoW(executable.c_str(), 0, &file_info, sizeof(file_info),
                     SHGFI_ICON | SHGFI_SMALLICON) == 0 ||
      file_info.hIcon == nullptr) {
    return {};
  }

  constexpr int kIconSize = 32;
  BITMAPINFO bitmap_info{};
  bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap_info.bmiHeader.biWidth = kIconSize;
  bitmap_info.bmiHeader.biHeight = -kIconSize;
  bitmap_info.bmiHeader.biPlanes = 1;
  bitmap_info.bmiHeader.biBitCount = 32;
  bitmap_info.bmiHeader.biCompression = BI_RGB;

  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(nullptr, &bitmap_info, DIB_RGB_COLORS,
                                    &pixels, nullptr, 0);
  std::vector<uint8_t> png;
  if (bitmap != nullptr && pixels != nullptr) {
    std::memset(pixels, 0, kIconSize * kIconSize * 4);
    HDC device_context = CreateCompatibleDC(nullptr);
    if (device_context != nullptr) {
      HGDIOBJ previous_bitmap = SelectObject(device_context, bitmap);
      if (previous_bitmap != nullptr && previous_bitmap != HGDI_ERROR &&
          DrawIconEx(device_context, 0, 0, file_info.hIcon, kIconSize,
                     kIconSize, 0, nullptr, DI_NORMAL)) {
        ApartmentScope apartment;
        using Microsoft::WRL::ComPtr;
        ComPtr<IWICImagingFactory> factory;
        ComPtr<IWICBitmap> source;
        ComPtr<IWICFormatConverter> converter;
        ComPtr<IWICStream> wic_stream;
        ComPtr<IWICBitmapEncoder> encoder;
        ComPtr<IWICBitmapFrameEncode> frame;
        ComPtr<IPropertyBag2> properties;
        ComPtr<IStream> memory_stream;
        if (SUCCEEDED(CoCreateInstance(
                CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                IID_PPV_ARGS(factory.GetAddressOf()))) &&
            SUCCEEDED(factory->CreateBitmapFromHBITMAP(
                bitmap, nullptr, WICBitmapUseAlpha, source.GetAddressOf())) &&
            SUCCEEDED(factory->CreateFormatConverter(
                converter.GetAddressOf())) &&
            SUCCEEDED(converter->Initialize(
                source.Get(), GUID_WICPixelFormat32bppBGRA,
                WICBitmapDitherTypeNone, nullptr, 0.0,
                WICBitmapPaletteTypeCustom)) &&
            SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE,
                                            memory_stream.GetAddressOf())) &&
            SUCCEEDED(factory->CreateStream(wic_stream.GetAddressOf())) &&
            SUCCEEDED(wic_stream->InitializeFromIStream(memory_stream.Get())) &&
            SUCCEEDED(factory->CreateEncoder(
                GUID_ContainerFormatPng, nullptr, encoder.GetAddressOf())) &&
            SUCCEEDED(encoder->Initialize(wic_stream.Get(),
                                          WICBitmapEncoderNoCache)) &&
            SUCCEEDED(encoder->CreateNewFrame(
                frame.GetAddressOf(), properties.GetAddressOf())) &&
            SUCCEEDED(frame->Initialize(properties.Get())) &&
            SUCCEEDED(frame->SetSize(kIconSize, kIconSize))) {
          WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
          if (SUCCEEDED(frame->SetPixelFormat(&pixel_format)) &&
              pixel_format == GUID_WICPixelFormat32bppBGRA &&
              SUCCEEDED(frame->WriteSource(converter.Get(), nullptr)) &&
              SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit())) {
            HGLOBAL encoded_png = nullptr;
            if (SUCCEEDED(GetHGlobalFromStream(memory_stream.Get(),
                                               &encoded_png)) &&
                encoded_png != nullptr) {
              const SIZE_T png_size = GlobalSize(encoded_png);
              const auto* png_data =
                  static_cast<const uint8_t*>(GlobalLock(encoded_png));
              if (png_data != nullptr && png_size > 0) {
                png.assign(png_data, png_data + png_size);
                GlobalUnlock(encoded_png);
              }
            }
          }
        }
      }
      if (previous_bitmap != nullptr && previous_bitmap != HGDI_ERROR) {
        SelectObject(device_context, previous_bitmap);
      }
      DeleteDC(device_context);
    }
    DeleteObject(bitmap);
  }
  DestroyIcon(file_info.hIcon);

  if (!png.empty()) {
    std::lock_guard<std::mutex> lock(cache_mutex);
    if (icon_cache.size() >= 256) icon_cache.clear();
    icon_cache.emplace(executable, png);
  }
  return png;
}

}  // namespace

class LiveWallpaperPlugin::Impl {
 public:
  Impl(flutter::PluginRegistrarWindows* registrar,
       std::function<void()> force_redraw);
  ~Impl();

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool AttachToDesktop();
  bool SetWidgetDesktopSurface(bool attach_to_desktop);
  bool ShowWidgetWindow();
  flutter::EncodableMap VerifyWidgetPresentation(bool expected_topmost);
  bool IsFullscreenForegroundWindow() const;
  bool IsFullscreenForegroundWindowOnMonitor(
      const std::string& monitor_id) const;
  void RefreshBatterySaverStatus();
  std::optional<LRESULT> HandleWindowMessage(HWND hwnd,
                                             UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam);

  flutter::EncodableMap StartMpv(const flutter::EncodableMap* args);
  flutter::EncodableMap PollMpvStart();
  bool SetMpvSettings(const flutter::EncodableMap* args);
  bool StopMpv();

  void OptimizeMemory();
  void SetLowPowerMode(bool enable);
  flutter::EncodableMap GetPerformanceMetrics();
  bool SetStaticWallpaper(const std::wstring& path, const std::string& style);
  flutter::EncodableMap GetGpuAndDisplayInfo();
  flutter::EncodableMap GetMediaSessionInfo();
  bool ControlMediaSession(const std::string& action);
  bool SetWindowClickThrough(bool enable);
  bool PinWindowToBottom();
  bool SetDesktopIconsVisible(bool visible);
  bool GetDesktopIconsVisible();
  bool SetTaskbarBlur(int mode);
  flutter::EncodableMap ConfigureTaskbarAppBar(
      const flutter::EncodableMap* args);
  flutter::EncodableMap SetTaskbarAppBarVisible(bool visible);
  flutter::EncodableMap GetWindowsTaskbarInfo();
  bool SetWindowsTaskbarVisibility(bool visible);
  bool RestoreWindowsTaskbar();
  flutter::EncodableMap PositionDockForReplacement(DWORD pid,
                                                   int64_t expected_hwnd);
  bool RunTaskbarCommand(const std::string& command);
  int64_t GetNativeWindowHandle();
  flutter::EncodableMap GetNativeWindowInfo();
  flutter::EncodableMap VerifyDockWindow(DWORD pid,
                                         const std::string& instance_id,
                                         int64_t operation_id = -1);
  bool ActivateDockWindow(DWORD pid, const std::string& instance_id);
  flutter::EncodableList GetDesktopWindows();
  bool ActivateDesktopWindow(int64_t hwnd);
  bool LaunchDockItem(const std::string& target);
  flutter::EncodableMap FindWindowByTitleOrPid(const std::string& title_query, DWORD pid_query);
  bool IsOtherAudioPlaying();
  flutter::EncodableMap GetWindowsAccentColor();
  bool IsProcessRunning(const std::string& process_name);
  std::string PickImageFile(const std::string& title);
  bool BoostProcessPriority(bool boost);
  bool SetWindowCloaked(bool cloak);
  bool CreateFileHardLink(const std::wstring& target_path, const std::wstring& existing_path);
  flutter::EncodableMap GetWindowsVersionInfo();
  flutter::EncodableList GetProcessList();
  bool SetProcessPriority(DWORD pid, int priority_level);
  bool TrimProcessMemory(DWORD pid);
  void StartLowMemoryMonitor();
  void StopLowMemoryMonitor();

  std::wstring FindMpvExecutable();
  bool SendMpvCommand(const std::string& json_cmd);
  HWND FindMpvWindow(DWORD pid, int timeout_ms);
  bool ReparentMpvWindow(HWND mpv_hwnd, int* out_width, int* out_height,
                         std::string* failure_reason,
                         double* out_desktop_target_lookup_ms);
  void DrainMpvStderr();

 private:
  flutter::PluginRegistrarWindows* registrar_;
  std::function<void()> force_redraw_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  HWND root_window_;
  HPOWERNOTIFY power_notification_ = nullptr;
  int window_proc_delegate_id_ = 0;
  bool battery_saver_enabled_ = false;
  bool widget_desktop_attached_ = false;
  HWND widget_desktop_parent_ = nullptr;

  HANDLE mpv_process_handle_ = nullptr;
  DWORD mpv_pid_ = 0;
  HWND mpv_hwnd_ = nullptr;
  bool mpv_window_attached_ = false;
  bool mpv_window_visible_ = false;
  int mpv_width_ = 0;
  int mpv_height_ = 0;
  std::string mpv_pipe_name_;
  std::string mpv_ipc_read_buffer_;
  std::string mpv_stderr_buffer_;
  HANDLE mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
  bool mpv_frame_decoded_ = false;
  bool mpv_is_reuse_ = false;
  std::chrono::steady_clock::time_point mpv_launch_started_{};
  double mpv_previous_cleanup_ms_ = -1.0;
  double mpv_executable_lookup_ms_ = -1.0;
  double mpv_process_launch_ms_ = -1.0;
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
  HANDLE mpv_stderr_read_ = nullptr;
  std::string mpv_launch_cmd_line_;
  std::string mpv_working_dir_;

  HANDLE low_mem_event_ = nullptr;
  HANDLE low_mem_stop_event_ = nullptr;
  std::atomic<bool> low_mem_running_{false};
  std::thread low_mem_thread_;
  UINT taskbar_created_msg_ = 0;
  std::unique_ptr<TaskbarAppBar> taskbar_appbar_;
};

LiveWallpaperPlugin::Impl::Impl(
    flutter::PluginRegistrarWindows* registrar,
    std::function<void()> force_redraw)
    : registrar_(registrar),
      force_redraw_(std::move(force_redraw)),
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
  HWND target_for_power = root_window_ ? root_window_ : window_;
  if (target_for_power) {
    power_notification_ =
        RegisterPowerSettingNotification(target_for_power, &kPowerSavingStatus,
                                         DEVICE_NOTIFY_WINDOW_HANDLE);
    RefreshBatterySaverStatus();
  }
  StartLowMemoryMonitor();
  taskbar_created_msg_ = RegisterWindowMessageW(L"TaskbarCreated");
}

LiveWallpaperPlugin::Impl::~Impl() {
  channel_->SetMethodCallHandler(nullptr);
  taskbar_appbar_.reset();
  if (window_proc_delegate_id_ != 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
  }
  if (power_notification_) {
    UnregisterPowerSettingNotification(power_notification_);
  }
  StopLowMemoryMonitor();
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
  if (call.method_name() == "setWidgetDesktopSurface") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    bool attach_to_desktop = false;
    if (args != nullptr) {
      const auto attach_entry =
          args->find(flutter::EncodableValue("attachToDesktop"));
      if (attach_entry != args->end()) {
        attach_to_desktop =
            GetBoolFromEncodable(attach_entry->second, false);
      }
    }
    result->Success(
        flutter::EncodableValue(SetWidgetDesktopSurface(attach_to_desktop)));
    return;
  }
  if (call.method_name() == "showWidgetWindow") {
    result->Success(flutter::EncodableValue(ShowWidgetWindow()));
    return;
  }
  if (call.method_name() == "verifyWidgetPresentation") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    bool expected_topmost = false;
    if (args != nullptr) {
      const auto topmost_entry =
          args->find(flutter::EncodableValue("alwaysOnTop"));
      if (topmost_entry != args->end()) {
        expected_topmost = GetBoolFromEncodable(topmost_entry->second, false);
      }
    }
    result->Success(
        flutter::EncodableValue(
            VerifyWidgetPresentation(expected_topmost)));
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
  if (call.method_name() == "optimizeMemory") {
    OptimizeMemory();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (call.method_name() == "setLowPowerMode") {
    bool enable = true;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("enable"));
      if (it != args->end()) {
        enable = GetBoolFromEncodable(it->second, true);
      }
    }
    SetLowPowerMode(enable);
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (call.method_name() == "getPerformanceMetrics") {
    result->Success(flutter::EncodableValue(GetPerformanceMetrics()));
    return;
  }
  if (call.method_name() == "setStaticWallpaper") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) {
      result->Error("INVALID_ARGS", "Expected argument map with path and style.");
      return;
    }
    std::string path_str = "";
    auto it_path = args->find(flutter::EncodableValue("path"));
    if (it_path != args->end()) {
      path_str = GetStringFromEncodable(it_path->second, "");
    }
    std::string style_str = "fill";
    auto it_style = args->find(flutter::EncodableValue("style"));
    if (it_style != args->end()) {
      style_str = GetStringFromEncodable(it_style->second, "fill");
    }
    std::wstring wide_path = Utf8ToWide(path_str);
    result->Success(flutter::EncodableValue(SetStaticWallpaper(wide_path, style_str)));
    return;
  }
  if (call.method_name() == "getGpuAndDisplayInfo") {
    result->Success(flutter::EncodableValue(GetGpuAndDisplayInfo()));
    return;
  }
  if (call.method_name() == "getMediaSessionInfo") {
    result->Success(flutter::EncodableValue(GetMediaSessionInfo()));
    return;
  }
  if (call.method_name() == "controlMediaSession") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    std::string action = "toggle";
    if (args) {
      auto it = args->find(flutter::EncodableValue("action"));
      if (it != args->end()) {
        action = GetStringFromEncodable(it->second, "toggle");
      }
    }
    result->Success(flutter::EncodableValue(ControlMediaSession(action)));
    return;
  }
  if (call.method_name() == "setWindowClickThrough") {
    bool enable = true;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("enable"));
      if (it != args->end()) {
        enable = GetBoolFromEncodable(it->second, true);
      }
    }
    result->Success(flutter::EncodableValue(SetWindowClickThrough(enable)));
    return;
  }
  if (call.method_name() == "pinWindowToBottom") {
    result->Success(flutter::EncodableValue(PinWindowToBottom()));
    return;
  }
  if (call.method_name() == "setDesktopIconsVisible") {
    bool visible = true;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("visible"));
      if (it != args->end()) {
        visible = GetBoolFromEncodable(it->second, true);
      }
    }
    result->Success(flutter::EncodableValue(SetDesktopIconsVisible(visible)));
    return;
  }
  if (call.method_name() == "getDesktopIconsVisible") {
    result->Success(flutter::EncodableValue(GetDesktopIconsVisible()));
    return;
  }
  if (call.method_name() == "setTaskbarBlur") {
    int mode = 0;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("mode"));
      if (it != args->end()) {
        mode = GetIntFromEncodable(it->second, 0);
      }
    }
    result->Success(flutter::EncodableValue(SetTaskbarBlur(mode)));
    return;
  }
  if (call.method_name() == "getWindowsTaskbarInfo") {
    result->Success(flutter::EncodableValue(GetWindowsTaskbarInfo()));
    return;
  }
  if (call.method_name() == "configureTaskbarAppBar") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (GetProcessModeName() != "taskbar_dock") {
      result->Error("TASKBAR_MODE_REQUIRED",
                    "AppBar configuration is only available to taskbar_dock.");
      return;
    }
    if (args == nullptr) {
      result->Error("INVALID_ARGUMENT",
                    "Expected a taskbar AppBar configuration map.");
      return;
    }
    result->Success(flutter::EncodableValue(ConfigureTaskbarAppBar(args)));
    return;
  }
  if (call.method_name() == "setTaskbarAppBarVisible") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (GetProcessModeName() != "taskbar_dock") {
      result->Error("TASKBAR_MODE_REQUIRED",
                    "AppBar visibility is only available to taskbar_dock.");
      return;
    }
    if (args == nullptr) {
      result->Error("INVALID_ARGUMENT",
                    "Expected a taskbar AppBar visibility map.");
      return;
    }
    const auto visible_entry = args->find(flutter::EncodableValue("visible"));
    if (visible_entry == args->end() ||
        !std::holds_alternative<bool>(visible_entry->second)) {
      result->Error("INVALID_ARGUMENT",
                    "Taskbar AppBar visibility must be a boolean.");
      return;
    }
    result->Success(flutter::EncodableValue(
        SetTaskbarAppBarVisible(std::get<bool>(visible_entry->second))));
    return;
  }
  if (call.method_name() == "isFullscreenForegroundWindowOnMonitor") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (GetProcessModeName() != "taskbar_dock" || args == nullptr) {
      result->Error("INVALID_ARGUMENT",
                    "A taskbar monitor identity is required.");
      return;
    }
    const auto monitor_entry =
        args->find(flutter::EncodableValue("monitorId"));
    if (monitor_entry == args->end() ||
        !std::holds_alternative<std::string>(monitor_entry->second)) {
      result->Error("INVALID_ARGUMENT", "Monitor identity must be a string.");
      return;
    }
    result->Success(flutter::EncodableValue(
        IsFullscreenForegroundWindowOnMonitor(
            std::get<std::string>(monitor_entry->second))));
    return;
  }
  if (call.method_name() == "setWindowsTaskbarVisibility") {
    bool visible = true;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("visible"));
      if (it != args->end()) {
        visible = GetBoolFromEncodable(it->second, true);
      }
    }
    result->Success(flutter::EncodableValue(SetWindowsTaskbarVisibility(visible)));
    return;
  }
  if (call.method_name() == "restoreWindowsTaskbar") {
    result->Success(flutter::EncodableValue(RestoreWindowsTaskbar()));
    return;
  }
  if (call.method_name() == "positionDockForReplacement") {
    DWORD pid = 0;
    int64_t expected_hwnd = 0;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it_pid = args->find(flutter::EncodableValue("pid"));
      if (it_pid != args->end()) pid = GetIntFromEncodable(it_pid->second, 0);
      auto it_hwnd = args->find(flutter::EncodableValue("hwnd"));
      if (it_hwnd != args->end()) {
        expected_hwnd = GetIntFromEncodable(it_hwnd->second, 0);
      }
    }
    result->Success(flutter::EncodableValue(
        PositionDockForReplacement(pid, expected_hwnd)));
    return;
  }
  if (call.method_name() == "runTaskbarCommand") {
    std::string command;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it_command = args->find(flutter::EncodableValue("command"));
      if (it_command != args->end()) {
        command = GetStringFromEncodable(it_command->second, "");
      }
    }
    result->Success(flutter::EncodableValue(RunTaskbarCommand(command)));
    return;
  }
  if (call.method_name() == "getNativeWindowHandle") {
    result->Success(flutter::EncodableValue(GetNativeWindowHandle()));
    return;
  }
  if (call.method_name() == "getNativeWindowInfo") {
    result->Success(flutter::EncodableValue(GetNativeWindowInfo()));
    return;
  }
  if (call.method_name() == "acknowledgeDockReadiness") {
    const bool acknowledged = SignalProcessReadinessEvent();
    result->Success(flutter::EncodableValue(acknowledged));
    return;
  }
  if (call.method_name() == "verifyDockWindow") {
    int pid_query = 0;
    int64_t operation_id = -1;
    std::string instance_id = "";
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it_pid = args->find(flutter::EncodableValue("pid"));
      if (it_pid != args->end()) pid_query = GetIntFromEncodable(it_pid->second, 0);
      auto it_inst = args->find(flutter::EncodableValue("instanceId"));
      if (it_inst != args->end()) instance_id = GetStringFromEncodable(it_inst->second, "");
      auto it_operation = args->find(flutter::EncodableValue("operationId"));
      if (it_operation != args->end()) {
        operation_id = GetIntFromEncodable(it_operation->second, -1);
      }
    }
    result->Success(flutter::EncodableValue(VerifyDockWindow(
        static_cast<DWORD>(pid_query), instance_id, operation_id)));
    return;
  }
  if (call.method_name() == "activateDockWindow") {
    int pid_query = 0;
    std::string instance_id = "";
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it_pid = args->find(flutter::EncodableValue("pid"));
      if (it_pid != args->end()) pid_query = GetIntFromEncodable(it_pid->second, 0);
      auto it_inst = args->find(flutter::EncodableValue("instanceId"));
      if (it_inst != args->end()) instance_id = GetStringFromEncodable(it_inst->second, "");
    }
    result->Success(flutter::EncodableValue(ActivateDockWindow(static_cast<DWORD>(pid_query), instance_id)));
    return;
  }
  if (call.method_name() == "getDesktopWindows") {
    result->Success(flutter::EncodableValue(GetDesktopWindows()));
    return;
  }
  if (call.method_name() == "activateDesktopWindow") {
    int64_t hwnd = 0;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("hwnd"));
      if (it != args->end() && std::holds_alternative<int64_t>(it->second)) {
        hwnd = std::get<int64_t>(it->second);
      }
    }
    result->Success(flutter::EncodableValue(ActivateDesktopWindow(hwnd)));
    return;
  }
  if (call.method_name() == "launchDockItem") {
    std::string target;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("target"));
      if (it != args->end()) target = GetStringFromEncodable(it->second);
    }
    result->Success(flutter::EncodableValue(LaunchDockItem(target)));
    return;
  }
  if (call.method_name() == "findWindowByTitleOrPid") {
    std::string title_query = "";
    int pid_query = 0;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it_title = args->find(flutter::EncodableValue("title"));
      if (it_title != args->end()) title_query = GetStringFromEncodable(it_title->second);
      auto it_pid = args->find(flutter::EncodableValue("pid"));
      if (it_pid != args->end()) pid_query = GetIntFromEncodable(it_pid->second, 0);
    }
    result->Success(flutter::EncodableValue(FindWindowByTitleOrPid(title_query, static_cast<DWORD>(pid_query))));
    return;
  }
  if (call.method_name() == "isOtherAudioPlaying") {
    result->Success(flutter::EncodableValue(IsOtherAudioPlaying()));
    return;
  }
  if (call.method_name() == "getWindowsAccentColor") {
    result->Success(flutter::EncodableValue(GetWindowsAccentColor()));
    return;
  }
  if (call.method_name() == "isProcessRunning") {
    std::string name = "";
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("name"));
      if (it != args->end()) {
        name = GetStringFromEncodable(it->second, "");
      }
    }
    result->Success(flutter::EncodableValue(IsProcessRunning(name)));
    return;
  }
  if (call.method_name() == "pickImageFile") {
    std::string title = "";
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("title"));
      if (it != args->end()) {
        title = GetStringFromEncodable(it->second, "");
      }
    }
    result->Success(flutter::EncodableValue(PickImageFile(title)));
    return;
  }
  if (call.method_name() == "boostProcessPriority") {
    bool boost = true;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("boost"));
      if (it != args->end()) {
        boost = GetBoolFromEncodable(it->second, true);
      }
    }
    result->Success(flutter::EncodableValue(BoostProcessPriority(boost)));
    return;
  }
  if (call.method_name() == "setWindowCloaked") {
    bool cloak = true;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("cloak"));
      if (it != args->end()) {
        cloak = GetBoolFromEncodable(it->second, true);
      }
    }
    result->Success(flutter::EncodableValue(SetWindowCloaked(cloak)));
    return;
  }
  if (call.method_name() == "createHardLink") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    std::string target_str = "";
    auto it_target = args->find(flutter::EncodableValue("target"));
    if (it_target != args->end()) {
      target_str = GetStringFromEncodable(it_target->second, "");
    }
    std::string existing_str = "";
    auto it_existing = args->find(flutter::EncodableValue("existing"));
    if (it_existing != args->end()) {
      existing_str = GetStringFromEncodable(it_existing->second, "");
    }
    if (target_str.empty() || existing_str.empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    std::wstring wide_target = Utf8ToWide(target_str);
    std::wstring wide_existing = Utf8ToWide(existing_str);
    result->Success(flutter::EncodableValue(CreateFileHardLink(wide_target, wide_existing)));
    return;
  }
  if (call.method_name() == "getWindowsVersionInfo") {
    result->Success(flutter::EncodableValue(GetWindowsVersionInfo()));
    return;
  }
  if (call.method_name() == "getProcessList") {
    result->Success(flutter::EncodableValue(GetProcessList()));
    return;
  }
  if (call.method_name() == "setProcessPriority") {
    int pid = 0;
    int priority = 1;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it_pid = args->find(flutter::EncodableValue("pid"));
      if (it_pid != args->end()) {
        pid = GetIntFromEncodable(it_pid->second, 0);
      }
      auto it_pri = args->find(flutter::EncodableValue("priority"));
      if (it_pri != args->end()) {
        priority = GetIntFromEncodable(it_pri->second, 1);
      }
    }
    result->Success(flutter::EncodableValue(SetProcessPriority(static_cast<DWORD>(pid), priority)));
    return;
  }
  if (call.method_name() == "trimProcessMemory") {
    int pid = 0;
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args) {
      auto it_pid = args->find(flutter::EncodableValue("pid"));
      if (it_pid != args->end()) {
        pid = GetIntFromEncodable(it_pid->second, 0);
      }
    }
    result->Success(flutter::EncodableValue(TrimProcessMemory(static_cast<DWORD>(pid))));
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

bool LiveWallpaperPlugin::Impl::SendMpvCommand(const std::string& json_cmd) {
  if (mpv_pipe_name_.empty()) return false;
  std::wstring full_pipe = LR"(\\.\pipe\)" + Utf8ToWide(mpv_pipe_name_);

  if (mpv_pipe_handle_ == nullptr || mpv_pipe_handle_ == INVALID_HANDLE_VALUE) {
    // Open with GENERIC_READ | GENERIC_WRITE to allow bidirectional communication
    // and match PollMpvStart() permissions, preventing ERROR_ACCESS_DENIED in ReadFile.
    mpv_pipe_handle_ = CreateFileW(
        full_pipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
        OPEN_EXISTING, 0, nullptr);
  }

  if (mpv_pipe_handle_ != INVALID_HANDLE_VALUE && mpv_pipe_handle_ != nullptr) {
    std::string payload = json_cmd + "\n";
    DWORD written = 0;
    BOOL ok = WriteFile(mpv_pipe_handle_, payload.c_str(),
                        static_cast<DWORD>(payload.length()), &written, nullptr);
    if (ok) {
      return true;
    } else {
      CloseHandle(mpv_pipe_handle_);
      mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
      return false;
    }
  }
  return false;
}

void LiveWallpaperPlugin::Impl::DrainMpvStderr() {
  if (!mpv_stderr_read_ || mpv_stderr_read_ == INVALID_HANDLE_VALUE) return;
  DWORD bytes_avail = 0;
  while (PeekNamedPipe(mpv_stderr_read_, nullptr, 0, nullptr, &bytes_avail, nullptr) && bytes_avail > 0) {
    char buf[1024];
    DWORD to_read = (bytes_avail > sizeof(buf)) ? sizeof(buf) : bytes_avail;
    DWORD bytes_read = 0;
    if (ReadFile(mpv_stderr_read_, buf, to_read, &bytes_read, nullptr) && bytes_read > 0) {
      mpv_stderr_buffer_.append(buf, bytes_read);
      // Keep only latest 16KB of stderr to avoid unbounded memory growth
      if (mpv_stderr_buffer_.size() > 16384) {
        mpv_stderr_buffer_.erase(0, mpv_stderr_buffer_.size() - 8192);
      }
    } else {
      break;
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
        std::chrono::milliseconds(remaining < 10 ? remaining : 10));
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
    SetWindowLongPtrW(mpv_hwnd, GWL_STYLE, WS_CHILD | WS_CLIPSIBLINGS);
  } else {
    LONG_PTR style = GetWindowLongPtrW(mpv_hwnd, GWL_STYLE);
    style &= ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
               WS_MAXIMIZEBOX | WS_SYSMENU);
    style |= (WS_CHILD | WS_CLIPSIBLINGS);
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

  // Always use SWP_NOACTIVATE so live wallpaper never steals active keyboard or mouse focus
  const UINT flags = SWP_SHOWWINDOW | SWP_NOACTIVATE |
                     (insert_after ? 0 : SWP_NOZORDER);
  if (!SetWindowPos(mpv_hwnd, insert_after, 0, 0, width, height, flags)) {
    return fail("SetWindowPos failed with Win32 error " +
                std::to_string(GetLastError()));
  }
  return true;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::StartMpv(const flutter::EncodableMap* args) {
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

  // Fast path: if MPV is already running, healthy, and attached to the desktop,
  // reuse it seamlessly via IPC loadfile! This eliminates process recreation,
  // window reparenting, and polling delays (ready in ~10ms).
  if (mpv_process_handle_ && mpv_hwnd_ && IsWindow(mpv_hwnd_) && mpv_window_attached_) {
    DWORD exit_code = 0;
    if (GetExitCodeProcess(mpv_process_handle_, &exit_code) && exit_code == STILL_ACTIVE) {
      HWND parent = GetParent(mpv_hwnd_);
      const bool target_alive = parent && IsWindow(parent) && IsWindowVisible(parent);
      const bool window_visible = IsWindowVisible(mpv_hwnd_) != FALSE;
      if (target_alive && window_visible) {
        std::wstring wide_video = Utf8ToWide(video_path);
        std::replace(wide_video.begin(), wide_video.end(), L'\\', L'/');
        std::string safe_video = WideToUtf8(wide_video);
        std::string escaped;
        for (char c : safe_video) {
          if (c == '"') escaped += "\\\"";
          else if (c == '\\') escaped += "\\\\";
          else escaped += c;
        }
        std::string load_cmd = R"({"command":["loadfile",")" + escaped + R"("]})";
        if (SendMpvCommand(load_cmd)) {
          SetMpvSettings(args);
          mpv_is_reuse_ = true;
          mpv_frame_decoded_ = false;
          mpv_launch_started_ = std::chrono::steady_clock::now();
          mpv_output_configured_ms_ = -1.0;
          mpv_frame_ready_ms_ = -1.0;
          mpv_previous_cleanup_ms_ = -1.0;
          mpv_executable_lookup_ms_ = -1.0;
          mpv_process_launch_ms_ = -1.0;
          mpv_window_discovered_ms_ = -1.0;
          mpv_window_discovery_call_ms_ = -1.0;
          mpv_window_attach_ms_ = -1.0;
          mpv_window_attachment_call_ms_ = -1.0;
          mpv_desktop_target_lookup_ms_ = -1.0;
          mpv_visible_request_ms_ = -1.0;
          mpv_visible_confirmed_ms_ = -1.0;
          mpv_dwm_flush_ms_ = -1.0;
          mpv_ipc_read_buffer_.clear();

          flutter::EncodableMap pending;
          pending[flutter::EncodableValue("pending")] = flutter::EncodableValue(true);
          pending[flutter::EncodableValue("reused")] = flutter::EncodableValue(true);
          pending[flutter::EncodableValue("mediaSwitched")] = flutter::EncodableValue(true);
          pending[flutter::EncodableValue("coldLaunch")] = flutter::EncodableValue(false);
          pending[flutter::EncodableValue("pid")] = flutter::EncodableValue(static_cast<int>(mpv_pid_));
          pending[flutter::EncodableValue("windowAttached")] = flutter::EncodableValue(true);
          pending[flutter::EncodableValue("windowVisible")] = flutter::EncodableValue(true);
          pending[flutter::EncodableValue("frameDecoded")] = flutter::EncodableValue(false);
          return pending;
        }
      }
    }
  }

  mpv_is_reuse_ = false;

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

  auto now = std::chrono::steady_clock::now().time_since_epoch().count();
  mpv_pipe_name_ = "wallsync_mpv_ipc_" + std::to_string(now);
  mpv_ipc_read_buffer_.clear();
  mpv_stderr_buffer_.clear();

  std::wstring wide_pipe = LR"(\\.\pipe\)" + Utf8ToWide(mpv_pipe_name_);

  std::wstringstream cmd_stream;
  cmd_stream << L"\"" << mpv_path << L"\""
             << (is_muted || volume <= 0
                     ? L" --mute=yes --audio=no --ao=null"
                     : L" --mute=no --ao=wasapi --audio-client-name=\"WallSync Pro\" --aid=auto")
             << L" --volume=" << std::clamp(volume, 0, 100)
             << L" --volume-max=100"
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
             << L" --gpu-context=d3d11"
             << L" --d3d11-exclusive-fs=no"
             << L" --d3d11-flip=yes"
             << L" --hwdec=d3d11va,auto-safe"
             << L" --vd-lavc-dr=yes"
             << L" --vd-lavc-threads=0"
             << L" --scale=bilinear"
             << L" --cscale=bilinear"
             << L" --demuxer-max-bytes=8MiB"
             << L" --demuxer-max-back-bytes=1MiB"
             << L" --cache=no"
             << L" --cache-secs=1"
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

  const std::wstring mpv_directory =
      std::filesystem::path(mpv_path).parent_path().wstring();

  mpv_launch_cmd_line_ = WideToUtf8(cmd_line);
  mpv_working_dir_ = WideToUtf8(mpv_directory);

  if (mpv_stderr_read_ != nullptr && mpv_stderr_read_ != INVALID_HANDLE_VALUE) {
    CloseHandle(mpv_stderr_read_);
    mpv_stderr_read_ = nullptr;
  }

  HANDLE stderr_write = nullptr;
  SECURITY_ATTRIBUTES sa{};
  sa.nLength = sizeof(SECURITY_ATTRIBUTES);
  sa.bInheritHandle = TRUE;
  sa.lpSecurityDescriptor = nullptr;
  if (CreatePipe(&mpv_stderr_read_, &stderr_write, &sa, 0)) {
    SetHandleInformation(mpv_stderr_read_, HANDLE_FLAG_INHERIT, 0);
  }

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  if (stderr_write != nullptr) {
    si.dwFlags |= STARTF_USESTDHANDLES;
    si.hStdError = stderr_write;
    si.hStdOutput = nullptr;
    si.hStdInput = nullptr;
  }

  PROCESS_INFORMATION pi{};
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
      nullptr, cmd_line_writable.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | NORMAL_PRIORITY_CLASS, nullptr,
      mpv_directory.c_str(), &si, &pi);

  if (stderr_write != nullptr) {
    CloseHandle(stderr_write);
    stderr_write = nullptr;
  }

  if (!success) {
    if (mpv_stderr_read_ != nullptr && mpv_stderr_read_ != INVALID_HANDLE_VALUE) {
      CloseHandle(mpv_stderr_read_);
      mpv_stderr_read_ = nullptr;
    }
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
    failure[flutter::EncodableValue("cmdLine")] = flutter::EncodableValue(mpv_launch_cmd_line_);
    failure[flutter::EncodableValue("workingDir")] = flutter::EncodableValue(mpv_working_dir_);
    failure[flutter::EncodableValue("launchMs")] = flutter::EncodableValue(-1.0);
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

  // Continuously drain MPV stderr into memory to prevent child process buffer deadlock
  DrainMpvStderr();

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
    result[flutter::EncodableValue("reused")] = flutter::EncodableValue(mpv_is_reuse_);
    result[flutter::EncodableValue("mediaSwitched")] = flutter::EncodableValue(mpv_is_reuse_);
    result[flutter::EncodableValue("coldLaunch")] = flutter::EncodableValue(!mpv_is_reuse_);
  };

  DWORD exit_code = 0;
  if (!GetExitCodeProcess(mpv_process_handle_, &exit_code) || exit_code != STILL_ACTIVE) {
    DrainMpvStderr();
    std::string stderr_output = mpv_stderr_buffer_;
    flutter::EncodableMap fail_res;
    std::string fail_msg = "MPV process exited prematurely with exit code: " + std::to_string(exit_code);
    if (!stderr_output.empty()) {
      fail_msg += " | STDERR: " + stderr_output;
    }
    fail_res[flutter::EncodableValue("error")] = flutter::EncodableValue(fail_msg);
    fail_res[flutter::EncodableValue("stderr")] = flutter::EncodableValue(stderr_output);
    fail_res[flutter::EncodableValue("exitCode")] = flutter::EncodableValue(static_cast<int>(exit_code));
    fail_res[flutter::EncodableValue("cmdLine")] = flutter::EncodableValue(mpv_launch_cmd_line_);
    fail_res[flutter::EncodableValue("workingDir")] = flutter::EncodableValue(mpv_working_dir_);
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
          if (response.find("\"event\":\"playback-restart\"") != std::string::npos) {
            mpv_frame_decoded_ = true;
            mpv_frame_ready_ms_ = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - mpv_launch_started_).count();
          }
          const auto frame_info_data = response.find("\"data\":");
          if (response.find("\"request_id\":4") != std::string::npos &&
              response.find("\"error\":\"success\"") != std::string::npos &&
              frame_info_data != std::string::npos &&
              (response.find("\"picture-type\"", frame_info_data) != std::string::npos ||
               response.find("\"w\":", frame_info_data) != std::string::npos)) {
            mpv_frame_decoded_ = true;
            mpv_frame_ready_ms_ = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - mpv_launch_started_).count();
          }
        }
      }
    }

    // Safety fallback: once VO has been configured for 350ms, video frames are active
    if (!mpv_frame_decoded_ && mpv_output_configured_ms_ > 0.0) {
      const double elapsed_since_vo = std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - mpv_launch_started_).count() - mpv_output_configured_ms_;
      if (elapsed_since_vo >= 350.0) {
        mpv_frame_decoded_ = true;
        mpv_frame_ready_ms_ = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - mpv_launch_started_).count();
      }
    }

    if (!mpv_frame_decoded_) {
      const auto now = std::chrono::steady_clock::now();
      if (now - mpv_last_frame_query_ >= std::chrono::milliseconds(20)) {
        const std::string output_query =
            "{\"command\":[\"get_property\",\"vo-configured\"],\"request_id\":2}\n";
        DWORD written = 0;
        if (!WriteFile(mpv_pipe_handle_, output_query.c_str(),
                       static_cast<DWORD>(output_query.length()), &written, nullptr)) {
          CloseHandle(mpv_pipe_handle_);
          mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
        } else {
          const std::string frame_info_query =
              "{\"command\":[\"get_property\",\"video-frame-info\"],\"request_id\":4}\n";
          WriteFile(mpv_pipe_handle_, frame_info_query.c_str(),
                    static_cast<DWORD>(frame_info_query.length()), &written, nullptr);
        }
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
  result[flutter::EncodableValue("width")] = flutter::EncodableValue(mpv_width_ > 0 ? mpv_width_ : 1920);
  result[flutter::EncodableValue("height")] = flutter::EncodableValue(mpv_height_ > 0 ? mpv_height_ : 1080);
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
    if (paused && mpv_process_handle_) {
      EmptyWorkingSet(mpv_process_handle_);
    }
  }

  return true;
}

bool LiveWallpaperPlugin::Impl::StopMpv() {
  if (mpv_hwnd_ && IsWindow(mpv_hwnd_)) {
    ShowWindow(mpv_hwnd_, SW_HIDE);
    SetParent(mpv_hwnd_, nullptr);
  }

  if (mpv_process_handle_) {
    DWORD exit_code = 0;
    const BOOL got_code = GetExitCodeProcess(mpv_process_handle_, &exit_code);
    if (!got_code || exit_code == STILL_ACTIVE) {
      if (!mpv_pipe_name_.empty()) {
        SendMpvCommand(R"({"command":["quit"]})");
      }

      if (mpv_pipe_handle_ != INVALID_HANDLE_VALUE && mpv_pipe_handle_ != nullptr) {
        CloseHandle(mpv_pipe_handle_);
        mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
      }

      // Check briefly (up to 50ms) on the platform thread for fast shutdown;
      // if it takes longer, offload the wait & termination to a worker thread
      // so Flutter never stalls its event loop or frame rendering.
      DWORD wait_status = WaitForSingleObject(mpv_process_handle_, 50);
      if (wait_status == WAIT_TIMEOUT) {
        HANDLE proc_to_wait = mpv_process_handle_;
        mpv_process_handle_ = nullptr;
        std::thread([proc_to_wait]() {
          DWORD status = WaitForSingleObject(proc_to_wait, 1500);
          if (status == WAIT_TIMEOUT) {
            TerminateProcess(proc_to_wait, 0);
            WaitForSingleObject(proc_to_wait, 1000);
          }
          CloseHandle(proc_to_wait);
        }).detach();
      } else {
        CloseHandle(mpv_process_handle_);
        mpv_process_handle_ = nullptr;
      }
    } else {
      CloseHandle(mpv_process_handle_);
      mpv_process_handle_ = nullptr;
    }
  }

  if (mpv_pipe_handle_ != INVALID_HANDLE_VALUE && mpv_pipe_handle_ != nullptr) {
    CloseHandle(mpv_pipe_handle_);
    mpv_pipe_handle_ = INVALID_HANDLE_VALUE;
  }

  if (mpv_stderr_read_ != nullptr && mpv_stderr_read_ != INVALID_HANDLE_VALUE) {
    CloseHandle(mpv_stderr_read_);
    mpv_stderr_read_ = nullptr;
  }

  mpv_pid_ = 0;
  mpv_hwnd_ = nullptr;
  mpv_window_attached_ = false;
  mpv_window_visible_ = false;
  mpv_width_ = 0;
  mpv_height_ = 0;
  mpv_pipe_name_.clear();
  mpv_ipc_read_buffer_.clear();
  mpv_stderr_buffer_.clear();
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

  // Flush desktop window composition to seamlessly reveal desktop background
  DwmFlush();

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

bool LiveWallpaperPlugin::Impl::SetWidgetDesktopSurface(
    bool attach_to_desktop) {
  HWND target = root_window_ ? root_window_ : window_;
  const auto fail = [target](const char* step) {
    LogProcessDiagnostic(
        "widget_desktop_surface",
        std::string("result=failed step=") + step +
            " hwnd=" + std::to_string(reinterpret_cast<intptr_t>(target)) +
            " error=" + std::to_string(GetLastError()));
    return false;
  };
  if (!target || !IsWindow(target)) {
    return fail("invalid_window");
  }

  RECT screen_bounds{};
  if (!GetWindowRect(target, &screen_bounds)) {
    return fail("get_window_rect");
  }

  HWND parent = nullptr;
  HWND insert_after = nullptr;
  bool raised_desktop = false;
  bool use_layered_window = false;
  if (attach_to_desktop) {
    parent = FindDesktopWallpaperTarget(
        &insert_after, &raised_desktop, &use_layered_window);
    if (!parent || !IsWindow(parent)) {
      return fail("desktop_host_not_found");
    }
  }

  POINT corners[2] = {{screen_bounds.left, screen_bounds.top},
                      {screen_bounds.right, screen_bounds.bottom}};
  if (attach_to_desktop) {
    SetLastError(ERROR_SUCCESS);
    if (MapWindowPoints(HWND_DESKTOP, parent, corners, 2) == 0 &&
        GetLastError() != ERROR_SUCCESS) {
      return fail("map_window_points");
    }
  }

  LONG_PTR style = GetWindowLongPtrW(target, GWL_STYLE);
  LONG_PTR extended_style = GetWindowLongPtrW(target, GWL_EXSTYLE);
  style &= ~(WS_CHILD | WS_POPUP | WS_CAPTION | WS_THICKFRAME |
             WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU);
  extended_style &= ~WS_EX_APPWINDOW;
  extended_style |= WS_EX_TOOLWINDOW;

  if (attach_to_desktop) {
    style |= WS_CHILD;
    extended_style &= ~WS_EX_TOPMOST;
    if (use_layered_window) {
      extended_style |= WS_EX_LAYERED;
    }
  } else {
    style |= WS_POPUP;
  }

  SetWindowLongPtrW(target, GWL_STYLE, style);
  SetWindowLongPtrW(target, GWL_EXSTYLE, extended_style);
  if (attach_to_desktop && use_layered_window &&
      !SetLayeredWindowAttributes(target, 0, 255, LWA_ALPHA)) {
    return fail("set_layered_attributes");
  }

  SetLastError(ERROR_SUCCESS);
  const HWND previous_parent = SetParent(target, parent);
  const DWORD parent_error = GetLastError();
  const HWND actual_parent = GetParent(target);
  if ((attach_to_desktop && actual_parent != parent) ||
      (!attach_to_desktop && actual_parent != nullptr)) {
    LogProcessDiagnostic(
        "widget_desktop_surface",
        "result=failed step=set_parent hwnd=" +
            std::to_string(reinterpret_cast<intptr_t>(target)) +
            " requestedParent=" +
            std::to_string(reinterpret_cast<intptr_t>(parent)) +
            " previousParent=" +
            std::to_string(reinterpret_cast<intptr_t>(previous_parent)) +
            " actualParent=" +
            std::to_string(reinterpret_cast<intptr_t>(actual_parent)) +
            " error=" + std::to_string(parent_error));
    return false;
  }

  const int left = attach_to_desktop ? corners[0].x : screen_bounds.left;
  const int top = attach_to_desktop ? corners[0].y : screen_bounds.top;
  const int width = screen_bounds.right - screen_bounds.left;
  const int height = screen_bounds.bottom - screen_bounds.top;
  const UINT flags = SWP_NOACTIVATE | SWP_FRAMECHANGED;
  const HWND z_order = attach_to_desktop
                           ? (raised_desktop ? HWND_TOP : insert_after)
                           : ((extended_style & WS_EX_TOPMOST) != 0
                                  ? HWND_TOPMOST
                                  : HWND_TOP);
  if (!SetWindowPos(target, z_order, left, top, width, height, flags)) {
    return fail("set_window_pos");
  }
  widget_desktop_attached_ = attach_to_desktop;
  widget_desktop_parent_ = attach_to_desktop ? parent : nullptr;

  LogProcessDiagnostic(
      "widget_desktop_surface",
      std::string("result=success attached=") +
          (attach_to_desktop ? "true" : "false") +
          " hwnd=" + std::to_string(reinterpret_cast<intptr_t>(target)) +
          " parent=" + std::to_string(reinterpret_cast<intptr_t>(parent)) +
          " raisedDesktop=" + (raised_desktop ? "true" : "false") +
          " zOrder=" +
          (attach_to_desktop && raised_desktop ? "above_desktop_view"
                                               : "desktop_default"));
  return true;
}

bool LiveWallpaperPlugin::Impl::ShowWidgetWindow() {
  HWND target = root_window_ ? root_window_ : window_;
  if (!target || !IsWindow(target)) {
    LogProcessDiagnostic(
        "window_visibility_failure",
        "result=failed reason=invalid_window hwnd=" +
            std::to_string(reinterpret_cast<intptr_t>(target)));
    return false;
  }

  ShowWindow(target, SW_SHOWNOACTIVATE);
  const bool visible = IsWindowVisible(target) != FALSE;
  LogProcessDiagnostic(
      "window_shown",
      std::string("request=SW_SHOWNOACTIVATE hwnd=") +
          std::to_string(reinterpret_cast<intptr_t>(target)) +
          " isWindow=" + (IsWindow(target) ? "true" : "false") +
          " isVisible=" + (visible ? "true" : "false") +
          " iconic=" + (IsIconic(target) ? "true" : "false"));
  return true;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::VerifyWidgetPresentation(
    bool expected_topmost) {
  HWND target = root_window_ ? root_window_ : window_;
  const auto fail = [target](const char* classification,
                             const char* reason) {
    LogProcessDiagnostic(
        classification,
        std::string("result=failed reason=") + reason +
            " hwnd=" + std::to_string(reinterpret_cast<intptr_t>(target)));
    flutter::EncodableMap failure;
    failure[flutter::EncodableValue("presentationVerified")] =
        flutter::EncodableValue(false);
    failure[flutter::EncodableValue("classification")] =
        flutter::EncodableValue(classification);
    failure[flutter::EncodableValue("reason")] =
        flutter::EncodableValue(reason);
    failure[flutter::EncodableValue("presentationEvidence")] =
        flutter::EncodableValue(
            "native window validation failed; Flutter pixel presentation "
            "is not directly observable");
    failure[flutter::EncodableValue("pixelPresentationVerified")] =
        flutter::EncodableValue(false);
    return failure;
  };

  if (!target || !IsWindow(target)) {
    return fail("hwnd_creation_failure", "invalid_window");
  }
  if (force_redraw_) {
    force_redraw_();
  }
  if (!RedrawWindow(target, nullptr, nullptr,
                    RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN)) {
    return fail("presentation_failure", "redraw_window_failed");
  }

  const HRESULT flush_result = DwmFlush();
  if (FAILED(flush_result)) {
    LogProcessDiagnostic(
        "presentation_failure",
        "result=failed reason=dwm_flush_failed hwnd=" +
            std::to_string(reinterpret_cast<intptr_t>(target)) +
            " hresult=" + std::to_string(flush_result));
    flutter::EncodableMap failure;
    failure[flutter::EncodableValue("presentationVerified")] =
        flutter::EncodableValue(false);
    failure[flutter::EncodableValue("classification")] =
        flutter::EncodableValue("presentation_failure");
    failure[flutter::EncodableValue("reason")] =
        flutter::EncodableValue("dwm_flush_failed");
    failure[flutter::EncodableValue("presentationEvidence")] =
        flutter::EncodableValue(
            "DWM flush failed; Flutter pixel presentation is not directly "
            "observable");
    failure[flutter::EncodableValue("pixelPresentationVerified")] =
        flutter::EncodableValue(false);
    return failure;
  }

  auto result = GetNativeWindowInfo();
  const bool valid =
      std::get<bool>(result[flutter::EncodableValue("isValid")]);
  const bool visible =
      std::get<bool>(result[flutter::EncodableValue("isVisible")]);
  const bool on_monitor =
      std::get<bool>(result[flutter::EncodableValue("onMonitor")]);
  const bool iconic =
      std::get<bool>(result[flutter::EncodableValue("isIconic")]);
  const bool cloaked_available =
      std::get<bool>(result[flutter::EncodableValue("cloakedAvailable")]);
  const bool cloaked =
      std::get<bool>(result[flutter::EncodableValue("isCloaked")]);
  const auto actual_parent =
      std::get<int64_t>(result[flutter::EncodableValue("parentHwnd")]);
  const auto extended_style =
      std::get<int64_t>(result[flutter::EncodableValue("extendedStyle")]);
  const auto style =
      std::get<int64_t>(result[flutter::EncodableValue("style")]);
  const auto width =
      std::get<int64_t>(result[flutter::EncodableValue("width")]);
  const auto height =
      std::get<int64_t>(result[flutter::EncodableValue("height")]);
  const auto client_width =
      std::get<int64_t>(result[flutter::EncodableValue("clientWidth")]);
  const auto client_height =
      std::get<int64_t>(result[flutter::EncodableValue("clientHeight")]);
  const bool parent_valid =
      widget_desktop_attached_
          ? actual_parent ==
                reinterpret_cast<int64_t>(widget_desktop_parent_)
          : actual_parent == 0;
  const bool child_style = (style & WS_CHILD) != 0;
  const bool window_style_valid =
      widget_desktop_attached_ ? child_style : !child_style;
  const bool topmost = (extended_style & WS_EX_TOPMOST) != 0;
  const bool z_order_valid = parent_valid && topmost == expected_topmost;
  const bool presented =
      valid && visible && on_monitor && !iconic &&
      (!cloaked_available || !cloaked) && z_order_valid && width > 0 &&
      height > 0 && client_width > 0 && client_height > 0 &&
      window_style_valid;
  const char* classification =
      !valid ? "hwnd_creation_failure"
      : !visible || iconic ? "window_visibility_failure"
      : !on_monitor || width <= 0 || height <= 0 || client_width <= 0 ||
                client_height <= 0
          ? "window_bounds_failure"
      : !window_style_valid ? "window_style_failure"
      : !z_order_valid ? "z_order_failure"
                       : "presentation_failure";
  result[flutter::EncodableValue("presentationVerified")] =
      flutter::EncodableValue(presented);
  result[flutter::EncodableValue("classification")] =
      flutter::EncodableValue(presented ? "presentation_success"
                                        : classification);
  result[flutter::EncodableValue("dwmFlushHresult")] =
      flutter::EncodableValue(static_cast<int64_t>(flush_result));
  result[flutter::EncodableValue("desktopAttached")] =
      flutter::EncodableValue(widget_desktop_attached_);
  result[flutter::EncodableValue("isTopmost")] =
      flutter::EncodableValue(topmost);
  result[flutter::EncodableValue("windowStyleValid")] =
      flutter::EncodableValue(window_style_valid);
  result[flutter::EncodableValue("clientAreaUsable")] =
      flutter::EncodableValue(client_width > 0 && client_height > 0);
  result[flutter::EncodableValue("presentationEvidence")] =
      flutter::EncodableValue(
          "native HWND geometry/style/visibility checks and DWM flush; "
          "Flutter pixel presentation is not directly observable");
  result[flutter::EncodableValue("pixelPresentationVerified")] =
      flutter::EncodableValue(false);

  std::ostringstream details;
  details << "result=" << (presented ? "verified" : "failed")
          << " hwnd=" << reinterpret_cast<intptr_t>(target)
          << " valid=" << valid << " visible=" << visible
          << " onMonitor=" << on_monitor << " iconic=" << iconic
          << " cloakedAvailable=" << cloaked_available
          << " cloaked=" << cloaked << " parent=" << actual_parent
          << " desktopAttached=" << widget_desktop_attached_
          << " expectedParent="
          << reinterpret_cast<intptr_t>(widget_desktop_parent_)
          << " width=" << width << " height=" << height
          << " clientWidth=" << client_width
          << " clientHeight=" << client_height
          << " windowStyleValid=" << window_style_valid
          << " topmost=" << topmost
          << " expectedTopmost=" << expected_topmost
          << " dwmFlushHresult=" << flush_result;
  LogProcessDiagnostic(presented ? "presentation_success" : classification,
                       details.str());
  return result;
}

bool LiveWallpaperPlugin::Impl::IsFullscreenForegroundWindow() const {
  HWND foreground = GetForegroundWindow();
  if (!foreground || !IsWindow(foreground) || !IsWindowVisible(foreground) || IsIconic(foreground)) {
    return false;
  }

  // Exclude WallSync's own process and any child/sibling WallSync overlay or widget processes
  DWORD fg_pid = 0;
  GetWindowThreadProcessId(foreground, &fg_pid);
  if (fg_pid != 0) {
    if (fg_pid == GetCurrentProcessId()) {
      return false;
    }
    HANDLE hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, fg_pid);
    if (hProc) {
      wchar_t procPath[MAX_PATH]{};
      DWORD size = MAX_PATH;
      if (QueryFullProcessImageNameW(hProc, 0, procPath, &size)) {
        std::wstring wsPath(procPath);
        std::transform(wsPath.begin(), wsPath.end(), wsPath.begin(), ::towlower);
        if (wsPath.find(L"wallsync") != std::wstring::npos) {
          CloseHandle(hProc);
          return false;
        }
      }
      CloseHandle(hProc);
    }
  }

  // Exclude WallSync's own application window
  if (root_window_ && (foreground == root_window_ || GetAncestor(foreground, GA_ROOT) == root_window_)) {
    return false;
  }

  // Exclude MPV live wallpaper window itself
  if (mpv_hwnd_ && (foreground == mpv_hwnd_ || GetAncestor(foreground, GA_ROOT) == mpv_hwnd_)) {
    return false;
  }

  // Check window title for WallSync windows (overlay, taskbar dock, diagnostics)
  wchar_t title[128]{};
  if (GetWindowTextW(foreground, title, 128) > 0) {
    if (wcsstr(title, L"WallSync") != nullptr) {
      return false;
    }
  }
  HWND root_fg = GetAncestor(foreground, GA_ROOT);
  if (!root_fg) root_fg = foreground;
  if (root_fg != foreground && GetWindowTextW(root_fg, title, 128) > 0) {
    if (wcsstr(title, L"WallSync") != nullptr) {
      return false;
    }
  }

  // Exclude Windows desktop and shell components

  wchar_t root_class[64]{};
  if (GetClassNameW(root_fg, root_class, 64) > 0) {
    if (wcscmp(root_class, L"Progman") == 0 ||
        wcscmp(root_class, L"WorkerW") == 0 ||
        wcscmp(root_class, L"Shell_TrayWnd") == 0 ||
        wcscmp(root_class, L"Shell_SecondaryTrayWnd") == 0 ||
        wcscmp(root_class, L"Windows.UI.Core.CoreWindow") == 0 ||
        wcscmp(root_class, L"XamlExplorerHostIslandWindow") == 0 ||
        wcscmp(root_class, L"Xaml_WindowedPopupClass") == 0 ||
        wcscmp(root_class, L"NotifyIconOverflowWindow") == 0 ||
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
        wcscmp(fg_class, L"XamlExplorerHostIslandWindow") == 0 ||
        wcscmp(fg_class, L"Xaml_WindowedPopupClass") == 0 ||
        wcscmp(fg_class, L"NotifyIconOverflowWindow") == 0) {
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

bool LiveWallpaperPlugin::Impl::IsFullscreenForegroundWindowOnMonitor(
    const std::string& monitor_id) const {
  if (monitor_id.empty() || !IsFullscreenForegroundWindow()) {
    return false;
  }
  HWND foreground = GetForegroundWindow();
  if (!foreground || !IsWindow(foreground)) {
    return false;
  }
  HWND root_window = GetAncestor(foreground, GA_ROOT);
  if (!root_window) {
    root_window = foreground;
  }
  RECT foreground_bounds{};
  if (!GetWindowRect(root_window, &foreground_bounds)) {
    return false;
  }
  const HMONITOR monitor =
      MonitorFromWindow(root_window, MONITOR_DEFAULTTONEAREST);
  MONITORINFOEXW monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfoW(monitor,
                       reinterpret_cast<MONITORINFO*>(&monitor_info))) {
    return false;
  }
  constexpr LONG kFullscreenBoundsTolerance = 12;
  const RECT& monitor_bounds = monitor_info.rcMonitor;
  if (foreground_bounds.left > monitor_bounds.left + kFullscreenBoundsTolerance ||
      foreground_bounds.top > monitor_bounds.top + kFullscreenBoundsTolerance ||
      foreground_bounds.right < monitor_bounds.right - kFullscreenBoundsTolerance ||
      foreground_bounds.bottom < monitor_bounds.bottom - kFullscreenBoundsTolerance) {
    return false;
  }

  const int expected_length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, monitor_id.c_str(), -1, nullptr, 0);
  if (expected_length <= 1) {
    return false;
  }
  std::wstring expected_id(static_cast<size_t>(expected_length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, monitor_id.c_str(),
                          -1, expected_id.data(), expected_length) == 0) {
    return false;
  }
  expected_id.pop_back();

  DISPLAY_DEVICEW display_device{};
  display_device.cb = sizeof(display_device);
  for (DWORD index = 0;
       EnumDisplayDevicesW(monitor_info.szDevice, index, &display_device, 0);
       ++index) {
    if (display_device.DeviceID[0] != L'\0' &&
        CompareStringOrdinal(expected_id.c_str(), -1,
                             display_device.DeviceID, -1, TRUE) ==
            CSTR_EQUAL) {
      return true;
    }
    display_device = {};
    display_device.cb = sizeof(display_device);
  }
  return false;
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
  if (taskbar_appbar_) {
    const auto appbar_result =
        taskbar_appbar_->HandleWindowMessage(message, wparam);
    if (appbar_result) {
      return appbar_result;
    }
  }
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
  } else if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_) {
    if (channel_) {
      channel_->InvokeMethod("onWindowsExplorerRestarted", nullptr);
    }
  }
  return std::nullopt;
}

void LiveWallpaperPlugin::Impl::OptimizeMemory() {
  // IMPORTANT: Do NOT call EmptyWorkingSet on the Flutter process while the window
  // is visible or rendering. Paging out D3D/DXGI swapchains, shader programs, and font
  // atlases causes severe raster thread stalls (up to 8.9s) when DWM/DXGI encounters
  // hard page faults during frame presentation.
  HeapCompact(GetProcessHeap(), 0);
  if (mpv_process_handle_ && mpv_process_handle_ != INVALID_HANDLE_VALUE) {
    EmptyWorkingSet(mpv_process_handle_);
    SetProcessWorkingSetSize(mpv_process_handle_, static_cast<SIZE_T>(-1), static_cast<SIZE_T>(-1));
  }
}

void LiveWallpaperPlugin::Impl::SetLowPowerMode(bool enable) {
  HANDLE current_proc = GetCurrentProcess();
  SetPriorityClass(current_proc, enable ? BELOW_NORMAL_PRIORITY_CLASS : NORMAL_PRIORITY_CLASS);

  // Configure Windows 11 EcoQoS (Power Throttling)
  PROCESS_POWER_THROTTLING_STATE throttling{};
  throttling.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  if (enable) {
    throttling.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
    throttling.StateMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
  } else {
    throttling.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
    throttling.StateMask = 0;
  }
  SetProcessInformation(current_proc, ProcessPowerThrottling, &throttling, sizeof(throttling));

  if (mpv_process_handle_ && mpv_process_handle_ != INVALID_HANDLE_VALUE) {
    SetPriorityClass(mpv_process_handle_, enable ? BELOW_NORMAL_PRIORITY_CLASS : NORMAL_PRIORITY_CLASS);
  }
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::GetPerformanceMetrics() {
  flutter::EncodableMap metrics;

  // 1. RAM metrics via GlobalMemoryStatusEx
  MEMORYSTATUSEX mem_status{};
  mem_status.dwLength = sizeof(mem_status);
  if (GlobalMemoryStatusEx(&mem_status)) {
    metrics[flutter::EncodableValue("ramLoadPercent")] =
        flutter::EncodableValue(static_cast<double>(mem_status.dwMemoryLoad));
    metrics[flutter::EncodableValue("totalPhysMb")] =
        flutter::EncodableValue(static_cast<double>(mem_status.ullTotalPhys / (1024 * 1024)));
    metrics[flutter::EncodableValue("availPhysMb")] =
        flutter::EncodableValue(static_cast<double>(mem_status.ullAvailPhys / (1024 * 1024)));
  }

  // 2. Process Private Working Set & Memory via GetProcessMemoryInfo
  PROCESS_MEMORY_COUNTERS_EX pmc{};
  if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&pmc), sizeof(pmc))) {
    metrics[flutter::EncodableValue("processWorkingSetMb")] =
        flutter::EncodableValue(static_cast<double>(pmc.WorkingSetSize / (1024 * 1024)));
    metrics[flutter::EncodableValue("processPrivateBytesMb")] =
        flutter::EncodableValue(static_cast<double>(pmc.PrivateUsage / (1024 * 1024)));
  }
  if (mpv_process_handle_ && mpv_process_handle_ != INVALID_HANDLE_VALUE) {
    PROCESS_MEMORY_COUNTERS_EX mpv_pmc{};
    if (GetProcessMemoryInfo(mpv_process_handle_, reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&mpv_pmc), sizeof(mpv_pmc))) {
      metrics[flutter::EncodableValue("mpvWorkingSetMb")] =
          flutter::EncodableValue(static_cast<double>(mpv_pmc.WorkingSetSize / (1024 * 1024)));
      metrics[flutter::EncodableValue("mpvPrivateBytesMb")] =
          flutter::EncodableValue(static_cast<double>(mpv_pmc.PrivateUsage / (1024 * 1024)));
    }
  }

  // 3. CPU metrics via GetSystemTimes
  FILETIME idle_time{}, kernel_time{}, user_time{};
  if (GetSystemTimes(&idle_time, &kernel_time, &user_time)) {
    uint64_t idle = (static_cast<uint64_t>(idle_time.dwHighDateTime) << 32) | idle_time.dwLowDateTime;
    uint64_t kernel = (static_cast<uint64_t>(kernel_time.dwHighDateTime) << 32) | kernel_time.dwLowDateTime;
    uint64_t user = (static_cast<uint64_t>(user_time.dwHighDateTime) << 32) | user_time.dwLowDateTime;

    static uint64_t s_prev_idle = 0;
    static uint64_t s_prev_kernel = 0;
    static uint64_t s_prev_user = 0;
    static double s_prev_cpu = 0.0;

    if (s_prev_idle != 0 && user >= s_prev_user && kernel >= s_prev_kernel && idle >= s_prev_idle) {
      uint64_t usr = user - s_prev_user;
      uint64_t ker = kernel - s_prev_kernel;
      uint64_t idl = idle - s_prev_idle;
      uint64_t sys = usr + ker;
      if (sys > 0 && sys >= idl) {
        s_prev_cpu = std::clamp((((sys - idl) * 100.0) / sys), 0.0, 100.0);
      }
    }
    s_prev_idle = idle;
    s_prev_kernel = kernel;
    s_prev_user = user;
    metrics[flutter::EncodableValue("cpuPercent")] = flutter::EncodableValue(s_prev_cpu);
  }

  // 4. Power & Battery status via GetSystemPowerStatus
  SYSTEM_POWER_STATUS pwr{};
  if (GetSystemPowerStatus(&pwr)) {
    metrics[flutter::EncodableValue("batteryPercent")] =
        flutter::EncodableValue(pwr.BatteryLifePercent <= 100 ? static_cast<int>(pwr.BatteryLifePercent) : -1);
    metrics[flutter::EncodableValue("isAcConnected")] =
        flutter::EncodableValue(pwr.ACLineStatus == 1);
    metrics[flutter::EncodableValue("isCharging")] =
        flutter::EncodableValue((pwr.BatteryFlag & 8) != 0);
  }

  return metrics;
}

bool LiveWallpaperPlugin::Impl::SetStaticWallpaper(const std::wstring& path, const std::string& style) {
  bool applied = false;
  std::thread worker([&applied, &path, &style]() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    {
      winrt::com_ptr<IDesktopWallpaper> wallpaper;
      HRESULT create_hr = CoCreateInstance(
          CLSID_DesktopWallpaper, nullptr, CLSCTX_ALL, IID_PPV_ARGS(wallpaper.put()));
      if (SUCCEEDED(create_hr) && wallpaper) {
        HRESULT set_hr = wallpaper->SetWallpaper(nullptr, path.c_str());
        if (SUCCEEDED(set_hr)) {
          DESKTOP_WALLPAPER_POSITION pos = DWPOS_FILL;
          if (style == "fit") pos = DWPOS_FIT;
          else if (style == "stretch") pos = DWPOS_STRETCH;
          else if (style == "tile") pos = DWPOS_TILE;
          else if (style == "center") pos = DWPOS_CENTER;
          else if (style == "span") pos = DWPOS_SPAN;
          wallpaper->SetPosition(pos);
          applied = true;
        }
      }
    } // wallpaper smart pointer is safely released before CoUninitialize

    if (!applied) {
      BOOL spi_res = SystemParametersInfoW(
          SPI_SETDESKWALLPAPER, 0, const_cast<wchar_t*>(path.c_str()),
          SPIF_UPDATEINIFILE | SPIF_SENDCHANGE);
      applied = (spi_res != 0);
    }

    if (SUCCEEDED(hr)) {
      CoUninitialize();
    }
  });
  worker.join();
  return applied;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::GetGpuAndDisplayInfo() {
  flutter::EncodableMap info;

  // 1. GPU Adapter Information via DXGI
  // Enumerate all adapters to choose the discrete high-performance GPU if present
  winrt::com_ptr<IDXGIFactory1> factory;
  if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(factory.put())))) {
    winrt::com_ptr<IDXGIAdapter1> best_adapter;
    DXGI_ADAPTER_DESC1 best_desc{};
    SIZE_T max_vram = 0;
    bool found_gpu = false;

    for (UINT i = 0;; ++i) {
      winrt::com_ptr<IDXGIAdapter1> adapter;
      if (factory->EnumAdapters1(i, adapter.put()) == DXGI_ERROR_NOT_FOUND) {
        break;
      }
      DXGI_ADAPTER_DESC1 desc{};
      if (SUCCEEDED(adapter->GetDesc1(&desc))) {
        // Skip software rasterizers (e.g. Microsoft Basic Render Driver)
        if ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) continue;
        if (!found_gpu || desc.DedicatedVideoMemory > max_vram) {
          max_vram = desc.DedicatedVideoMemory;
          best_desc = desc;
          best_adapter = adapter;
          found_gpu = true;
        }
      }
    }

    if (found_gpu) {
      char name_buf[128]{};
      WideCharToMultiByte(CP_UTF8, 0, best_desc.Description, -1, name_buf, sizeof(name_buf), nullptr, nullptr);
      info[flutter::EncodableValue("gpuName")] = flutter::EncodableValue(std::string(name_buf));
      info[flutter::EncodableValue("dedicatedVramMb")] =
          flutter::EncodableValue(static_cast<double>(best_desc.DedicatedVideoMemory / (1024 * 1024)));
      info[flutter::EncodableValue("sharedVramMb")] =
          flutter::EncodableValue(static_cast<double>(best_desc.SharedSystemMemory / (1024 * 1024)));
    }
  }

  // 2. Primary Monitor Information
  HMONITOR primary = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFOEXW mi{};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfoW(primary, &mi)) {
    int width = mi.rcMonitor.right - mi.rcMonitor.left;
    int height = mi.rcMonitor.bottom - mi.rcMonitor.top;
    int work_width = mi.rcWork.right - mi.rcWork.left;
    int work_height = mi.rcWork.bottom - mi.rcWork.top;
    info[flutter::EncodableValue("screenWidth")] = flutter::EncodableValue(width);
    info[flutter::EncodableValue("screenHeight")] = flutter::EncodableValue(height);
    info[flutter::EncodableValue("workAreaWidth")] = flutter::EncodableValue(work_width);
    info[flutter::EncodableValue("workAreaHeight")] = flutter::EncodableValue(work_height);

    DEVMODEW dm{};
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(mi.szDevice, ENUM_CURRENT_SETTINGS, &dm)) {
      info[flutter::EncodableValue("refreshRateHz")] = flutter::EncodableValue(static_cast<int>(dm.dmDisplayFrequency));
    }
  }

  return info;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::GetMediaSessionInfo() {
  flutter::EncodableMap media;
  media[flutter::EncodableValue("title")] = flutter::EncodableValue("");
  media[flutter::EncodableValue("artist")] = flutter::EncodableValue("");
  media[flutter::EncodableValue("album")] = flutter::EncodableValue("");
  media[flutter::EncodableValue("status")] = flutter::EncodableValue("Closed");
  media[flutter::EncodableValue("source")] = flutter::EncodableValue("");
  media[flutter::EncodableValue("canPlay")] = flutter::EncodableValue(false);
  media[flutter::EncodableValue("canPause")] = flutter::EncodableValue(false);
  media[flutter::EncodableValue("canGoNext")] = flutter::EncodableValue(false);
  media[flutter::EncodableValue("canGoPrevious")] = flutter::EncodableValue(false);
  media[flutter::EncodableValue("position")] = flutter::EncodableValue(0);
  media[flutter::EncodableValue("duration")] = flutter::EncodableValue(0);

  std::thread worker([&media]() {
    ApartmentScope apartment;
    if (!apartment.initialized_) return;
    try {
      using namespace winrt::Windows::Media::Control;
      auto manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
      if (!manager) return;
      auto session = manager.GetCurrentSession();
      if (!session) return;

      auto source_id = winrt::to_string(session.SourceAppUserModelId());
      std::string lower_source = source_id;
      std::transform(lower_source.begin(), lower_source.end(), lower_source.begin(),
                     [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
      if (lower_source.find("mpv") != std::string::npos || lower_source.find("wallsync") != std::string::npos) {
        return;
      }
      media[flutter::EncodableValue("source")] = flutter::EncodableValue(source_id);

      auto playback_info = session.GetPlaybackInfo();
      if (playback_info) {
        auto status = playback_info.PlaybackStatus();
        if (status == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing) {
          media[flutter::EncodableValue("status")] = flutter::EncodableValue("Playing");
        } else if (status == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Paused) {
          media[flutter::EncodableValue("status")] = flutter::EncodableValue("Paused");
        } else if (status == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Stopped) {
          media[flutter::EncodableValue("status")] = flutter::EncodableValue("Stopped");
        }

        auto controls = playback_info.Controls();
        if (controls) {
          media[flutter::EncodableValue("canPlay")] = flutter::EncodableValue(controls.IsPlayEnabled());
          media[flutter::EncodableValue("canPause")] = flutter::EncodableValue(controls.IsPauseEnabled());
          media[flutter::EncodableValue("canGoNext")] = flutter::EncodableValue(controls.IsNextEnabled());
          media[flutter::EncodableValue("canGoPrevious")] = flutter::EncodableValue(controls.IsPreviousEnabled());
        }
      }

      auto props = session.TryGetMediaPropertiesAsync().get();
      if (props) {
        media[flutter::EncodableValue("title")] = flutter::EncodableValue(winrt::to_string(props.Title()));
        media[flutter::EncodableValue("artist")] = flutter::EncodableValue(winrt::to_string(props.Artist()));
        media[flutter::EncodableValue("album")] = flutter::EncodableValue(winrt::to_string(props.AlbumTitle()));
      }

      auto timeline = session.GetTimelineProperties();
      if (timeline) {
        auto pos = std::chrono::duration_cast<std::chrono::seconds>(timeline.Position()).count();
        auto dur = std::chrono::duration_cast<std::chrono::seconds>(timeline.EndTime()).count();
        media[flutter::EncodableValue("position")] = flutter::EncodableValue(static_cast<int>(pos));
        media[flutter::EncodableValue("duration")] = flutter::EncodableValue(static_cast<int>(dur));
      }
    } catch (...) {
    }
  });
  worker.join();

  return media;
}

bool LiveWallpaperPlugin::Impl::ControlMediaSession(const std::string& action) {
  bool success = false;
  std::thread worker([&success, &action]() {
    ApartmentScope apartment;
    if (!apartment.initialized_) return;
    try {
      using namespace winrt::Windows::Media::Control;
      auto manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
      if (!manager) return;
      auto session = manager.GetCurrentSession();
      if (!session) return;

      if (action == "play") success = session.TryPlayAsync().get();
      else if (action == "pause") success = session.TryPauseAsync().get();
      else if (action == "toggle") success = session.TryTogglePlayPauseAsync().get();
      else if (action == "next") success = session.TrySkipNextAsync().get();
      else if (action == "previous") success = session.TrySkipPreviousAsync().get();
    } catch (...) {
    }
  });
  worker.join();
  return success;
}

bool LiveWallpaperPlugin::Impl::SetWindowClickThrough(bool enable) {
  if (!window_ || !IsWindow(window_)) return false;
  HWND root = root_window_ ? root_window_ : window_;
  LONG_PTR ex_style = GetWindowLongPtrW(root, GWL_EXSTYLE);
  if (enable) {
    ex_style |= (WS_EX_TRANSPARENT | WS_EX_LAYERED);
    SetWindowLongPtrW(root, GWL_EXSTYLE, ex_style);
    SetLayeredWindowAttributes(root, 0, 255, LWA_ALPHA);
  } else {
    ex_style &= ~WS_EX_TRANSPARENT;
    SetWindowLongPtrW(root, GWL_EXSTYLE, ex_style);
  }
  SetWindowPos(root, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  return true;
}

bool LiveWallpaperPlugin::Impl::PinWindowToBottom() {
  if (!window_ || !IsWindow(window_)) return false;
  HWND root = root_window_ ? root_window_ : window_;
  SetWindowPos(root, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  return true;
}

namespace {
typedef enum _ACCENT_STATE {
  ACCENT_DISABLED = 0,
  ACCENT_ENABLE_GRADIENT = 1,
  ACCENT_ENABLE_TRANSPARENTGRADIENT = 2,
  ACCENT_ENABLE_BLURBEHIND = 3,
  ACCENT_ENABLE_ACRYLICBLURBEHIND = 4,
  ACCENT_INVALID_STATE = 5
} ACCENT_STATE;

struct ACCENT_POLICY {
  ACCENT_STATE AccentState;
  DWORD AccentFlags;
  DWORD GradientColor;
  DWORD AnimationId;
};

struct WINCOMPATTRDATA {
  DWORD attribute;
  PVOID pData;
  ULONG dataSize;
};

typedef BOOL(WINAPI* pSetWindowCompositionAttribute)(HWND, WINCOMPATTRDATA*);
}  // namespace

bool LiveWallpaperPlugin::Impl::SetDesktopIconsVisible(bool visible) {
  HWND def_view = FindDesktopDefView();
  if (!def_view) return false;
  ShowWindow(def_view, visible ? SW_SHOW : SW_HIDE);
  UpdateWindow(def_view);
  return true;
}

bool LiveWallpaperPlugin::Impl::GetDesktopIconsVisible() {
  HWND def_view = FindDesktopDefView();
  if (!def_view) return true;
  return IsWindowVisible(def_view) != FALSE;
}

bool LiveWallpaperPlugin::Impl::SetTaskbarBlur(int mode) {
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (!user32) return false;
  auto setAttr = reinterpret_cast<pSetWindowCompositionAttribute>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (!setAttr) return false;

  ACCENT_POLICY policy{};
  if (mode == 1) {
    policy.AccentState = ACCENT_ENABLE_TRANSPARENTGRADIENT;
    policy.AccentFlags = 2;
    policy.GradientColor = 0x00000000;
  } else if (mode == 2) {
    policy.AccentState = ACCENT_ENABLE_ACRYLICBLURBEHIND;
    policy.AccentFlags = 2;
    policy.GradientColor = 0xAA000000;
  } else if (mode == 3) {
    policy.AccentState = ACCENT_ENABLE_BLURBEHIND;
    policy.AccentFlags = 2;
  } else {
    policy.AccentState = ACCENT_DISABLED;
  }

  WINCOMPATTRDATA data{};
  data.attribute = 19;  // WCA_ACCENT_POLICY
  data.pData = &policy;
  data.dataSize = sizeof(policy);

  HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr);
  if (tray) {
    setAttr(tray, &data);
  }

  HWND sec_tray = nullptr;
  do {
    sec_tray = FindWindowExW(nullptr, sec_tray, L"Shell_SecondaryTrayWnd", nullptr);
    if (sec_tray) {
      setAttr(sec_tray, &data);
    }
  } while (sec_tray);

  return true;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::ConfigureTaskbarAppBar(
    const flutter::EncodableMap* args) {
  flutter::EncodableMap response;
  const auto edge_entry = args->find(flutter::EncodableValue("edge"));
  const auto thickness_entry =
      args->find(flutter::EncodableValue("thickness"));
  const auto length_entry = args->find(flutter::EncodableValue("length"));
  const auto auto_hide_entry =
      args->find(flutter::EncodableValue("autoHide"));
  const auto revision_entry = args->find(flutter::EncodableValue("revision"));
  if (edge_entry == args->end() || thickness_entry == args->end() ||
      length_entry == args->end() || auto_hide_entry == args->end() ||
      revision_entry == args->end()) {
    response[flutter::EncodableValue("success")] =
        flutter::EncodableValue(false);
    response[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Configuration is missing required fields.");
    return response;
  }

  const std::string edge = GetStringFromEncodable(edge_entry->second);
  const int thickness = GetIntFromEncodable(thickness_entry->second, -1);
  const int length = GetIntFromEncodable(length_entry->second, -1);
  const bool auto_hide =
      GetBoolFromEncodable(auto_hide_entry->second, false);
  const int revision = GetIntFromEncodable(revision_entry->second, -1);
  DWORD owner_pid = 0;
  if (!root_window_ || !IsWindow(root_window_) ||
      GetWindowThreadProcessId(root_window_, &owner_pid) == 0 ||
      owner_pid != GetCurrentProcessId()) {
    response[flutter::EncodableValue("success")] =
        flutter::EncodableValue(false);
    response[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Taskbar host HWND ownership is invalid.");
    return response;
  }

  if (!taskbar_appbar_) {
    taskbar_appbar_ = std::make_unique<TaskbarAppBar>(root_window_);
  }
  std::string error;
  const bool applied = taskbar_appbar_->Apply(
      {edge, thickness, length, auto_hide, revision}, &error);
  response[flutter::EncodableValue("success")] =
      flutter::EncodableValue(applied);
  response[flutter::EncodableValue("revision")] =
      flutter::EncodableValue(revision);
  response[flutter::EncodableValue("appliedRevision")] =
      flutter::EncodableValue(taskbar_appbar_->applied_revision());
  response[flutter::EncodableValue("hwnd")] = flutter::EncodableValue(
      static_cast<int64_t>(reinterpret_cast<intptr_t>(root_window_)));
  response[flutter::EncodableValue("ownerPid")] =
      flutter::EncodableValue(static_cast<int64_t>(owner_pid));
  response[flutter::EncodableValue("left")] =
      flutter::EncodableValue(
          static_cast<int32_t>(taskbar_appbar_->bounds().left));
  response[flutter::EncodableValue("top")] =
      flutter::EncodableValue(
          static_cast<int32_t>(taskbar_appbar_->bounds().top));
  response[flutter::EncodableValue("right")] =
      flutter::EncodableValue(
          static_cast<int32_t>(taskbar_appbar_->bounds().right));
  response[flutter::EncodableValue("bottom")] =
      flutter::EncodableValue(
          static_cast<int32_t>(taskbar_appbar_->bounds().bottom));
  if (!applied) {
    response[flutter::EncodableValue("error")] =
        flutter::EncodableValue(error);
    LogProcessDiagnostic("taskbar_appbar_configuration",
                         "result=failed revision=" +
                             std::to_string(revision) + " error=" + error);
  }
  return response;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::SetTaskbarAppBarVisible(
    bool visible) {
  flutter::EncodableMap response;
  std::string error;
  const bool success =
      taskbar_appbar_ && taskbar_appbar_->SetVisible(visible, &error);
  response[flutter::EncodableValue("success")] =
      flutter::EncodableValue(success);
  if (!success) {
    response[flutter::EncodableValue("error")] = flutter::EncodableValue(
        taskbar_appbar_ ? error : "The taskbar AppBar has not been configured.");
  }
  return response;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::GetWindowsTaskbarInfo() {
  flutter::EncodableMap info;
  HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr);
  bool primary_present = (tray != nullptr);
  bool primary_visible = false;
  flutter::EncodableMap rect_map;
  if (tray) {
    primary_visible = (IsWindowVisible(tray) != FALSE);
    RECT r{};
    GetWindowRect(tray, &r);
    rect_map[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int64_t>(r.left));
    rect_map[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int64_t>(r.top));
    rect_map[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int64_t>(r.right));
    rect_map[flutter::EncodableValue("bottom")] = flutter::EncodableValue(static_cast<int64_t>(r.bottom));
    rect_map[flutter::EncodableValue("width")] = flutter::EncodableValue(static_cast<int64_t>(r.right - r.left));
    rect_map[flutter::EncodableValue("height")] = flutter::EncodableValue(static_cast<int64_t>(r.bottom - r.top));
  }
  int64_t secondary_count = 0;
  int64_t secondary_visible_count = 0;
  HWND sec_tray = nullptr;
  while ((sec_tray = FindWindowExW(nullptr, sec_tray, L"Shell_SecondaryTrayWnd", nullptr)) != nullptr) {
    secondary_count++;
    if (IsWindowVisible(sec_tray)) {
      secondary_visible_count++;
    }
  }

  info[flutter::EncodableValue("primaryPresent")] = flutter::EncodableValue(primary_present);
  info[flutter::EncodableValue("primaryVisible")] = flutter::EncodableValue(primary_visible);
  info[flutter::EncodableValue("primaryRect")] = flutter::EncodableValue(rect_map);
  info[flutter::EncodableValue("secondaryCount")] = flutter::EncodableValue(secondary_count);
  info[flutter::EncodableValue("secondaryVisibleCount")] = flutter::EncodableValue(secondary_visible_count);
  info[flutter::EncodableValue("allVisible")] = flutter::EncodableValue(primary_visible && (secondary_count == 0 || secondary_visible_count == secondary_count));
  info[flutter::EncodableValue("anyVisible")] = flutter::EncodableValue(primary_visible || secondary_visible_count > 0);
  return info;
}

bool LiveWallpaperPlugin::Impl::SetWindowsTaskbarVisibility(bool visible) {
  if (!visible) {
    return false;
  }

  HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr);
  if (tray) {
    LONG_PTR style = GetWindowLongPtrW(tray, GWL_STYLE);
    SetWindowLongPtrW(tray, GWL_STYLE, style | WS_VISIBLE);
    ShowWindow(tray, SW_SHOW);
    SetWindowPos(tray, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
    SetWindowPos(tray, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  HWND sec_tray = nullptr;
  while ((sec_tray = FindWindowExW(nullptr, sec_tray, L"Shell_SecondaryTrayWnd", nullptr)) != nullptr) {
    LONG_PTR style = GetWindowLongPtrW(sec_tray, GWL_STYLE);
    SetWindowLongPtrW(sec_tray, GWL_STYLE, style | WS_VISIBLE);
    ShowWindow(sec_tray, SW_SHOW);
    SetWindowPos(sec_tray, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
    SetWindowPos(sec_tray, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  SystemParametersInfoW(SPI_SETWORKAREA, 0, nullptr, SPIF_SENDCHANGE);
  RedrawWindow(nullptr, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);

  return true;
}

struct WindowSearchContext {
  std::string title_query;
  DWORD pid_query = 0;
  HWND matched_hwnd = nullptr;
  bool is_visible = false;
  RECT rect{};
};

static BOOL CALLBACK EnumWindowsSearchCallback(HWND hwnd, LPARAM lParam) {
  auto* ctx = reinterpret_cast<WindowSearchContext*>(lParam);
  if (ctx->pid_query != 0) {
    DWORD win_pid = 0;
    GetWindowThreadProcessId(hwnd, &win_pid);
    if (win_pid != ctx->pid_query) return TRUE;
  }
  if (!ctx->title_query.empty()) {
    wchar_t buf[512] = {0};
    GetWindowTextW(hwnd, buf, 512);
    std::string s = WideToUtf8(buf);
    if (s.find(ctx->title_query) == std::string::npos) return TRUE;
  }
  ctx->matched_hwnd = hwnd;
  ctx->is_visible = (IsWindowVisible(hwnd) != FALSE);
  GetWindowRect(hwnd, &ctx->rect);
  return FALSE;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::FindWindowByTitleOrPid(
    const std::string& title_query, DWORD pid_query) {
  flutter::EncodableMap res;
  WindowSearchContext ctx;
  ctx.title_query = title_query;
  ctx.pid_query = pid_query;
  EnumWindows(EnumWindowsSearchCallback, reinterpret_cast<LPARAM>(&ctx));

  bool found = (ctx.matched_hwnd != nullptr);
  res[flutter::EncodableValue("found")] = flutter::EncodableValue(found);
  res[flutter::EncodableValue("hwnd")] = flutter::EncodableValue(reinterpret_cast<int64_t>(ctx.matched_hwnd));
  res[flutter::EncodableValue("visible")] = flutter::EncodableValue(ctx.is_visible);
  if (found) {
    flutter::EncodableMap rect_map;
    rect_map[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int64_t>(ctx.rect.left));
    rect_map[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int64_t>(ctx.rect.top));
    rect_map[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int64_t>(ctx.rect.right));
    rect_map[flutter::EncodableValue("bottom")] = flutter::EncodableValue(static_cast<int64_t>(ctx.rect.bottom));
    rect_map[flutter::EncodableValue("width")] = flutter::EncodableValue(static_cast<int64_t>(ctx.rect.right - ctx.rect.left));
    rect_map[flutter::EncodableValue("height")] = flutter::EncodableValue(static_cast<int64_t>(ctx.rect.bottom - ctx.rect.top));
    res[flutter::EncodableValue("rect")] = flutter::EncodableValue(rect_map);
  }
  return res;
}

int64_t LiveWallpaperPlugin::Impl::GetNativeWindowHandle() {
  HWND target = root_window_ ? root_window_ : window_;
  return reinterpret_cast<int64_t>(target);
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::GetNativeWindowInfo() {
  flutter::EncodableMap result;
  HWND target = root_window_ ? root_window_ : window_;
  DWORD owner_pid = 0;
  const DWORD thread_id =
      target != nullptr && IsWindow(target)
          ? GetWindowThreadProcessId(target, &owner_pid)
          : 0;
  RECT bounds{};
  RECT client_bounds{};
  const bool valid = target != nullptr && IsWindow(target) &&
                     owner_pid == GetCurrentProcessId() && thread_id != 0;
  const bool bounds_valid = valid && GetWindowRect(target, &bounds);
  const bool client_bounds_valid =
      valid && GetClientRect(target, &client_bounds);
  const LONG_PTR style = valid ? GetWindowLongPtrW(target, GWL_STYLE) : 0;
  const LONG_PTR extended_style =
      valid ? GetWindowLongPtrW(target, GWL_EXSTYLE) : 0;
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  const bool placement_valid =
      valid && GetWindowPlacement(target, &placement) != FALSE;
  DWORD cloaked = 0;
  const HRESULT cloaked_result =
      valid ? DwmGetWindowAttribute(target, DWMWA_CLOAKED, &cloaked,
                                    sizeof(cloaked))
            : E_INVALIDARG;
  const bool cloaked_available = SUCCEEDED(cloaked_result);
  const HMONITOR monitor =
      valid ? MonitorFromWindow(target, MONITOR_DEFAULTTONULL) : nullptr;
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  const bool monitor_info_valid =
      monitor != nullptr && GetMonitorInfoW(monitor, &monitor_info) != FALSE;
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  const bool intersects_monitor =
      monitor_info_valid && bounds_valid && width > 0 && height > 0 &&
      bounds.right > monitor_info.rcMonitor.left &&
      bounds.left < monitor_info.rcMonitor.right &&
      bounds.bottom > monitor_info.rcMonitor.top &&
      bounds.top < monitor_info.rcMonitor.bottom;
  const HWND parent = valid ? GetParent(target) : nullptr;
  const HWND owner = valid ? GetWindow(target, GW_OWNER) : nullptr;
  const HWND previous_sibling = valid ? GetWindow(target, GW_HWNDPREV) : nullptr;
  result[flutter::EncodableValue("hwnd")] =
      flutter::EncodableValue(reinterpret_cast<int64_t>(target));
  result[flutter::EncodableValue("ownerPid")] =
      flutter::EncodableValue(static_cast<int64_t>(owner_pid));
  result[flutter::EncodableValue("threadId")] =
      flutter::EncodableValue(static_cast<int64_t>(thread_id));
  result[flutter::EncodableValue("isValid")] =
      flutter::EncodableValue(valid);
  result[flutter::EncodableValue("isVisible")] =
      flutter::EncodableValue(valid && IsWindowVisible(target));
  result[flutter::EncodableValue("onMonitor")] =
      flutter::EncodableValue(intersects_monitor);
  result[flutter::EncodableValue("isIconic")] =
      flutter::EncodableValue(valid && IsIconic(target));
  result[flutter::EncodableValue("isCloaked")] =
      flutter::EncodableValue(cloaked_available && cloaked != 0);
  result[flutter::EncodableValue("cloakedAvailable")] =
      flutter::EncodableValue(cloaked_available);
  result[flutter::EncodableValue("style")] =
      flutter::EncodableValue(static_cast<int64_t>(style));
  result[flutter::EncodableValue("extendedStyle")] =
      flutter::EncodableValue(static_cast<int64_t>(extended_style));
  result[flutter::EncodableValue("showCmd")] =
      flutter::EncodableValue(placement_valid ? placement.showCmd : 0);
  result[flutter::EncodableValue("parentHwnd")] =
      flutter::EncodableValue(reinterpret_cast<int64_t>(parent));
  result[flutter::EncodableValue("ownerHwnd")] =
      flutter::EncodableValue(reinterpret_cast<int64_t>(owner));
  result[flutter::EncodableValue("previousSiblingHwnd")] =
      flutter::EncodableValue(reinterpret_cast<int64_t>(previous_sibling));
  result[flutter::EncodableValue("left")] =
      flutter::EncodableValue(static_cast<int64_t>(bounds.left));
  result[flutter::EncodableValue("top")] =
      flutter::EncodableValue(static_cast<int64_t>(bounds.top));
  result[flutter::EncodableValue("right")] =
      flutter::EncodableValue(static_cast<int64_t>(bounds.right));
  result[flutter::EncodableValue("bottom")] =
      flutter::EncodableValue(static_cast<int64_t>(bounds.bottom));
  result[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int64_t>(width));
  result[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int64_t>(height));
  result[flutter::EncodableValue("clientWidth")] =
      flutter::EncodableValue(static_cast<int64_t>(
          client_bounds_valid ? client_bounds.right - client_bounds.left : 0));
  result[flutter::EncodableValue("clientHeight")] =
      flutter::EncodableValue(static_cast<int64_t>(
          client_bounds_valid ? client_bounds.bottom - client_bounds.top : 0));
  result[flutter::EncodableValue("monitorLeft")] =
      flutter::EncodableValue(static_cast<int64_t>(
          monitor_info_valid ? monitor_info.rcMonitor.left : 0));
  result[flutter::EncodableValue("monitorTop")] =
      flutter::EncodableValue(static_cast<int64_t>(
          monitor_info_valid ? monitor_info.rcMonitor.top : 0));
  result[flutter::EncodableValue("monitorRight")] =
      flutter::EncodableValue(static_cast<int64_t>(
          monitor_info_valid ? monitor_info.rcMonitor.right : 0));
  result[flutter::EncodableValue("monitorBottom")] =
      flutter::EncodableValue(static_cast<int64_t>(
          monitor_info_valid ? monitor_info.rcMonitor.bottom : 0));
  LogProcessDiagnostic(
      "hwnd_ownership_verification",
      std::string("result=") + (valid ? "verified" : "failed") +
          " hwnd=" +
          std::to_string(reinterpret_cast<intptr_t>(target)) +
          " ownerPid=" + std::to_string(owner_pid) +
          " currentPid=" + std::to_string(GetCurrentProcessId()) +
          " threadId=" + std::to_string(thread_id) +
          " visible=" + (valid && IsWindowVisible(target) ? "true" : "false") +
          " iconic=" + (valid && IsIconic(target) ? "true" : "false") +
          " bounds=" + std::to_string(bounds.left) + "," +
          std::to_string(bounds.top) + "," + std::to_string(bounds.right) +
          "," + std::to_string(bounds.bottom) +
          " onMonitor=" + (intersects_monitor ? "true" : "false") +
          " style=" + std::to_string(style) +
          " exStyle=" + std::to_string(extended_style) +
          " parent=" + std::to_string(reinterpret_cast<intptr_t>(parent)) +
          " owner=" + std::to_string(reinterpret_cast<intptr_t>(owner)) +
          " previousSibling=" +
          std::to_string(reinterpret_cast<intptr_t>(previous_sibling)) +
          " showCmd=" +
          std::to_string(placement_valid ? placement.showCmd : 0) +
          " cloakedAvailable=" + (cloaked_available ? "true" : "false") +
          " cloaked=" + (cloaked_available && cloaked ? "true" : "false"));
  return result;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::VerifyDockWindow(
    DWORD pid, const std::string& instance_id, int64_t operation_id) {
  flutter::EncodableMap res;
  res[flutter::EncodableValue("found")] = flutter::EncodableValue(false);
  res[flutter::EncodableValue("hwnd")] = flutter::EncodableValue(static_cast<int64_t>(0));
  res[flutter::EncodableValue("pidMatches")] = flutter::EncodableValue(false);
  res[flutter::EncodableValue("isVisible")] = flutter::EncodableValue(false);
  res[flutter::EncodableValue("isIconic")] = flutter::EncodableValue(false);
  res[flutter::EncodableValue("isEnabled")] = flutter::EncodableValue(false);
  res[flutter::EncodableValue("onMonitor")] = flutter::EncodableValue(false);
  res[flutter::EncodableValue("ipcReady")] =
      flutter::EncodableValue(IsProcessReadinessEventSignaled(
          pid, instance_id, operation_id));

  flutter::EncodableMap empty_rect;
  empty_rect[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int64_t>(0));
  empty_rect[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int64_t>(0));
  empty_rect[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int64_t>(0));
  empty_rect[flutter::EncodableValue("bottom")] = flutter::EncodableValue(static_cast<int64_t>(0));
  empty_rect[flutter::EncodableValue("width")] = flutter::EncodableValue(static_cast<int64_t>(0));
  empty_rect[flutter::EncodableValue("height")] = flutter::EncodableValue(static_cast<int64_t>(0));
  res[flutter::EncodableValue("rect")] = flutter::EncodableValue(empty_rect);

  if (pid == 0) return res;

  struct DockSearchCtx {
    DWORD target_pid = 0;
    std::string instance_id;
    HWND best_hwnd = nullptr;
    RECT best_rect{};
    bool best_visible = false;
  } ctx;
  ctx.target_pid = pid;
  ctx.instance_id = instance_id;

  EnumWindows([](HWND hwnd, LPARAM lParam) -> BOOL {
    auto* c = reinterpret_cast<DockSearchCtx*>(lParam);
    DWORD wpid = 0;
    GetWindowThreadProcessId(hwnd, &wpid);
    if (wpid != c->target_pid) return TRUE;

    if (!IsWindow(hwnd)) return TRUE;

    RECT r{};
    GetWindowRect(hwnd, &r);
    int w = r.right - r.left;
    int h = r.bottom - r.top;
    bool vis = (IsWindowVisible(hwnd) != FALSE);

    if (!c->instance_id.empty()) {
      wchar_t title_buf[512] = {0};
      GetWindowTextW(hwnd, title_buf, 512);
      std::string title = WideToUtf8(title_buf);
      if (title.find(c->instance_id) != std::string::npos) {
        c->best_hwnd = hwnd;
        c->best_rect = r;
        c->best_visible = vis;
        return FALSE;
      }
    }

    if (vis && w > 0 && h > 0) {
      c->best_hwnd = hwnd;
      c->best_rect = r;
      c->best_visible = vis;
      return FALSE;
    }

    if (!c->best_hwnd && (w > 0 || h > 0)) {
      c->best_hwnd = hwnd;
      c->best_rect = r;
      c->best_visible = vis;
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&ctx));

  if (ctx.best_hwnd != nullptr && IsWindow(ctx.best_hwnd)) {
    HWND h = ctx.best_hwnd;
    DWORD found_pid = 0;
    GetWindowThreadProcessId(h, &found_pid);
    bool visible = (IsWindowVisible(h) != FALSE);
    bool iconic = (IsIconic(h) != FALSE);
    bool enabled = (IsWindowEnabled(h) != FALSE);
    HMONITOR mon = MonitorFromWindow(h, MONITOR_DEFAULTTONULL);

    int w = ctx.best_rect.right - ctx.best_rect.left;
    int hgt = ctx.best_rect.bottom - ctx.best_rect.top;

    res[flutter::EncodableValue("found")] = flutter::EncodableValue(true);
    res[flutter::EncodableValue("hwnd")] = flutter::EncodableValue(reinterpret_cast<int64_t>(h));
    res[flutter::EncodableValue("pidMatches")] = flutter::EncodableValue(found_pid == pid);
    res[flutter::EncodableValue("isVisible")] = flutter::EncodableValue(visible);
    res[flutter::EncodableValue("isIconic")] = flutter::EncodableValue(iconic);
    res[flutter::EncodableValue("isEnabled")] = flutter::EncodableValue(enabled);
    res[flutter::EncodableValue("onMonitor")] = flutter::EncodableValue(mon != nullptr);
    res[flutter::EncodableValue("windowThreadId")] =
        flutter::EncodableValue(static_cast<int64_t>(
            GetWindowThreadProcessId(h, nullptr)));
    res[flutter::EncodableValue("ownerPid")] =
        flutter::EncodableValue(static_cast<int64_t>(found_pid));

    flutter::EncodableMap rect_map;
    rect_map[flutter::EncodableValue("left")] = flutter::EncodableValue(static_cast<int64_t>(ctx.best_rect.left));
    rect_map[flutter::EncodableValue("top")] = flutter::EncodableValue(static_cast<int64_t>(ctx.best_rect.top));
    rect_map[flutter::EncodableValue("right")] = flutter::EncodableValue(static_cast<int64_t>(ctx.best_rect.right));
    rect_map[flutter::EncodableValue("bottom")] = flutter::EncodableValue(static_cast<int64_t>(ctx.best_rect.bottom));
    rect_map[flutter::EncodableValue("width")] = flutter::EncodableValue(static_cast<int64_t>(w));
    rect_map[flutter::EncodableValue("height")] = flutter::EncodableValue(static_cast<int64_t>(hgt));
    res[flutter::EncodableValue("rect")] = flutter::EncodableValue(rect_map);
  }

  return res;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::PositionDockForReplacement(
    DWORD pid, int64_t expected_hwnd) {
  flutter::EncodableMap result;
  result[flutter::EncodableValue("success")] = flutter::EncodableValue(false);

  if (pid == 0 || expected_hwnd == 0) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Missing dock PID or HWND.");
    return result;
  }

  const auto found = FindWindowByTitleOrPid("", pid);
  const auto hwnd_it = found.find(flutter::EncodableValue("hwnd"));
  if (found.find(flutter::EncodableValue("found")) == found.end() ||
      !std::get<bool>(found.at(flutter::EncodableValue("found"))) ||
      hwnd_it == found.end()) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("No top-level window found for the dock PID.");
    return result;
  }

  const auto* hwnd_value = std::get_if<int64_t>(&hwnd_it->second);
  if (hwnd_value == nullptr || *hwnd_value != expected_hwnd) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Dock HWND does not match the ready record.");
    return result;
  }

  HWND dock = reinterpret_cast<HWND>(*hwnd_value);
  DWORD owner_pid = 0;
  GetWindowThreadProcessId(dock, &owner_pid);
  if (!IsWindow(dock) || owner_pid != pid) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Dock HWND is invalid or owned by another PID.");
    return result;
  }

  HWND shell_taskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
  RECT target{};
  if (shell_taskbar == nullptr || !IsWindow(shell_taskbar) ||
      !GetWindowRect(shell_taskbar, &target)) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Could not read the native taskbar bounds.");
    return result;
  }

  const int width = target.right - target.left;
  const int height = target.bottom - target.top;
  if (width <= 0 || height <= 0) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Native taskbar bounds are unusable.");
    return result;
  }
  if (height > width) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue(
            "Full Replacement currently supports horizontal taskbars only.");
    return result;
  }

  if (!SetWindowPos(dock, HWND_TOP, target.left, target.top, width, height,
                    SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW |
                        SWP_FRAMECHANGED)) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("SetWindowPos failed with Win32 error " +
                                std::to_string(GetLastError()) + ".");
    return result;
  }

  RECT actual{};
  DWORD actual_owner_pid = 0;
  GetWindowThreadProcessId(dock, &actual_owner_pid);
  if (!GetWindowRect(dock, &actual) || actual_owner_pid != pid ||
      actual.left != target.left || actual.top != target.top ||
      actual.right != target.right || actual.bottom != target.bottom ||
      !IsWindowVisible(dock)) {
    result[flutter::EncodableValue("error")] =
        flutter::EncodableValue("Dock window did not match native taskbar bounds.");
    return result;
  }

  flutter::EncodableMap target_rect;
  target_rect[flutter::EncodableValue("left")] =
      flutter::EncodableValue(static_cast<int64_t>(target.left));
  target_rect[flutter::EncodableValue("top")] =
      flutter::EncodableValue(static_cast<int64_t>(target.top));
  target_rect[flutter::EncodableValue("right")] =
      flutter::EncodableValue(static_cast<int64_t>(target.right));
  target_rect[flutter::EncodableValue("bottom")] =
      flutter::EncodableValue(static_cast<int64_t>(target.bottom));
  target_rect[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int64_t>(width));
  target_rect[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int64_t>(height));

  result[flutter::EncodableValue("success")] = flutter::EncodableValue(true);
  result[flutter::EncodableValue("hwnd")] =
      flutter::EncodableValue(static_cast<int64_t>(
          reinterpret_cast<intptr_t>(dock)));
  result[flutter::EncodableValue("ownerPid")] =
      flutter::EncodableValue(static_cast<int64_t>(actual_owner_pid));
  result[flutter::EncodableValue("targetRect")] =
      flutter::EncodableValue(target_rect);
  LogProcessDiagnostic(
      "dock_replacement_position",
      "result=verified pid=" + std::to_string(pid) +
          " hwnd=" + std::to_string(reinterpret_cast<intptr_t>(dock)) +
          " bounds=" + std::to_string(target.left) + "," +
          std::to_string(target.top) + "," + std::to_string(target.right) +
          "," + std::to_string(target.bottom));
  return result;
}

bool LiveWallpaperPlugin::Impl::RunTaskbarCommand(
    const std::string& command) {
  WORD key = 0;
  if (command == "search") {
    key = 'S';
  } else if (command == "task-view") {
    key = VK_TAB;
  } else if (command == "show-desktop") {
    key = 'D';
  } else if (command == "quick-settings") {
    key = 'A';
  } else if (command == "notifications") {
    OSVERSIONINFOEXW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    version.dwBuildNumber = 22000;
    DWORDLONG version_mask = 0;
    VER_SET_CONDITION(version_mask, VER_BUILDNUMBER, VER_GREATER_EQUAL);
    const bool is_windows_11 =
        VerifyVersionInfoW(&version, VER_BUILDNUMBER, version_mask) != FALSE;
    key = is_windows_11 ? 'N' : 'A';
  } else if (command == "copilot") {
    const auto result =
        reinterpret_cast<intptr_t>(ShellExecuteW(nullptr, L"open",
                                                 L"ms-copilot:", nullptr,
                                                 nullptr, SW_SHOWNORMAL));
    if (result > 32) return true;
    return reinterpret_cast<intptr_t>(ShellExecuteW(
               nullptr, L"open", L"https://copilot.microsoft.com/", nullptr,
               nullptr, SW_SHOWNORMAL)) > 32;
  } else if (command == "file-explorer") {
    return reinterpret_cast<intptr_t>(ShellExecuteW(
               nullptr, L"open", L"explorer.exe", nullptr, nullptr,
               SW_SHOWNORMAL)) > 32;
  } else if (command == "wifi-settings") {
    return reinterpret_cast<intptr_t>(ShellExecuteW(
               nullptr, L"open", L"ms-settings:network-wifi", nullptr, nullptr,
               SW_SHOWNORMAL)) > 32;
  } else if (command == "sound-settings") {
    return reinterpret_cast<intptr_t>(ShellExecuteW(
               nullptr, L"open", L"ms-settings:sound", nullptr, nullptr,
               SW_SHOWNORMAL)) > 32;
  } else if (command == "battery-settings") {
    return reinterpret_cast<intptr_t>(ShellExecuteW(
               nullptr, L"open", L"ms-settings:powersleep", nullptr, nullptr,
               SW_SHOWNORMAL)) > 32;
  } else {
    return false;
  }

  INPUT events[4]{};
  events[0].type = INPUT_KEYBOARD;
  events[0].ki.wVk = VK_LWIN;
  events[1].type = INPUT_KEYBOARD;
  events[1].ki.wVk = key;
  events[2].type = INPUT_KEYBOARD;
  events[2].ki.wVk = key;
  events[2].ki.dwFlags = KEYEVENTF_KEYUP;
  events[3].type = INPUT_KEYBOARD;
  events[3].ki.wVk = VK_LWIN;
  events[3].ki.dwFlags = KEYEVENTF_KEYUP;
  return SendInput(4, events, sizeof(INPUT)) == 4;
}

bool LiveWallpaperPlugin::Impl::ActivateDockWindow(
    DWORD pid, const std::string& instance_id) {
  const auto verification = VerifyDockWindow(pid, instance_id);
  const auto hwnd_it = verification.find(flutter::EncodableValue("hwnd"));
  if (hwnd_it == verification.end()) return false;
  const auto* hwnd_value = std::get_if<int64_t>(&hwnd_it->second);
  if (hwnd_value == nullptr) return false;

  HWND hwnd = reinterpret_cast<HWND>(*hwnd_value);
  if (!IsWindow(hwnd)) return false;

  ShowWindow(hwnd, SW_RESTORE);
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  return IsWindowVisible(hwnd) != FALSE && IsWindowEnabled(hwnd) != FALSE;
}

flutter::EncodableList LiveWallpaperPlugin::Impl::GetDesktopWindows() {
  flutter::EncodableList windows;
  struct WindowSearchContext {
    DWORD own_pid;
    HWND foreground;
    flutter::EncodableList* windows;
  } context{GetCurrentProcessId(), GetForegroundWindow(), &windows};

  EnumWindows(
      [](HWND hwnd, LPARAM parameter) -> BOOL {
        auto* ctx = reinterpret_cast<WindowSearchContext*>(parameter);
        if (!IsWindowVisible(hwnd) || GetAncestor(hwnd, GA_ROOT) != hwnd) {
          return TRUE;
        }

        const LONG_PTR extended_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if ((extended_style & WS_EX_TOOLWINDOW) != 0 ||
            (GetWindow(hwnd, GW_OWNER) != nullptr &&
             (extended_style & WS_EX_APPWINDOW) == 0)) {
          return TRUE;
        }

        DWORD process_id = 0;
        GetWindowThreadProcessId(hwnd, &process_id);
        if (process_id == 0 || process_id == ctx->own_pid) return TRUE;

        DWORD cloaked = 0;
        if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                            sizeof(cloaked))) &&
            cloaked != 0) {
          return TRUE;
        }

        const int title_length = GetWindowTextLengthW(hwnd);
        if (title_length <= 0) return TRUE;
        std::wstring title(static_cast<size_t>(title_length) + 1, L'\0');
        const int copied =
            GetWindowTextW(hwnd, title.data(), title_length + 1);
        if (copied <= 0) return TRUE;
        title.resize(static_cast<size_t>(copied));

        RECT bounds{};
        if (!GetWindowRect(hwnd, &bounds) ||
            bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
          return TRUE;
        }

        std::wstring executable;
        HANDLE process =
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
        if (process) {
          std::vector<wchar_t> path(32768, L'\0');
          DWORD path_length = static_cast<DWORD>(path.size());
          if (QueryFullProcessImageNameW(process, 0, path.data(),
                                         &path_length)) {
            executable.assign(path.data(), path_length);
          }
          CloseHandle(process);
        }

        flutter::EncodableMap item;
        item[flutter::EncodableValue("hwnd")] =
            flutter::EncodableValue(reinterpret_cast<int64_t>(hwnd));
        item[flutter::EncodableValue("pid")] =
            flutter::EncodableValue(static_cast<int64_t>(process_id));
        item[flutter::EncodableValue("title")] =
            flutter::EncodableValue(WideToUtf8(title));
        item[flutter::EncodableValue("executable")] =
            flutter::EncodableValue(WideToUtf8(executable));
        item[flutter::EncodableValue("isForeground")] =
            flutter::EncodableValue(hwnd == ctx->foreground);
        item[flutter::EncodableValue("iconPng")] =
            flutter::EncodableValue(GetExecutableIconPng(executable));
        ctx->windows->emplace_back(std::move(item));
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&context));

  return windows;
}

bool LiveWallpaperPlugin::Impl::ActivateDesktopWindow(int64_t hwnd_value) {
  HWND hwnd = reinterpret_cast<HWND>(hwnd_value);
  if (hwnd_value == 0 || !IsWindow(hwnd) ||
      GetAncestor(hwnd, GA_ROOT) != hwnd || !IsWindowEnabled(hwnd)) {
    return false;
  }

  DWORD process_id = 0;
  GetWindowThreadProcessId(hwnd, &process_id);
  if (process_id == 0 || process_id == GetCurrentProcessId()) return false;

  if (GetForegroundWindow() == hwnd) {
    ShowWindow(hwnd, SW_MINIMIZE);
    return true;
  }

  ShowWindow(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
  return GetForegroundWindow() == hwnd;
}

bool LiveWallpaperPlugin::Impl::LaunchDockItem(const std::string& target) {
  const std::wstring wide_target = Utf8ToWide(target);
  if (wide_target.empty()) return false;
  const auto result =
      reinterpret_cast<INT_PTR>(ShellExecuteW(window_, L"open",
                                              wide_target.c_str(), nullptr,
                                              nullptr, SW_SHOWNORMAL));
  return result > 32;
}

bool LiveWallpaperPlugin::Impl::RestoreWindowsTaskbar() {
  SetWindowsTaskbarVisibility(true);

  HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr);
  if (tray) {
    ShowWindow(tray, SW_SHOW);
    SetWindowPos(tray, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetWindowPos(tray, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  HWND sec_tray = nullptr;
  while ((sec_tray = FindWindowExW(nullptr, sec_tray, L"Shell_SecondaryTrayWnd", nullptr)) != nullptr) {
    ShowWindow(sec_tray, SW_SHOW);
    SetWindowPos(sec_tray, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetWindowPos(sec_tray, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  SystemParametersInfoW(SPI_SETWORKAREA, 0, nullptr, SPIF_SENDCHANGE);
  RedrawWindow(nullptr, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_UPDATENOW);
  return true;
}

bool LiveWallpaperPlugin::Impl::IsOtherAudioPlaying() {
  bool other_playing = false;
  try {
    winrt::com_ptr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(enumerator.put()));
    if (SUCCEEDED(hr) && enumerator) {
      winrt::com_ptr<IMMDevice> device;
      hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device.put());
      if (SUCCEEDED(hr) && device) {
        winrt::com_ptr<IAudioSessionManager2> session_mgr;
        hr = device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, session_mgr.put_void());
        if (SUCCEEDED(hr) && session_mgr) {
          winrt::com_ptr<IAudioSessionEnumerator> session_enum;
          hr = session_mgr->GetSessionEnumerator(session_enum.put());
          if (SUCCEEDED(hr) && session_enum) {
            int count = 0;
            session_enum->GetCount(&count);
            DWORD our_pid = GetCurrentProcessId();
            for (int i = 0; i < count; ++i) {
              winrt::com_ptr<IAudioSessionControl> control;
              if (SUCCEEDED(session_enum->GetSession(i, control.put())) && control) {
                winrt::com_ptr<IAudioSessionControl2> control2;
                if (SUCCEEDED(control->QueryInterface(__uuidof(IAudioSessionControl2), control2.put_void())) && control2) {
                  DWORD session_pid = 0;
                  control2->GetProcessId(&session_pid);
                  AudioSessionState state;
                  control2->GetState(&state);
                  if (state == AudioSessionStateActive && session_pid != 0 &&
                      session_pid != our_pid && session_pid != mpv_pid_) {
                    other_playing = true;
                    break;
                  }
                }
              }
            }
          }
        }
      }
    }
  } catch (...) {
  }
  return other_playing;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::GetWindowsAccentColor() {
  flutter::EncodableMap result;
  DWORD color = 0;
  BOOL opaque = FALSE;
  HRESULT hr = DwmGetColorizationColor(&color, &opaque);
  if (SUCCEEDED(hr)) {
    // If alpha is 0, ensure full opacity so Flutter renders a non-transparent color
    if ((color & 0xFF000000) == 0 || opaque != FALSE) {
      color |= 0xFF000000;
    }
    result[flutter::EncodableValue("color")] = flutter::EncodableValue(static_cast<int64_t>(color));
    result[flutter::EncodableValue("opaque")] = flutter::EncodableValue(opaque != FALSE);
  } else {
    result[flutter::EncodableValue("color")] = flutter::EncodableValue(static_cast<int64_t>(0xFF0078D7));
    result[flutter::EncodableValue("opaque")] = flutter::EncodableValue(true);
  }
  return result;
}

bool LiveWallpaperPlugin::Impl::IsProcessRunning(const std::string& process_name) {
  if (process_name.empty()) return false;
  std::wstring target_name = Utf8ToWide(process_name);
  std::transform(target_name.begin(), target_name.end(), target_name.begin(), ::towlower);

  std::wstring target_with_exe = target_name;
  if (target_with_exe.size() < 4 || target_with_exe.substr(target_with_exe.size() - 4) != L".exe") {
    target_with_exe += L".exe";
  }

  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return false;

  PROCESSENTRY32W pe{};
  pe.dwSize = sizeof(pe);
  bool found = false;

  if (Process32FirstW(snapshot, &pe)) {
    do {
      std::wstring exe_name(pe.szExeFile);
      std::transform(exe_name.begin(), exe_name.end(), exe_name.begin(), ::towlower);
      if (exe_name == target_name || exe_name == target_with_exe) {
        found = true;
        break;
      }
    } while (Process32NextW(snapshot, &pe));
  }

  CloseHandle(snapshot);
  return found;
}

std::string LiveWallpaperPlugin::Impl::PickImageFile(const std::string& title) {
  std::string selected_path = "";
  HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  bool need_uninit = SUCCEEDED(hr);

  {
    winrt::com_ptr<IFileOpenDialog> file_dialog;
    if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(file_dialog.put())))) {
      COMDLG_FILTERSPEC filters[] = {
        { L"Image Files (*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp)", L"*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp" },
        { L"PNG Images (*.png)", L"*.png" },
        { L"JPEG Images (*.jpg;*.jpeg)", L"*.jpg;*.jpeg" },
        { L"All Files (*.*)", L"*.*" }
      };
      file_dialog->SetFileTypes(ARRAYSIZE(filters), filters);
      file_dialog->SetFileTypeIndex(1);
      std::wstring wide_title = Utf8ToWide(title);
      file_dialog->SetTitle(wide_title.empty() ? L"Select Image" : wide_title.c_str());

      DWORD flags = 0;
      if (SUCCEEDED(file_dialog->GetOptions(&flags))) {
        file_dialog->SetOptions(flags | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST);
      }

      HWND parent_hwnd = (window_ && IsWindow(window_) && IsWindowVisible(window_))
                             ? (root_window_ ? root_window_ : window_)
                             : nullptr;
      if (SUCCEEDED(file_dialog->Show(parent_hwnd))) {
        winrt::com_ptr<IShellItem> item;
        if (SUCCEEDED(file_dialog->GetResult(item.put()))) {
          PWSTR pszFilePath = nullptr;
          if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &pszFilePath))) {
            selected_path = WideToUtf8(pszFilePath);
            CoTaskMemFree(pszFilePath);
          }
        }
      }
    }
  } // COM smart pointers are destroyed before CoUninitialize

  if (need_uninit) {
    CoUninitialize();
  }
  return selected_path;
}

bool LiveWallpaperPlugin::Impl::BoostProcessPriority(bool boost) {
  HANDLE current_proc = GetCurrentProcess();
  BOOL res = SetPriorityClass(current_proc, boost ? ABOVE_NORMAL_PRIORITY_CLASS : NORMAL_PRIORITY_CLASS);
  return res != 0;
}

bool LiveWallpaperPlugin::Impl::SetWindowCloaked(bool cloak) {
  HWND target = root_window_ ? root_window_ : window_;
  if (!target || !IsWindow(target)) return false;

  // DWMWA_EXCLUDED_FROM_PEEK stops DWM thumbnail/peek compositing when hidden
  BOOL exclude_peek = cloak ? TRUE : FALSE;
  DwmSetWindowAttribute(target, DWMWA_EXCLUDED_FROM_PEEK, &exclude_peek, sizeof(exclude_peek));

  if (cloak) {
    ShowWindow(target, SW_HIDE);
  } else {
    ShowWindow(target, SW_SHOW);
  }
  return true;
}

bool LiveWallpaperPlugin::Impl::CreateFileHardLink(
    const std::wstring& target_path, const std::wstring& existing_path) {
  if (GetFileAttributesW(target_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
    DeleteFileW(target_path.c_str());
  }
  return CreateHardLinkW(target_path.c_str(), existing_path.c_str(), nullptr) !=
         0;
}

flutter::EncodableMap LiveWallpaperPlugin::Impl::GetWindowsVersionInfo() {
  flutter::EncodableMap info;

  SYSTEM_INFO sys_info{};
  GetSystemInfo(&sys_info);
  info[flutter::EncodableValue("processorCount")] =
      flutter::EncodableValue(static_cast<int>(sys_info.dwNumberOfProcessors));

  std::string product_name = "Windows 11";
  std::string display_version = "";
  int build_number = 22631;
  int ubr = 0;

  HKEY hKey = nullptr;
  if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                    L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
                    0, KEY_READ | KEY_WOW64_64KEY, &hKey) == ERROR_SUCCESS) {
    wchar_t buf[256] = {0};
    DWORD buf_size = sizeof(buf);
    if (RegQueryValueExW(hKey, L"ProductName", nullptr, nullptr,
                         reinterpret_cast<LPBYTE>(buf), &buf_size) == ERROR_SUCCESS) {
      product_name = WideToUtf8(buf);
    }
    buf_size = sizeof(buf);
    if (RegQueryValueExW(hKey, L"DisplayVersion", nullptr, nullptr,
                         reinterpret_cast<LPBYTE>(buf), &buf_size) == ERROR_SUCCESS) {
      display_version = WideToUtf8(buf);
    }
    buf_size = sizeof(buf);
    if (RegQueryValueExW(hKey, L"CurrentBuildNumber", nullptr, nullptr,
                         reinterpret_cast<LPBYTE>(buf), &buf_size) == ERROR_SUCCESS) {
      build_number = _wtoi(buf);
    }
    DWORD ubr_val = 0;
    DWORD ubr_size = sizeof(ubr_val);
    if (RegQueryValueExW(hKey, L"UBR", nullptr, nullptr,
                         reinterpret_cast<LPBYTE>(&ubr_val), &ubr_size) == ERROR_SUCCESS) {
      ubr = static_cast<int>(ubr_val);
    }
    RegCloseKey(hKey);
  }

  bool is_win11 = (build_number >= 22000);
  if (is_win11 && product_name.find("Windows 10") != std::string::npos) {
    size_t pos = product_name.find("Windows 10");
    product_name.replace(pos, 10, "Windows 11");
  }

  info[flutter::EncodableValue("productName")] = flutter::EncodableValue(product_name);
  info[flutter::EncodableValue("displayVersion")] = flutter::EncodableValue(display_version);
  info[flutter::EncodableValue("build")] = flutter::EncodableValue(build_number);
  info[flutter::EncodableValue("ubr")] = flutter::EncodableValue(ubr);
  info[flutter::EncodableValue("isWindows11")] = flutter::EncodableValue(is_win11);
  info[flutter::EncodableValue("supportsEcoQoS")] = flutter::EncodableValue(is_win11);

  return info;
}

flutter::EncodableList LiveWallpaperPlugin::Impl::GetProcessList() {
  flutter::EncodableList list;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return list;
  }

  wchar_t current_exe_name[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, current_exe_name, MAX_PATH);
  std::wstring our_exe = std::filesystem::path(current_exe_name).filename().wstring();

  DWORD current_pid = GetCurrentProcessId();
  PROCESSENTRY32W pe32{};
  pe32.dwSize = sizeof(PROCESSENTRY32W);

  if (Process32FirstW(snapshot, &pe32)) {
    do {
      if (pe32.th32ProcessID == 0) continue;

      flutter::EncodableMap item;
      std::string name = WideToUtf8(pe32.szExeFile);
      item[flutter::EncodableValue("pid")] =
          flutter::EncodableValue(static_cast<int>(pe32.th32ProcessID));
      item[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
      item[flutter::EncodableValue("threads")] =
          flutter::EncodableValue(static_cast<int>(pe32.cntThreads));

      bool is_self = (pe32.th32ProcessID == current_pid);
      bool is_wallsync = is_self ||
                         (_wcsicmp(pe32.szExeFile, our_exe.c_str()) == 0) ||
                         (_wcsicmp(pe32.szExeFile, L"WallSync.exe") == 0) ||
                         (_wcsicmp(pe32.szExeFile, L"mpv.exe") == 0);
      item[flutter::EncodableValue("isWallSync")] =
          flutter::EncodableValue(is_wallsync);
      item[flutter::EncodableValue("isCurrentProcess")] =
          flutter::EncodableValue(is_self);

      double working_set_mb = 0.0;
      double private_mb = 0.0;
      // PROCESS_QUERY_LIMITED_INFORMATION is sufficient for GetProcessMemoryInfo on
      // Windows 7 SP1+ and Windows 10/11, allowing access to Store apps and sandboxed processes.
      HANDLE h_proc = OpenProcess(
          PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
          pe32.th32ProcessID);
      if (!h_proc) {
        h_proc = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pe32.th32ProcessID);
      }
      if (h_proc) {
        PROCESS_MEMORY_COUNTERS_EX pmc{};
        if (GetProcessMemoryInfo(h_proc,
                                 reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&pmc),
                                 sizeof(pmc))) {
          working_set_mb =
              static_cast<double>(pmc.WorkingSetSize) / (1024.0 * 1024.0);
          private_mb =
              static_cast<double>(pmc.PrivateUsage) / (1024.0 * 1024.0);
        }
        CloseHandle(h_proc);
      }
      item[flutter::EncodableValue("workingSetMb")] =
          flutter::EncodableValue(working_set_mb);
      item[flutter::EncodableValue("privateMb")] =
          flutter::EncodableValue(private_mb);

      list.push_back(flutter::EncodableValue(item));
    } while (Process32NextW(snapshot, &pe32));
  }
  CloseHandle(snapshot);
  return list;
}

bool LiveWallpaperPlugin::Impl::SetProcessPriority(DWORD pid, int priority_level) {
  if (pid == 0) return false;
  HANDLE h_proc = (pid == GetCurrentProcessId())
                      ? GetCurrentProcess()
                      : OpenProcess(PROCESS_SET_INFORMATION, FALSE, pid);
  if (!h_proc) return false;

  DWORD priority_class = NORMAL_PRIORITY_CLASS;
  if (priority_level == 0) {
    priority_class = BELOW_NORMAL_PRIORITY_CLASS;
  } else if (priority_level == 2) {
    priority_class = ABOVE_NORMAL_PRIORITY_CLASS;
  } else if (priority_level == 3) {
    priority_class = HIGH_PRIORITY_CLASS;
  }

  BOOL success = SetPriorityClass(h_proc, priority_class);
  if (pid != GetCurrentProcessId()) {
    CloseHandle(h_proc);
  }
  return success != 0;
}

bool LiveWallpaperPlugin::Impl::TrimProcessMemory(DWORD pid) {
  if (pid == 0) return false;
  if (pid == GetCurrentProcessId()) {
    // IMPORTANT: Never call EmptyWorkingSet or SetProcessWorkingSetSize(-1, -1) on the
    // active Flutter UI/rendering process. Paging out D3D/DXGI swapchain surfaces and
    // compiled GPU shaders causes massive raster presentation freezes (up to 8.9s).
    // Use non-destructive HeapCompact for the host process.
    HeapCompact(GetProcessHeap(), 0);
    return true;
  }

  HANDLE h_proc = OpenProcess(PROCESS_SET_QUOTA | PROCESS_QUERY_INFORMATION, FALSE, pid);
  if (!h_proc) return false;

  EmptyWorkingSet(h_proc);
  SetProcessWorkingSetSize(h_proc, static_cast<SIZE_T>(-1), static_cast<SIZE_T>(-1));
  CloseHandle(h_proc);
  return true;
}

void LiveWallpaperPlugin::Impl::StartLowMemoryMonitor() {
  if (low_mem_running_) return;
  if (!low_mem_stop_event_) {
    low_mem_stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  } else {
    ResetEvent(low_mem_stop_event_);
  }
  low_mem_event_ = CreateMemoryResourceNotification(LowMemoryResourceNotification);
  if (!low_mem_event_) return;
  low_mem_running_ = true;
  low_mem_thread_ = std::thread([this]() {
    HANDLE handles[2] = {low_mem_stop_event_, low_mem_event_};
    while (low_mem_running_) {
      DWORD wait_res = WaitForMultipleObjects(2, handles, FALSE, 2000);
      if (!low_mem_running_ || wait_res == WAIT_OBJECT_0) break;
      if (wait_res == WAIT_OBJECT_0 + 1) {
        OptimizeMemory();
        // Cooldown: wait for stop_event or up to 5000ms
        WaitForSingleObject(low_mem_stop_event_, 5000);
      }
    }
  });
}

void LiveWallpaperPlugin::Impl::StopLowMemoryMonitor() {
  if (low_mem_running_) {
    low_mem_running_ = false;
    if (low_mem_stop_event_) {
      SetEvent(low_mem_stop_event_);
    }
    if (low_mem_thread_.joinable()) {
      low_mem_thread_.join();
    }
  }
  if (low_mem_event_) {
    CloseHandle(low_mem_event_);
    low_mem_event_ = nullptr;
  }
  if (low_mem_stop_event_) {
    CloseHandle(low_mem_stop_event_);
    low_mem_stop_event_ = nullptr;
  }
}

LiveWallpaperPlugin::LiveWallpaperPlugin(
    flutter::PluginRegistrarWindows* registrar,
    std::function<void()> force_redraw)
    : impl_(std::make_unique<Impl>(registrar, std::move(force_redraw))) {}

LiveWallpaperPlugin::~LiveWallpaperPlugin() = default;
