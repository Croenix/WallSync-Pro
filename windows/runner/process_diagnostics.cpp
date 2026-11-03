#include "process_diagnostics.h"

#include <shlobj.h>

#include <algorithm>
#include <cstdio>
#include <mutex>
#include <sstream>

namespace {

std::mutex g_log_mutex;
std::wstring g_log_path;
std::wstring g_process_mode = L"main";
std::string g_process_mode_name = "main";
std::string g_instance_id;
int64_t g_operation_id = -1;
int64_t g_configuration_revision = 1;
HANDLE g_readiness_event = nullptr;

std::string WideToUtf8(const wchar_t* value) {
  if (value == nullptr || *value == L'\0') return "";
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) return "";
  std::string result(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result.data(),
                      length, nullptr, nullptr);
  result.pop_back();
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return L"";
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1, nullptr, 0);
  if (length <= 1) return L"";
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                      result.data(), length);
  result.pop_back();
  return result;
}

std::wstring Sanitize(const std::wstring& value) {
  std::wstring result;
  for (const wchar_t character : value) {
    result.push_back((character >= L'a' && character <= L'z') ||
                             (character >= L'A' && character <= L'Z') ||
                             (character >= L'0' && character <= L'9') ||
                             character == L'_' || character == L'-'
                         ? character
                         : L'_');
  }
  return result.empty() ? L"none" : result;
}

std::wstring ReadinessEventName(DWORD pid, const std::string& instance_id,
                                int64_t operation_id) {
  std::wstringstream name;
  name << L"Local\\WallSyncPro.Ready." << pid << L"."
       << Sanitize(Utf8ToWide(instance_id)) << L"." << operation_id;
  return name.str();
}

std::string EscapeLine(const std::string& value) {
  std::string escaped;
  escaped.reserve(value.size());
  for (const char character : value) {
    if (character == '\r' || character == '\n') {
      escaped.push_back(' ');
    } else {
      escaped.push_back(character);
    }
  }
  return escaped;
}

std::string CurrentTimestamp() {
  SYSTEMTIME time{};
  GetSystemTime(&time);
  char value[40]{};
  std::snprintf(value, sizeof(value), "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
                time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
                time.wSecond, time.wMilliseconds);
  return value;
}

std::string WindowsError(DWORD error) {
  wchar_t* message = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, 0, reinterpret_cast<wchar_t*>(&message), 0, nullptr);
  std::string result =
      length == 0 ? "Windows error " + std::to_string(error)
                  : WideToUtf8(message);
  if (message != nullptr) LocalFree(message);
  return EscapeLine(result);
}

bool Contains(const std::vector<std::string>& arguments,
              const std::string& argument) {
  return std::find(arguments.begin(), arguments.end(), argument) !=
         arguments.end();
}

std::string ValueFor(const std::vector<std::string>& arguments,
                     const std::string& prefix) {
  for (const auto& argument : arguments) {
    if (argument.rfind(prefix, 0) == 0) {
      return argument.substr(prefix.length());
    }
  }
  return "";
}

std::string JoinArguments(const std::vector<std::string>& arguments) {
  std::ostringstream result;
  for (size_t index = 0; index < arguments.size(); ++index) {
    if (index != 0) result << " ";
    result << "\"" << EscapeLine(arguments[index]) << "\"";
  }
  return result.str();
}

}  // namespace

bool InitializeProcessDiagnostics(
    const std::vector<std::string>& command_line_arguments) {
  const bool overlay = Contains(command_line_arguments, "--overlay");
  const bool wallpaper = Contains(command_line_arguments, "--wallpaper");
  const std::string overlay_type =
      ValueFor(command_line_arguments, "--overlay-type=");
  g_instance_id = ValueFor(command_line_arguments, "--instance-id=");
  const std::string operation_id =
      ValueFor(command_line_arguments, "--operation-id=");
  const std::string configuration_revision =
      ValueFor(command_line_arguments, "--config-revision=");

  if (wallpaper && !overlay) {
    g_process_mode_name = "wallpaper";
  } else if (overlay && (overlay_type.empty() || overlay_type == "classic")) {
    g_process_mode_name = "classic";
  } else if (overlay && overlay_type == "taskbar_dock") {
    g_process_mode_name = "taskbar_dock";
  } else if (!overlay && !wallpaper && overlay_type.empty()) {
    g_process_mode_name = "main";
  } else {
    g_process_mode_name = "invalid";
  }
  g_process_mode = Utf8ToWide(g_process_mode_name);
  if (!operation_id.empty()) {
    try {
      g_operation_id = std::stoll(operation_id);
    } catch (...) {
      g_operation_id = -1;
    }
  }
  if (!configuration_revision.empty()) {
    try {
      g_configuration_revision = std::stoll(configuration_revision);
    } catch (...) {
      g_configuration_revision = -1;
    }
  }

  PWSTR app_data = nullptr;
  const HRESULT known_folder_result =
      SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT, nullptr,
                           &app_data);
  if (FAILED(known_folder_result) || app_data == nullptr) {
    OutputDebugStringW(L"WallSync: Could not resolve the roaming AppData path.\n");
    return false;
  }
  const std::wstring directory =
      std::wstring(app_data) + L"\\com.example\\wallsync\\diagnostics";
  CoTaskMemFree(app_data);

  const int directory_result = SHCreateDirectoryExW(nullptr, directory.c_str(),
                                                     nullptr);
  if (directory_result != ERROR_SUCCESS &&
      directory_result != ERROR_ALREADY_EXISTS &&
      directory_result != ERROR_FILE_EXISTS) {
    OutputDebugStringW(L"WallSync: Could not create the process log directory.\n");
    return false;
  }

  SYSTEMTIME time{};
  GetSystemTime(&time);
  wchar_t timestamp[32]{};
  swprintf_s(timestamp, L"%04u%02u%02uT%02u%02u%02u%03uZ", time.wYear,
             time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond,
             time.wMilliseconds);
  std::wstringstream filename;
  filename << L"process_" << GetCurrentProcessId() << L"_" << timestamp << L"_"
           << g_process_mode << L"_"
           << Sanitize(Utf8ToWide(g_instance_id)) << L"_op_"
           << (g_operation_id < 0 ? 0 : g_operation_id) << L".log";
  g_log_path = directory + L"\\" + filename.str();
  if (_wputenv_s(L"WALLSYNC_DIAGNOSTIC_LOG", g_log_path.c_str()) != 0) {
    OutputDebugStringW(L"WallSync: Could not publish the process log path.\n");
    return false;
  }

  wchar_t executable[MAX_PATH]{};
  GetModuleFileNameW(nullptr, executable, MAX_PATH);
  wchar_t working_directory[MAX_PATH]{};
  GetCurrentDirectoryW(MAX_PATH, working_directory);
  LogProcessDiagnostic("process_entry",
                       "rawCommandLine=\"" +
                           EscapeLine(WideToUtf8(GetCommandLineW())) + "\"");
  LogProcessDiagnostic("parsed_arguments",
                       "arguments=" + JoinArguments(command_line_arguments));
  LogProcessDiagnostic(
      "process_mode_validation",
      "processMode=" + g_process_mode_name +
          " result=" + (g_process_mode_name == "invalid" ? "invalid"
                                                         : "provisional"));
  LogProcessDiagnostic("runtime_path",
                       "executable=\"" + WideToUtf8(executable) +
                           "\" workingDirectory=\"" +
                           WideToUtf8(working_directory) + "\"");
  LogProcessDiagnostic("diagnostic_log_path",
                       "path=\"" + WideToUtf8(g_log_path.c_str()) + "\"");
  return true;
}

