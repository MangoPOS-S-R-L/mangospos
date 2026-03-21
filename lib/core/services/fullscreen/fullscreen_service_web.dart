import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'fullscreen_service.dart';

class _WebFullscreenService implements FullscreenService {
  web.Document get _document => web.window.document;

  @override
  Future<bool> isSupported() async {
    final body = _document.body;
    if (body == null) return false;
    return body.hasProperty('requestFullscreen'.toJS).toDart;
  }

  @override
  Future<bool> isFullscreen() async => _document.fullscreenElement != null;

  @override
  Future<void> enterFullscreen() async {
    final body = _document.body;
    if (body == null) return;
    if (!await isSupported()) return;
    if (await isFullscreen()) return;
    await body.requestFullscreen().toDart;
  }

  @override
  Future<void> exitFullscreen() async {
    if (!await isFullscreen()) return;
    await _document.exitFullscreen().toDart;
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

FullscreenService createFullscreenServiceImpl() => _WebFullscreenService();
