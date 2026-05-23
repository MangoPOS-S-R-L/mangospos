import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../env/env.dart';

/// Servicio de monitoreo de conectividad.
///
/// `isConnected` combina dos señales:
/// 1. Estado del adaptador (wifi/ethernet/mobile vía `connectivity_plus`).
/// 2. Alcance real a Supabase (healthcheck periódico contra `/auth/v1/health`).
///
/// Esto resuelve el caso "wifi conectado pero sin WAN / Supabase caído": el
/// adapter dice connected pero las llamadas HTTP cuelgan por timeout. Con este
/// cambio, `isConnected` baja a `false` y las ramas offline existentes se
/// activan automáticamente sin necesidad de tocar los call sites.
class ConnectivityService {
  static ConnectivityService? _instance;
  final Connectivity _connectivity = Connectivity();

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  bool _adapterUp = true;
  bool _reachable = true;
  bool _initialized = false;
  int _failedProbes = 0;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _reachabilityTimer;

  /// Cuántos fallos consecutivos toleramos antes de marcar como offline.
  /// Evita falsos positivos por blips de red transitorios.
  static const int _failureThreshold = 2;

  /// Periodicidad del healthcheck cuando el adapter está up.
  static const Duration _probeInterval = Duration(seconds: 30);

  /// Timeout corto del healthcheck. Si tarda más, el server está degradado.
  static const Duration _probeTimeout = Duration(seconds: 3);

  ConnectivityService._();

  /// Singleton instance
  factory ConnectivityService() {
    _instance ??= ConnectivityService._();
    return _instance!;
  }

  /// Stream de cambios de conectividad efectiva (adapter + alcance real).
  Stream<bool> get connectionStream => _connectionController.stream;

  /// Conectividad efectiva: adapter up Y Supabase alcanzable.
  /// Esta es la propiedad que deben consultar las ramas offline del POS.
  bool get isConnected => _adapterUp && _reachable;

  /// Estado del adaptador puro (sin healthcheck). Útil solo para diagnóstico
  /// o UI que distinga "sin wifi" vs "wifi pero servidor caído".
  bool get isAdapterUp => _adapterUp;

  /// Última lectura del healthcheck (sin contar el adapter).
  bool get isReachable => _reachable;

  /// Inicializar monitoreo de conectividad
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Verificar estado inicial del adapter.
    await _checkAdapter();

    // Si el adapter está up, verificar alcance real una vez al arrancar.
    if (_adapterUp) {
      await _probeReachability();
    } else {
      _reachable = false;
    }

    // Escuchar cambios del adapter.
    _subscription = _connectivity.onConnectivityChanged.listen(
      _handleAdapterChange,
      onError: (error) {
        debugPrint('Error en connectivity stream: $error');
      },
    );

    // Polling de reachability cuando el adapter está up.
    _startReachabilityPolling();

    debugPrint(
      'ConnectivityService initialized. '
      'adapter=$_adapterUp reachable=$_reachable',
    );
  }

  /// Verificar conectividad actual del adapter.
  Future<void> _checkAdapter() async {
    try {
      final result = await _connectivity.checkConnectivity();
      _updateAdapterStatus(result, emit: false);
    } catch (e) {
      debugPrint('Error checking adapter: $e');
      _updateAdapterStatus([ConnectivityResult.none], emit: false);
    }
  }

  /// Manejar cambios de adapter.
  void _handleAdapterChange(List<ConnectivityResult> results) {
    _updateAdapterStatus(results, emit: true);

    // Si el adapter acaba de subir, hacer un probe inmediato para no esperar
    // 30s al próximo poll.
    if (_adapterUp) {
      unawaited(_probeReachability(emit: true));
    } else {
      // Adapter abajo → forzamos reachable=false al toque.
      _failedProbes = _failureThreshold;
      if (_reachable) {
        _reachable = false;
        _emitCombined();
      }
    }
  }

  /// Actualizar estado del adaptador. `emit` controla si se notifica el cambio
  /// combinado en el stream — al inicializar no emitimos porque todavía no se
  /// ha probado reachability.
  void _updateAdapterStatus(
    List<ConnectivityResult> results, {
    required bool emit,
  }) {
    final wasConnected = isConnected;

    // Hay algún transport válido (no none, no solo bluetooth).
    _adapterUp = results.any(
      (result) =>
          result != ConnectivityResult.none &&
          result != ConnectivityResult.bluetooth,
    );

    if (emit && wasConnected != isConnected) {
      debugPrint('Adapter changed: $_adapterUp (combined=$isConnected)');
      _connectionController.add(isConnected);
    }
  }

  /// Lanza healthcheck contra Supabase y actualiza `_reachable`.
  Future<void> _probeReachability({bool emit = false}) async {
    if (!_adapterUp) {
      _reachable = false;
      return;
    }

    final wasConnected = isConnected;

    try {
      final url = Uri.parse('${Env.supabaseUrl}/auth/v1/health');
      final response = await http
          .get(url)
          .timeout(_probeTimeout);

      // Supabase auth/health responde 200 con `{"description":"...","name":"GoTrue"}`.
      // Cualquier 2xx/3xx vale como "alcanzable".
      if (response.statusCode >= 200 && response.statusCode < 400) {
        _failedProbes = 0;
        if (!_reachable) {
          _reachable = true;
          debugPrint('Supabase reachable again');
        }
      } else {
        _markProbeFailure('status ${response.statusCode}');
      }
    } on TimeoutException {
      _markProbeFailure('timeout');
    } catch (e) {
      _markProbeFailure('$e');
    }

    if (emit && wasConnected != isConnected) {
      _emitCombined();
    }
  }

  void _markProbeFailure(String reason) {
    _failedProbes++;
    if (_failedProbes >= _failureThreshold && _reachable) {
      _reachable = false;
      debugPrint('Supabase unreachable ($_failedProbes probes failed: $reason)');
    }
  }

  void _emitCombined() {
    debugPrint(
      'Connectivity combined: $isConnected '
      '(adapter=$_adapterUp reachable=$_reachable)',
    );
    _connectionController.add(isConnected);
  }

  void _startReachabilityPolling() {
    _reachabilityTimer?.cancel();
    _reachabilityTimer = Timer.periodic(_probeInterval, (_) async {
      if (!_adapterUp) return;
      await _probeReachability(emit: true);
    });
  }

  /// Forzar un check ad-hoc. Útil cuando un viewmodel acaba de fallar una
  /// llamada y quiere re-validar el estado sin esperar al próximo poll.
  Future<bool> forceReachabilityCheck() async {
    await _probeReachability(emit: true);
    return isConnected;
  }

  /// Simular desconexión (para testing).
  void simulateDisconnect() {
    debugPrint('🔴 Simulating disconnect...');
    _adapterUp = false;
    _reachable = false;
    _failedProbes = _failureThreshold;
    _connectionController.add(false);
  }

  /// Simular reconexión (para testing).
  void simulateReconnect() {
    debugPrint('🟢 Simulating reconnect...');
    _adapterUp = true;
    _reachable = true;
    _failedProbes = 0;
    _connectionController.add(true);
  }

  /// Limpiar recursos.
  void dispose() {
    _reachabilityTimer?.cancel();
    _subscription?.cancel();
    _connectionController.close();
  }
}
