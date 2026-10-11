import 'dart:async';

import 'package:flutter/foundation.dart';

/// Mantiene la subida activa desde el shell, incluso sin abrir Ventas.
///
/// Despierta al arrancar, al reconectar y con cada evento de [wakeups]
/// (trabajo recién guardado en la cola, la app vuelve al primer plano). El
/// timer queda como red de seguridad: recupera avisos perdidos y reintentos
/// cuyo backoff vence estando online. Nunca corre dos drenajes a la vez: lo
/// que llega durante uno se junta en UN drenaje más al terminar.
class OfflineSalesUplink {
  OfflineSalesUplink({
    required Stream<bool> connectionStream,
    required bool Function() isConnected,
    required Future<void> Function() drain,
    Iterable<Stream<Object?>> wakeups = const [],
    Duration interval = const Duration(seconds: 5),
  }) : _isConnected = isConnected,
       _drain = drain {
    _subscription = connectionStream.listen((connected) {
      if (connected) unawaited(trigger());
    });
    for (final wakeup in wakeups) {
      _wakeupSubscriptions.add(wakeup.listen((_) => unawaited(trigger())));
    }
    _timer = Timer.periodic(interval, (_) => unawaited(trigger()));
    // El stream de conectividad no reproduce el estado inicial.
    scheduleMicrotask(() => unawaited(trigger()));
  }

  final bool Function() _isConnected;
  final Future<void> Function() _drain;
  StreamSubscription<bool>? _subscription;
  final List<StreamSubscription<Object?>> _wakeupSubscriptions = [];
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
    for (final subscription in _wakeupSubscriptions) {
      unawaited(subscription.cancel());
    }
    _wakeupSubscriptions.clear();
  }
}
