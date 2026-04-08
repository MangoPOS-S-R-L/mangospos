#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "startup_log.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  StartupLog::Log("FlutterWindow::OnCreate() called");

  if (!Win32Window::OnCreate()) {
    StartupLog::Log("ERROR: Win32Window::OnCreate() failed");
    return false;
  }
  StartupLog::Log("Win32Window::OnCreate() OK");

  RECT frame = GetClientArea();
  int w = frame.right - frame.left;
  int h = frame.bottom - frame.top;

  char buf[128];
  snprintf(buf, sizeof(buf), "Client area: %dx%d", w, h);
  StartupLog::Log(buf);

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  StartupLog::Log("Creating FlutterViewController...");
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      w, h, project_);

  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine()) {
    StartupLog::Log("ERROR: Flutter engine is NULL");
    return false;
  }
  if (!flutter_controller_->view()) {
    StartupLog::Log("ERROR: Flutter view is NULL");
    return false;
  }
  StartupLog::Log("FlutterViewController created OK (engine + view valid)");

  StartupLog::Log("Registering plugins...");
  RegisterPlugins(flutter_controller_->engine());
  StartupLog::Log("Plugins registered");

  StartupLog::Log("Setting child content...");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  StartupLog::Log("Child content set");

  StartupLog::Log("Registering first-frame callback (window will show on first frame)...");
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    StartupLog::Log(">>> FIRST FRAME RENDERED - calling Show()");
    this->Show();
    StartupLog::Log(">>> Window shown!");
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  StartupLog::Log("Calling ForceRedraw()...");
  flutter_controller_->ForceRedraw();
  StartupLog::Log("ForceRedraw() done. Waiting for first frame...");

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
