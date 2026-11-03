#ifndef RUNNER_TASKBAR_APPBAR_H_
#define RUNNER_TASKBAR_APPBAR_H_

#include <windows.h>

#include <optional>
#include <string>

class TaskbarAppBar {
 public:
  struct Configuration {
    std::string edge;
    int thickness;
    int length;
    bool auto_hide;
    int revision;
  };

  explicit TaskbarAppBar(HWND window);
  ~TaskbarAppBar();

  TaskbarAppBar(const TaskbarAppBar&) = delete;
  TaskbarAppBar& operator=(const TaskbarAppBar&) = delete;

  bool Apply(const Configuration& configuration, std::string* error);
  bool SetVisible(bool visible, std::string* error);
  std::optional<LRESULT> HandleWindowMessage(UINT message, WPARAM wparam);
  int applied_revision() const;
  RECT bounds() const;

 private:
  bool Register(std::string* error);
  bool SetPosition(std::string* error);
  void Remove();

  HWND window_ = nullptr;
  UINT callback_message_ = 0;
  UINT edge_ = ABE_BOTTOM;
  int thickness_ = 48;
  int length_ = 640;
  int applied_revision_ = 0;
  Configuration last_configuration_{};
  bool auto_hide_ = false;
  bool registered_ = false;
  bool has_configuration_ = false;
  bool visible_ = true;
  RECT bounds_{};
};

#endif  // RUNNER_TASKBAR_APPBAR_H_
