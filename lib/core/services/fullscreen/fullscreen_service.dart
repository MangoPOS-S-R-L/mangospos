import 'fullscreen_service_stub.dart'
    if (dart.library.html) 'fullscreen_service_web.dart'
    if (dart.library.io) 'fullscreen_service_io.dart';

abstract class FullscreenService {
  Future<bool> isSupported();
  Future<bool> isFullscreen();
  Future<void> enterFullscreen();
  Future<void> exitFullscreen();
  Future<void> toggleFullscreen();
}

FullscreenService createFullscreenService() => createFullscreenServiceImpl();
