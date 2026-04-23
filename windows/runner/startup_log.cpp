#include "startup_log.h"

#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <time.h>

#include <string>

namespace StartupLog {

static FILE* g_log_file = nullptr;

static void EmitToConsoleAndDebugger(const std::string& line) {
  // Always send to debugger (View -> Output) when available.
  ::OutputDebugStringA(line.c_str());

  // If a console is attached (e.g. `flutter run`), print there too.
  if (::GetConsoleWindow() != nullptr) {
    fwrite(line.c_str(), 1, line.size(), stderr);
    fflush(stderr);
  }
}

static std::string GetLogFilePath() {
  // Write to Desktop so the user can find it immediately
  char desktop[MAX_PATH];
  if (SUCCEEDED(::SHGetFolderPathA(nullptr, CSIDL_DESKTOPDIRECTORY, nullptr, 0,
                                    desktop))) {
    DWORD attrs = ::GetFileAttributesA(desktop);
    if (attrs != INVALID_FILE_ATTRIBUTES &&
        (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
      return std::string(desktop) + "\\mangopos_startup.log";
    }
  }
  // Fallback to temp directory
  char temp[MAX_PATH];
  ::GetTempPathA(MAX_PATH, temp);
  return std::string(temp) + "mangopos_startup.log";
}

static std::string GetTimestamp() {
  time_t now = time(nullptr);
  struct tm local_time;
  localtime_s(&local_time, &now);
  char buf[64];
  strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &local_time);
  return std::string(buf);
}

void Init() {
  std::string path = GetLogFilePath();
  fopen_s(&g_log_file, path.c_str(), "w");
  Log("=== MangoPOS Startup Log ===");
  Log("Log file: " + path);
}

void Log(const char* message) {
  std::string line =
      "[" + GetTimestamp() + "] " + std::string(message ? message : "") + "\n";

  if (g_log_file) {
    fwrite(line.c_str(), 1, line.size(), g_log_file);
    fflush(g_log_file);
  }

  EmitToConsoleAndDebugger(line);
}

void Log(const std::string& message) {
  Log(message.c_str());
}

void LogSystemInfo() {
  if (!g_log_file) return;

  // OS Version
  OSVERSIONINFOEXW osvi = {};
  osvi.dwOSVersionInfoSize = sizeof(osvi);
#pragma warning(push)
#pragma warning(disable : 4996)  // GetVersionEx deprecated but works on Win7
  GetVersionExW(reinterpret_cast<OSVERSIONINFOW*>(&osvi));
#pragma warning(pop)

  char buf[256];
  snprintf(buf, sizeof(buf), "OS: Windows %lu.%lu build %lu (SP %u.%u)",
           osvi.dwMajorVersion, osvi.dwMinorVersion, osvi.dwBuildNumber,
           osvi.wServicePackMajor, osvi.wServicePackMinor);
  Log(buf);

  // Architecture
  SYSTEM_INFO si = {};
  ::GetNativeSystemInfo(&si);
  const char* arch = "unknown";
  switch (si.wProcessorArchitecture) {
    case PROCESSOR_ARCHITECTURE_AMD64: arch = "x64"; break;
    case PROCESSOR_ARCHITECTURE_INTEL: arch = "x86"; break;
    case PROCESSOR_ARCHITECTURE_ARM64: arch = "ARM64"; break;
  }
  snprintf(buf, sizeof(buf), "Processor: %s, cores: %lu", arch,
           si.dwNumberOfProcessors);
  Log(buf);

  // Memory
  MEMORYSTATUSEX mem = {};
  mem.dwLength = sizeof(mem);
  if (::GlobalMemoryStatusEx(&mem)) {
    snprintf(buf, sizeof(buf), "RAM: %llu MB total, %llu MB available",
             mem.ullTotalPhys / (1024 * 1024),
             mem.ullAvailPhys / (1024 * 1024));
    Log(buf);
  }

  // Screen
  int screenW = ::GetSystemMetrics(SM_CXSCREEN);
  int screenH = ::GetSystemMetrics(SM_CYSCREEN);
  snprintf(buf, sizeof(buf), "Screen: %dx%d", screenW, screenH);
  Log(buf);

  // DPI (primary monitor)
  HDC hdc = ::GetDC(nullptr);
  if (hdc) {
    int dpiX = ::GetDeviceCaps(hdc, LOGPIXELSX);
    int dpiY = ::GetDeviceCaps(hdc, LOGPIXELSY);
    snprintf(buf, sizeof(buf), "DPI: %dx%d (scale: %.0f%%)", dpiX, dpiY,
             dpiX * 100.0 / 96.0);
    Log(buf);
    ::ReleaseDC(nullptr, hdc);
  }

  // GPU info (basic - adapter description)
  // Not available without DXGI, skip for Win7 compat
}

void Close() {
  if (g_log_file) {
    Log("=== Log closed ===");
    fclose(g_log_file);
    g_log_file = nullptr;
  }
}

}  // namespace StartupLog
