#include "taskbar_appbar.h"

#include <shellapi.h>

#include <algorithm>

#include "process_diagnostics.h"

namespace {

constexpr UINT kTaskbarAppBarCallbackMessage = WM_APP + 0x3A;
constexpr int kMinimumThickness = 24;
constexpr int kMaximumThickness = 256;
constexpr int kMinimumLength = 120;

bool ParseEdge(const std::string& value, UINT* edge) {
  if (value == "top") {
    *edge = ABE_TOP;
  } else if (value == "bottom") {
    *edge = ABE_BOTTOM;
  } else if (value == "left") {
    *edge = ABE_LEFT;
  } else if (value == "right") {
    *edge = ABE_RIGHT;
  } else {
    return false;
  }
  return true;
}

const char* EdgeName(UINT edge) {
  switch (edge) {
    case ABE_TOP:
      return "top";
    case ABE_BOTTOM:
      return "bottom";
    case ABE_LEFT:
      return "left";
    case ABE_RIGHT:
      return "right";
    default:
      return "unknown";
  }
}

}  // namespace

TaskbarAppBar::TaskbarAppBar(HWND window)
    : window_(window), callback_message_(kTaskbarAppBarCallbackMessage) {}

TaskbarAppBar::~TaskbarAppBar() {
  Remove();
}

bool TaskbarAppBar::Apply(const Configuration& configuration,
                          std::string* error) {
  UINT requested_edge = ABE_BOTTOM;
  if (!window_ || !IsWindow(window_)) {
    *error = "The taskbar host HWND is not valid.";
    return false;
  }
  if (!ParseEdge(configuration.edge, &requested_edge)) {
    *error = "The taskbar edge must be top, bottom, left, or right.";
    return false;
  }
  if (configuration.thickness < kMinimumThickness ||
      configuration.thickness > kMaximumThickness) {
    *error = "Taskbar thickness is outside the supported range.";
    return false;
  }
  if (configuration.length != 0 &&
      configuration.length < kMinimumLength) {
    *error = "Taskbar length must be zero or at least 120 pixels.";
    return false;
  }
  if (configuration.revision < 1 ||
      configuration.revision < applied_revision_) {
    *error = "Taskbar configuration revision is invalid or stale.";
    return false;
  }

  if (auto_hide_ &&
      (requested_edge != edge_ || !configuration.auto_hide)) {
    APPBARDATA data{};
    data.cbSize = sizeof(data);
    data.hWnd = window_;
    data.uEdge = edge_;
    data.lParam = FALSE;
    if (SHAppBarMessage(ABM_SETAUTOHIDEBAR, &data) == 0) {
      *error = "Windows could not release the previous AppBar auto-hide edge.";
      return false;
    }
    auto_hide_ = false;
  }
  edge_ = requested_edge;
  thickness_ = configuration.thickness;
  length_ = configuration.length;
  if (!registered_ && !Register(error)) {
    return false;
  }
  if (configuration.auto_hide != auto_hide_) {
    APPBARDATA data{};
    data.cbSize = sizeof(data);
    data.hWnd = window_;
    data.uEdge = edge_;
    data.lParam = configuration.auto_hide ? TRUE : FALSE;
    if (SHAppBarMessage(ABM_SETAUTOHIDEBAR, &data) == 0) {
      *error = "Windows rejected the requested AppBar auto-hide state.";
      return false;
    }
    auto_hide_ = configuration.auto_hide;
  }
  if (!SetPosition(error)) {
    return false;
  }

  last_configuration_ = configuration;
  has_configuration_ = true;
  visible_ = true;
  applied_revision_ = configuration.revision;
  LogProcessDiagnostic(
      "taskbar_appbar_configuration",
      "result=applied revision=" + std::to_string(applied_revision_) +
          " edge=" + EdgeName(edge_) + " thickness=" +
          std::to_string(thickness_) + " length=" +
          std::to_string(length_) + " bounds=" +
          std::to_string(bounds_.left) + "," +
          std::to_string(bounds_.top) + "," +
          std::to_string(bounds_.right) + "," +
          std::to_string(bounds_.bottom));
  return true;
}

bool TaskbarAppBar::SetVisible(bool visible, std::string* error) {
  if (visible == visible_) {
    return true;
  }
  if (!visible) {
    Remove();
    ShowWindow(window_, SW_HIDE);
    visible_ = false;
    return true;
  }
  if (!has_configuration_) {
    *error = "The AppBar has no configuration to restore.";
    return false;
  }
  if (!Apply(last_configuration_, error)) {
    return false;
  }
  return true;
}

