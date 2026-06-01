import 'dart:async';

import 'package:flutter/foundation.dart';

/// Coordina la BAJADA de datos (server → device) en reconexión (F6). Refresca
/// los caches de lectura (catálogo, roster, zonas, inventario, config…) sin
/// depender de qué pantallas se abrieron, para que el device esté listo para
/// el próximo corte de internet.
///
/// La SUBIDA (device → server) ya la maneja la cola offline / el Hub; este
/// coordinador es la otra mitad. No hay conflictos de merge: cada dirección
/// posee datos disjuntos (device = transacciones, server = catálogo/config).
///
/// Cada "refresher" es un `fetch + cachear` best-effort: si uno falla, no
/// frena a los demás. Diseñado con refreshers inyectados → testeable sin
/// red/BD; la composición real los arma desde los servicios de cada módulo.
class OfflineSyncCoordinator {
  OfflineSyncCoordinator({
    required Stream<bool> connectionStream,
    required List<Future<void> Function()> refreshers,
    Duration periodic = const Duration(minutes: 15),
  })  : _connectionStream = connectionStream,
        _refreshers = refreshers,
        _periodic = periodic;

  final Stream<bool> _connectionStream;
  final List<Future<void> Function()> _refreshers;
  final Duration _periodic;

  StreamSubscription<bool>? _sub;
  Timer? _timer;
  bool _connected = false;
  bool _inFlight = false;
  bool _disposed = false;

  void start() {
    if (_disposed) return;
    _sub = _connectionStream.listen((connected) {
      final wasConnected = _connected;
      _connected = connected;
      // Solo al pasar offline→online refrescamos (no en cada tick del probe).
      if (connected && !wasConnected) unawaited(refreshAll());
    });
    // Red de seguridad: aunque no haya transición, refresca cada tanto si hay
    // conexión (cubre cambios del server mientras el device sigue online).
    _timer = Timer.periodic(_periodic, (_) {
      if (_connected) unawaited(refreshAll());
    });
  }

  /// Corre todos los refreshers en orden, best-effort. Guard de solapamiento:
  /// si ya hay un refresh en vuelo, no arranca otro.
  Future<void> refreshAll() async {
    if (_inFlight || _disposed) return;
    _inFlight = true;
    try {
      for (final refresh in _refreshers) {
        try {
          await refresh();
        } catch (e) {
          debugPrint('[OfflineSyncCoordinator] refresher falló: $e');
        }
      }
    } finally {
      _inFlight = false;
    }
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
  }
}
