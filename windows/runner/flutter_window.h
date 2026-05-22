#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <windows.h>

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // mangopos/window channel for native fullscreen toggle. Kept as a member
  // so its handler survives past OnCreate(); destroying the channel would
  // unregister the handler.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Native fullscreen state (replaces window_manager on Windows, which is
  // disabled because of historical crashes in this app). Captured the first
  // time enterFullscreen is called and replayed on exit.
  bool fullscreen_ = false;
  WINDOWPLACEMENT saved_placement_ = { sizeof(WINDOWPLACEMENT) };
  LONG saved_style_ = 0;
  LONG saved_exstyle_ = 0;

  void EnterFullscreen();
  void ExitFullscreen();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
