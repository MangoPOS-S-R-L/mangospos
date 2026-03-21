import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'fullscreen_service.dart';

class _IoFullscreenService implements FullscreenService {
  @override
  Future<bool> isSupported() async => Platform.isAndroid || Platform.isWindows;

  @override
  Future<bool> isFullscreen() async {
    if (Platform.isWindows) {
      return windowManager.isFullScreen();
    }
    if (Platform.isAndroid) {
      return false;
    }
    return false;
  }

  @override
  Future<void> enterFullscreen() async {
    if (Platform.isWindows) {
      await windowManager.setFullScreen(true);
      return;
    }
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  Future<void> exitFullscreen() async {
    if (Platform.isWindows) {
      await windowManager.setFullScreen(false);
      return;
    }
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  @override
  Future<void> toggleFullscreen() async {
    if (Platform.isWindows) {
      final current = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!current);
      return;
    }
    if (Platform.isAndroid) {
      await enterFullscreen();
    }
  }
}

FullscreenService createFullscreenServiceImpl() => _IoFullscreenService();
