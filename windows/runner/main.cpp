#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "startup_log.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Start diagnostic logging immediately
  StartupLog::Init();
  StartupLog::Log("wWinMain entered");
  StartupLog::LogSystemInfo();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
    StartupLog::Log("Console attached (debugger detected)");
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  HRESULT com_result = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (SUCCEEDED(com_result)) {
    StartupLog::Log("COM initialized OK");
  } else {
    char buf[128];
    snprintf(buf, sizeof(buf), "COM initialization FAILED: HRESULT=0x%08lX",
             com_result);
    StartupLog::Log(buf);
  }

  StartupLog::Log("Creating DartProject...");
  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));
  StartupLog::Log("DartProject created");

  // Detect primary monitor size and adapt window to fit any screen
  int screenWidth = ::GetSystemMetrics(SM_CXSCREEN);
  int screenHeight = ::GetSystemMetrics(SM_CYSCREEN);

  // Use 90% of screen or 1280x720, whichever is smaller
  int winWidth = (screenWidth * 90) / 100;
  int winHeight = (screenHeight * 90) / 100;
  if (winWidth > 1280) winWidth = 1280;
  if (winHeight > 720) winHeight = 720;
  // Minimum usable size
  if (winWidth < 800) winWidth = 800;
  if (winHeight < 600) winHeight = 600;

  // Center on screen
  int originX = (screenWidth - winWidth) / 2;
  int originY = (screenHeight - winHeight) / 2;
  if (originX < 0) originX = 0;
  if (originY < 0) originY = 0;

  char size_buf[128];
  snprintf(size_buf, sizeof(size_buf),
           "Window: %dx%d at (%d,%d) | Screen: %dx%d",
           winWidth, winHeight, originX, originY, screenWidth, screenHeight);
  StartupLog::Log(size_buf);

  StartupLog::Log("Creating FlutterWindow...");
  FlutterWindow window(project);
  Win32Window::Point origin(originX, originY);
  Win32Window::Size size(winWidth, winHeight);

  StartupLog::Log("Calling window.Create()...");
  if (!window.Create(L"MangoPOS", origin, size)) {
    StartupLog::Log("ERROR: window.Create() FAILED - exiting");
    StartupLog::Close();
    return EXIT_FAILURE;
  }
  StartupLog::Log("window.Create() succeeded");

  StartupLog::Log("Showing native window immediately as startup safety fallback...");
  if (window.Show()) {
    StartupLog::Log("Native window shown before first Flutter frame");
  } else {
    StartupLog::Log("WARNING: window.Show() returned false during startup fallback");
  }

  // POS environments always boot maximized so the cashier sees the full UI
  // without manual resizing. Apply after Show() so foreground/focus state
  // from Win32Window::Show() is preserved.
  if (HWND hwnd = window.GetHandle()) {
    ::ShowWindow(hwnd, SW_MAXIMIZE);
    StartupLog::Log("Native window maximized on startup");
  }

  window.SetQuitOnClose(true);
  StartupLog::Log("Entering message loop (Flutter should render first frame soon)...");

  ::MSG msg;
  BOOL get_message_result = 0;
  while ((get_message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (get_message_result == -1) {
    DWORD err = ::GetLastError();
    char buf[128];
    snprintf(buf, sizeof(buf), "GetMessage FAILED: GetLastError=%lu", err);
    StartupLog::Log(buf);
  } else {
    char buf[128];
    snprintf(buf, sizeof(buf), "WM_QUIT received: exitCode=%llu",
             static_cast<unsigned long long>(msg.wParam));
    StartupLog::Log(buf);
  }

  StartupLog::Log("Message loop exited, shutting down");
  StartupLog::Close();

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