void LogProcessDiagnostic(const std::string& stage,
                          const std::string& detail) {
  if (g_log_path.empty()) return;
  const std::string line =
      CurrentTimestamp() + " pid=" + std::to_string(GetCurrentProcessId()) +
      " processMode=" + g_process_mode_name + " instanceId=" +
      (g_instance_id.empty() ? "none" : EscapeLine(g_instance_id)) +
      " operationId=" +
      (g_operation_id < 0 ? "none" : std::to_string(g_operation_id)) +
      " configRevision=" + std::to_string(g_configuration_revision) +
      " stage=" + EscapeLine(stage) + " " + EscapeLine(detail) + "\r\n";
  std::lock_guard<std::mutex> lock(g_log_mutex);
  HANDLE file = CreateFileW(g_log_path.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    OutputDebugStringW(L"WallSync: Could not open the process diagnostic log.\n");
    return;
  }
  DWORD bytes_written = 0;
  const BOOL written = WriteFile(file, line.data(),
                                 static_cast<DWORD>(line.size()),
                                 &bytes_written, nullptr);
  if (written && bytes_written == line.size()) FlushFileBuffers(file);
  CloseHandle(file);
}

const std::wstring& GetProcessDiagnosticPath() { return g_log_path; }

bool CreateProcessReadinessEvent(
    const std::vector<std::string>& command_line_arguments) {
  if (g_process_mode_name != "taskbar_dock") return true;
  const std::string instance_id =
      ValueFor(command_line_arguments, "--instance-id=");
  const std::wstring event_name = ReadinessEventName(
      GetCurrentProcessId(), instance_id, g_operation_id);
  g_readiness_event =
      CreateEventW(nullptr, TRUE, FALSE, event_name.c_str());
  const DWORD error = g_readiness_event == nullptr ? GetLastError() : ERROR_SUCCESS;
  LogProcessDiagnostic(
      "ipc_server_startup",
      "transport=named-readiness-event name=\"" + WideToUtf8(event_name.c_str()) +
          "\" result=" + (g_readiness_event == nullptr ? "failed" : "ready") +
          (g_readiness_event == nullptr
               ? " error=" + WindowsError(error)
               : ""));
  return g_readiness_event != nullptr;
}

bool SignalProcessReadinessEvent() {
  if (g_readiness_event == nullptr) return false;
  const bool signaled = SetEvent(g_readiness_event) != FALSE;
  LogProcessDiagnostic("readiness_acknowledgement",
                       std::string("transport=named-readiness-event result=") +
                           (signaled ? "signaled" : "failed") +
                           (signaled ? "" : " error=" +
                                                  WindowsError(GetLastError())));
  return signaled;
}

void CloseProcessDiagnostics(int exit_code) {
  LogProcessDiagnostic("process_exit", "exitCode=" + std::to_string(exit_code));
  if (g_readiness_event != nullptr) {
    CloseHandle(g_readiness_event);
    g_readiness_event = nullptr;
  }
}

bool IsProcessReadinessEventSignaled(DWORD pid,
                                     const std::string& instance_id,
                                     int64_t operation_id) {
  if (operation_id < 0 || instance_id.empty()) return false;
  const std::wstring event_name =
      ReadinessEventName(pid, instance_id, operation_id);
  HANDLE event = OpenEventW(SYNCHRONIZE, FALSE, event_name.c_str());
  if (event == nullptr) return false;
  const bool signaled = WaitForSingleObject(event, 0) == WAIT_OBJECT_0;
  CloseHandle(event);
  return signaled;
}

bool IsCurrentProcessReadinessEventSignaled() {
  return g_readiness_event != nullptr &&
         WaitForSingleObject(g_readiness_event, 0) == WAIT_OBJECT_0;
}

std::string GetProcessModeName() { return g_process_mode_name; }
