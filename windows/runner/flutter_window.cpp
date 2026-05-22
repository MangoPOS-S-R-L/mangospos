#include "flutter_window.h"

#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "startup_log.h"

namespace {
constexpr const char* kWindowChannelName = "mangopos/window";
}  // namespace

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

  // mangopos/window channel: native fullscreen toggle because window_manager
  // is intentionally disabled on Windows in lib/main.dart.
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        const std::string& name = call.method_name();
        if (name == "isFullscreen") {
          result->Success(flutter::EncodableValue(this->fullscreen_));
        } else if (name == "enterFullscreen") {
          this->EnterFullscreen();
          result->Success();
        } else if (name == "exitFullscreen") {
          this->ExitFullscreen();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

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

void FlutterWindow::EnterFullscreen() {
  HWND hwnd = GetHandle();
  if (!hwnd || fullscreen_) {
    return;
  }

  // Capture pre-fullscreen state so we can restore exactly to the same window
  // chrome, position, and dimensions on exit.
  saved_placement_.length = sizeof(WINDOWPLACEMENT);
  ::GetWindowPlacement(hwnd, &saved_placement_);
  saved_style_ = ::GetWindowLongW(hwnd, GWL_STYLE);
  saved_exstyle_ = ::GetWindowLongW(hwnd, GWL_EXSTYLE);

  // Bounds of the monitor that hosts the window. Multi-monitor friendly.
  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (!::GetMonitorInfoW(monitor, &mi)) {
    return;
  }

  ::SetWindowLongW(hwnd, GWL_STYLE, saved_style_ & ~WS_OVERLAPPEDWINDOW);
  ::SetWindowLongW(hwnd, GWL_EXSTYLE,
                    saved_exstyle_ & ~(WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE |
                                       WS_EX_CLIENTEDGE | WS_EX_STATICEDGE));
  ::SetWindowPos(hwnd, HWND_TOP,
                 mi.rcMonitor.left, mi.rcMonitor.top,
                 mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  fullscreen_ = true;
}

void FlutterWindow::ExitFullscreen() {
  HWND hwnd = GetHandle();
  if (!hwnd || !fullscreen_) {
    return;
  }

  ::SetWindowLongW(hwnd, GWL_STYLE, saved_style_);
  ::SetWindowLongW(hwnd, GWL_EXSTYLE, saved_exstyle_);
  ::SetWindowPlacement(hwnd, &saved_placement_);
  ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                     SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  fullscreen_ = false;
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
