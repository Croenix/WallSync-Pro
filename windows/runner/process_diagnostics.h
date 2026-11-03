#ifndef RUNNER_PROCESS_DIAGNOSTICS_H_
#define RUNNER_PROCESS_DIAGNOSTICS_H_

#include <windows.h>

#include <string>
#include <vector>

bool InitializeProcessDiagnostics(
    const std::vector<std::string>& command_line_arguments);
void LogProcessDiagnostic(const std::string& stage,
                          const std::string& detail);
const std::wstring& GetProcessDiagnosticPath();
bool CreateProcessReadinessEvent(
    const std::vector<std::string>& command_line_arguments);
bool SignalProcessReadinessEvent();
void CloseProcessDiagnostics(int exit_code);
bool IsProcessReadinessEventSignaled(DWORD pid,
                                     const std::string& instance_id,
                                     int64_t operation_id);
bool IsCurrentProcessReadinessEventSignaled();
std::string GetProcessModeName();

#endif  // RUNNER_PROCESS_DIAGNOSTICS_H_
