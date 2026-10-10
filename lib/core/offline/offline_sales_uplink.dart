import 'dart:async';

import 'package:flutter/foundation.dart';

/// Mantiene la subida activa desde el shell, incluso sin abrir Ventas.
/// El timer también recupera reintentos cuyo backoff vence estando online.
class OfflineSalesUplink {
  OfflineSalesUplink({
    required Stream<bool> connectionStream,
    required bool Function() isConnected,
    required Future<void> Function() drain,
    Duration interval = const Duration(seconds: 5),
  }) : _isConnected = isConnected,
       _drain = drain {
    _subscription = connectionStream.listen((connected) {
      if (connected) unawaited(trigger());
    });
    _timer = Timer.periodic(interval, (_) => unawaited(trigger()));
    // El stream de conectividad no reproduce el estado inicial.
    scheduleMicrotask(() => unawaited(trigger()));
  }

  final bool Function() _isConnected;
  final Future<void> Function() _drain;
  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;
  bool _triggerAgain = false;

  Future<void> trigger() async {
    if (_disposed || !_isConnected()) return;
    if (_busy) {
      _triggerAgain = true;
      return;
    }
    _busy = true;
    try {
      await _drain();
    } catch (e) {
      debugPrint('[OfflineSalesUplink] subida pendiente: $e');
    } finally {
      _busy = false;
      if (_triggerAgain && !_disposed) {
        _triggerAgain = false;
        scheduleMicrotask(() => unawaited(trigger()));
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
  }
}
