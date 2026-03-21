import 'fullscreen_service.dart';

class _UnsupportedFullscreenService implements FullscreenService {
  @override
  Future<void> enterFullscreen() async {}

  @override
  Future<void> exitFullscreen() async {}

  @override
  Future<bool> isFullscreen() async => false;

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<void> toggleFullscreen() async {}
}

FullscreenService createFullscreenServiceImpl() =>
    _UnsupportedFullscreenService();
