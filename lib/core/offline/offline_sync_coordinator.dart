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
    bool Function()? isConnectedNow,
    Duration startupDelay = const Duration(seconds: 5),
  })  : _connectionStream = connectionStream,
        _refreshers = refreshers,
        _periodic = periodic,
        _isConnectedNow = isConnectedNow,
        _startupDelay = startupDelay;

  final Stream<bool> _connectionStream;
  final List<Future<void> Function()> _refreshers;
  final Duration _periodic;

  /// Lectura EN VIVO de la conectividad. Sin esto el coordinador solo conoce
  /// el estado que le haya llegado por [_connectionStream] — y ese stream es
  /// un broadcast sin replay que únicamente emite en los CAMBIOS
  /// (`ConnectivityService._updateAdapterStatus(..., emit: false)` al
  /// inicializar). En el caso normal —el equipo nace con internet y se queda
  /// con internet— el stream no emitía nunca, `_connected` se quedaba en
  /// `false` y NI la siembra inicial NI el timer periódico llegaban a correr:
  /// los caches de lectura nunca se sembraban y el device llegaba a su primera
  /// caída de red en frío. Es opcional para no romper los tests que inyectan
  /// solo el stream.
  final bool Function()? _isConnectedNow;

  /// Espera antes de la siembra inicial, para no competir con la carga de la
  /// primera pantalla (el shell lee este provider mientras el salón arranca).
  final Duration _startupDelay;

  StreamSubscription<bool>? _sub;
  Timer? _timer;
  Timer? _startupTimer;
  bool _connected = false;
  bool _inFlight = false;
  bool _disposed = false;

  /// Conectividad efectiva: la lectura en vivo si la hay, si no lo último que
  /// llegó por el stream.
  bool get _isOnline => _isConnectedNow?.call() ?? _connected;

  void start() {
    if (_disposed) return;
    // Semilla: arrancar en `false` a ciegas es lo que rompía la siembra. Con
    // la lectura en vivo el estado inicial es el real, y la detección de
    // transición sigue siendo correcta: si el device está offline de verdad,
    // el probe emitirá `false` y la reconexión posterior sí cuenta como
    // offline→online.
    _connected = _isConnectedNow?.call() ?? _connected;

    _sub = _connectionStream.listen((connected) {
      final wasConnected = _connected;
      _connected = connected;
      // Solo al pasar offline→online refrescamos (no en cada tick del probe).
      if (connected && !wasConnected) unawaited(refreshAll());
    });
    // Red de seguridad: aunque no haya transición, refresca cada tanto si hay
    // conexión (cubre cambios del server mientras el device sigue online).
    _timer = Timer.periodic(_periodic, (_) {
      if (_isOnline) unawaited(refreshAll());
    });

    // Siembra inicial: sin esto, un device que nunca pierde la red no cachea
    // nada hasta el primer corte — justo cuando ya es tarde.
    if (_isConnectedNow == null) return;
    if (_startupDelay <= Duration.zero) {
      if (_isOnline) unawaited(refreshAll());
      return;
    }
    _startupTimer = Timer(_startupDelay, () {
      if (_disposed || !_isOnline) return;
      unawaited(refreshAll());
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
    _startupTimer?.cancel();
    _startupTimer = null;
  }
}
