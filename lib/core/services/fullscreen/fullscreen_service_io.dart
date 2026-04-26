import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'fullscreen_service.dart';

class _IoFullscreenService implements FullscreenService {
  @override
  Future<bool> isSupported() async => Platform.isAndroid;

  @override
  Future<bool> isFullscreen() async {
    if (Platform.isAndroid) {
      return false;
    }
    return false;
  }

  @override
  Future<void> enterFullscreen() async {
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  Future<void> exitFullscreen() async {
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  @override
  Future<void> toggleFullscreen() async {
    if (Platform.isAndroid) {
      await enterFullscreen();
    }
  }
}

FullscreenService createFullscreenServiceImpl() => _IoFullscreenService();
