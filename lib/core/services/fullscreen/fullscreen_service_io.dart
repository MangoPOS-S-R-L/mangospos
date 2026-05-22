import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'fullscreen_service.dart';

class _IoFullscreenService implements FullscreenService {
  // MethodChannel para Windows: window_manager no se inicializa en Windows
  // (ver lib/main.dart) por crashes históricos, así que el toggle se delega
  // al runner nativo C++.
  static const _windowsChannel = MethodChannel('mangopos/window');

  // SystemChrome no expone un getter de "modo actual", así que cacheamos
  // el estado para Android/iOS dentro de la instancia del servicio.
  bool _mobileFullscreen = false;

  @override
  Future<bool> isSupported() async {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isLinux ||
        Platform.isWindows;
  }

  @override
  Future<bool> isFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return _mobileFullscreen;
    }
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        return await windowManager.isFullScreen();
      } catch (_) {
        return false;
      }
    }
    if (Platform.isWindows) {
      try {
        final result = await _windowsChannel.invokeMethod<bool>(
          'isFullscreen',
        );
        return result ?? false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  @override
  Future<void> enterFullscreen() async {
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _mobileFullscreen = true;
    } else if (Platform.isIOS) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const [],
      );
      _mobileFullscreen = true;
    } else if (Platform.isMacOS || Platform.isLinux) {
      try {
        await windowManager.setFullScreen(true);
      } catch (_) {}
    } else if (Platform.isWindows) {
      try {
        await _windowsChannel.invokeMethod('enterFullscreen');
      } catch (_) {}
    }
  }

  @override
  Future<void> exitFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
      _mobileFullscreen = false;
    } else if (Platform.isMacOS || Platform.isLinux) {
      try {
        await windowManager.setFullScreen(false);
      } catch (_) {}
    } else if (Platform.isWindows) {
      try {
        await _windowsChannel.invokeMethod('exitFullscreen');
      } catch (_) {}
    }
  }

  @override
  Future<void> toggleFullscreen() async {
    if (await isFullscreen()) {
      await exitFullscreen();
    } else {
      await enterFullscreen();
    }
  }
}

FullscreenService createFullscreenServiceImpl() => _IoFullscreenService();
