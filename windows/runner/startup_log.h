#ifndef RUNNER_STARTUP_LOG_H_
#define RUNNER_STARTUP_LOG_H_

#include <windows.h>
#include <string>

// Writes startup diagnostic messages to a log file next to the executable.
// This captures events BEFORE Flutter initializes, which is critical for
// diagnosing "app runs as background process but window never appears" issues.
namespace StartupLog {

// Initialize the log file. Call once at the very start of wWinMain.
// Creates/overwrites "mangopos_startup.log" next to the .exe.
void Init();

// Write a timestamped message to the log file.
void Log(const char* message);
void Log(const std::string& message);

// Write system info (OS version, screen size, DPI, etc.)
void LogSystemInfo();

// Flush and close the log file.
void Close();

}  // namespace StartupLog

#endif  // RUNNER_STARTUP_LOG_H_