std::optional<LRESULT> TaskbarAppBar::HandleWindowMessage(UINT message,
                                                          WPARAM wparam) {
  if (message == callback_message_) {
    if (wparam == ABN_POSCHANGED) {
      std::string error;
      if (!SetPosition(&error)) {
        LogProcessDiagnostic("taskbar_appbar_reposition",
                             "result=failed error=" + error);
      }
    }
    return 0;
  }
  if (message == WM_DISPLAYCHANGE || message == WM_SETTINGCHANGE ||
      message == WM_DPICHANGED) {
    std::string error;
    if (!SetPosition(&error)) {
      LogProcessDiagnostic("taskbar_appbar_reposition",
                           "result=failed error=" + error);
    }
    return 0;
  }
  return std::nullopt;
}

int TaskbarAppBar::applied_revision() const {
  return applied_revision_;
}

RECT TaskbarAppBar::bounds() const {
  return bounds_;
}

bool TaskbarAppBar::Register(std::string* error) {
  APPBARDATA data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uCallbackMessage = callback_message_;
  if (SHAppBarMessage(ABM_NEW, &data) == 0) {
    *error = "Windows rejected AppBar registration.";
    LogProcessDiagnostic("taskbar_appbar_registration",
                         "result=failed error=ABM_NEW");
    return false;
  }
  registered_ = true;
  LogProcessDiagnostic(
      "taskbar_appbar_registration",
      "result=success hwnd=" +
          std::to_string(reinterpret_cast<intptr_t>(window_)));
  return true;
}

bool TaskbarAppBar::SetPosition(std::string* error) {
  if (!registered_ || !window_ || !IsWindow(window_)) {
    *error = "The AppBar is not registered or its HWND is invalid.";
    return false;
  }

  HMONITOR monitor = MonitorFromWindow(window_, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfoW(monitor, &monitor_info)) {
    *error = "Windows could not query the target monitor.";
    return false;
  }

  const RECT monitor_bounds = monitor_info.rcMonitor;
  const int monitor_width = monitor_bounds.right - monitor_bounds.left;
  const int monitor_height = monitor_bounds.bottom - monitor_bounds.top;
  if (monitor_width <= 0 || monitor_height <= 0) {
    *error = "The target monitor has invalid bounds.";
    return false;
  }
  UINT dpi = GetDpiForWindow(window_);
  if (dpi == 0) {
    dpi = 96;
  }
  const int thickness = MulDiv(thickness_, dpi, 96);
  const int requested_length = MulDiv(length_, dpi, 96);

  APPBARDATA data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uCallbackMessage = callback_message_;
  data.uEdge = edge_;

  if (edge_ == ABE_TOP || edge_ == ABE_BOTTOM) {
    const int width =
        requested_length == 0 ? monitor_width
                              : std::min(requested_length, monitor_width);
    data.rc.left = monitor_bounds.left + (monitor_width - width) / 2;
    data.rc.right = data.rc.left + width;
    if (edge_ == ABE_TOP) {
      data.rc.top = monitor_bounds.top;
      data.rc.bottom = data.rc.top + thickness;
    } else {
      data.rc.bottom = monitor_bounds.bottom;
      data.rc.top = data.rc.bottom - thickness;
    }
  } else {
    data.rc.top = monitor_bounds.top;
    data.rc.bottom = monitor_bounds.bottom;
    if (edge_ == ABE_LEFT) {
      data.rc.left = monitor_bounds.left;
      data.rc.right = data.rc.left + thickness;
    } else {
      data.rc.right = monitor_bounds.right;
      data.rc.left = data.rc.right - thickness;
    }
  }

  SHAppBarMessage(ABM_QUERYPOS, &data);
  if (edge_ == ABE_TOP) {
    data.rc.bottom = data.rc.top + thickness;
  } else if (edge_ == ABE_BOTTOM) {
    data.rc.top = data.rc.bottom - thickness;
  } else if (edge_ == ABE_LEFT) {
    data.rc.right = data.rc.left + thickness;
  } else {
    data.rc.left = data.rc.right - thickness;
  }

  if (SHAppBarMessage(ABM_SETPOS, &data) == 0) {
    *error = "Windows could not reserve the AppBar position.";
    return false;
  }
  if (!SetWindowPos(window_, HWND_TOPMOST, data.rc.left, data.rc.top,
                    data.rc.right - data.rc.left,
                    data.rc.bottom - data.rc.top,
                    SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW)) {
    *error = "Windows could not position the AppBar HWND.";
    return false;
  }

  bounds_ = data.rc;
  return true;
}

void TaskbarAppBar::Remove() {
  if (registered_ && window_ && IsWindow(window_)) {
    APPBARDATA data{};
    data.cbSize = sizeof(data);
    data.hWnd = window_;
    if (auto_hide_) {
      data.uEdge = edge_;
      data.lParam = FALSE;
      SHAppBarMessage(ABM_SETAUTOHIDEBAR, &data);
      auto_hide_ = false;
    }
    SHAppBarMessage(ABM_REMOVE, &data);
    LogProcessDiagnostic("taskbar_appbar_registration",
                         "result=removed hwnd=" +
                             std::to_string(
                                 reinterpret_cast<intptr_t>(window_)));
  }
  registered_ = false;
}
