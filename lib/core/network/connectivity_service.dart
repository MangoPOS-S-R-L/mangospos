import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../env/env.dart';

/// Snapshot de diagnostico para la UI. Muestra exactamente que rompio
/// el probe sin necesidad de abrir consola debug.
class ConnectivityDiagnostics {
  const ConnectivityDiagnostics({
    required this.adapterUp,
    required this.reachable,
    required this.failedProbes,
    required this.supabaseUrl,
    this.lastProbeAt,
    this.lastProbeUrl,
    this.lastProbeStatus,
    this.lastProbeError,
    this.lastProbeDuration,
  });

  final bool adapterUp;
  final bool reachable;
  final int failedProbes;
  final String supabaseUrl;
  final DateTime? lastProbeAt;
  final String? lastProbeUrl;
  final int? lastProbeStatus;
  final String? lastProbeError;
  final Duration? lastProbeDuration;

  bool get isConnected => adapterUp && reachable;
}

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

  // Diagnostico del ultimo probe — expuesto via [diagnostics] para
  // que la UI muestre exactamente que rompio (path probado, status,
  // error, duracion). Sin esto el cajero tiene que abrir consola debug.
  DateTime? _lastProbeAt;
  String? _lastProbeUrl;
  int? _lastProbeStatus;
  String? _lastProbeError;
  Duration? _lastProbeDuration;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _reachabilityTimer;
  Timer? _confirmProbeTimer;

  /// Sondeo en curso, compartido: el timer, [forceReachabilityCheck] y
  /// [reportTransportFailure] no lanzan sondeos en paralelo.
  Future<void>? _inFlightProbe;

  /// Último sondeo HTTP que FALLÓ de verdad (no el adaptador caído). Es la
  /// evidencia que exige [isKnownOffline] para cortar peticiones sin intentarlas.
  DateTime? _lastHttpProbeFailedAt;

  /// Cuántos fallos consecutivos toleramos antes de marcar como offline.
  /// Evita falsos positivos por blips de red transitorios.
  static const int _failureThreshold = 2;

  /// Periodicidad del healthcheck cuando el adapter está up Y reachable.
  static const Duration _probeInterval = Duration(seconds: 30);

  /// Periodicidad acelerada cuando estamos marcados como offline — para
  /// recuperar mas rapido cuando vuelve la conectividad (sin esperar
  /// 30s de la cadencia normal). Antes el cajero veia "Sin conexion"
  /// durante medio minuto despues de que la red ya estaba OK.
  static const Duration _probeIntervalFast = Duration(seconds: 5);

  /// Timeout del healthcheck. 8s da margen para TLS handshake lento
  /// (Coolify/Cloudflare detras pueden agregar 1-3s en cold start) sin
  /// dejar al cajero esperando una eternidad.
  static const Duration _probeTimeout = Duration(seconds: 8);

  /// Tras un sondeo fallido que todavía no llega al umbral, el segundo se
  /// hace a los pocos segundos en vez de esperar la cadencia de 30s. Antes la
  /// caja tardaba hasta minuto y medio en admitir que se fue el internet, y
  /// todo lo que no tenía timeout propio se quedaba colgado ese rato.
  static const Duration _confirmProbeDelay = Duration(seconds: 3);

  /// Cuánto vale un sondeo fallido como evidencia para [isKnownOffline].
  /// Sin red el timer sondea cada 5s, así que en la práctica se renueva solo;
  /// si por lo que sea dejara de sondear, se vuelve a intentar la red.
  static const Duration _knownOfflineEvidence = Duration(seconds: 45);

  /// Mínimo entre dos confirmaciones disparadas por [reportTransportFailure]:
  /// cuando se va la red fallan muchas peticiones a la vez.
  static const Duration _transportReportThrottle = Duration(seconds: 3);
  DateTime? _lastTransportReportAt;

  /// Endpoints a probar en orden. Aceptamos cualquier respuesta del
  /// server (incluso 401/404) como "alcanzable" — el solo hecho de
  /// recibir respuesta HTTP prueba que la red llego al server. Solo
  /// timeouts/network errors/5xx cuentan como unreachable.
  ///
  /// Multiples paths porque diferentes deploys de Supabase tienen
  /// configuraciones distintas: el self-hosted via Kong puede tener
  /// /auth/v1/health bloqueado pero /rest/v1/ accesible, etc.
  static List<String> get _probePaths => [
        '/auth/v1/health',
        '/rest/v1/',
        '/',
      ];

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

  /// `true` solo si un sondeo HTTP reciente confirmó que el servidor no
  /// responde. Más estricto que `!isConnected` a propósito: el adaptador caído
  /// por sí solo no cuenta (connectivity_plus reporta "none" en falso en
  /// algunos equipos), porque esto se usa para NO intentar la red.
  bool get isKnownOffline {
    if (_reachable) return false;
    final failedAt = _lastHttpProbeFailedAt;
    return failedAt != null &&
        DateTime.now().difference(failedAt) < _knownOfflineEvidence;
  }

  /// Una petición real al servidor acaba de fallar por red. Sondea YA (y
  /// confirma enseguida) en vez de esperar al siguiente tick de 30s.
  void reportTransportFailure() {
    if (!_initialized || !_adapterUp || !_reachable) return;
    final now = DateTime.now();
    final last = _lastTransportReportAt;
    if (last != null && now.difference(last) < _transportReportThrottle) {
      return;
    }
    _lastTransportReportAt = now;
    unawaited(_confirmOutage());
  }

  Future<void> _confirmOutage() async {
    await _probeOnce();
    if (_reachable && _failedProbes > 0) {
      await _probeOnce();
    }
    _rearmPollingIfStateChanged();
  }

  /// Snapshot de diagnostico para la UI de troubleshooting.
  ConnectivityDiagnostics get diagnostics => ConnectivityDiagnostics(
        adapterUp: _adapterUp,
        reachable: _reachable,
        failedProbes: _failedProbes,
        supabaseUrl: Env.supabaseUrl,
        lastProbeAt: _lastProbeAt,
        lastProbeUrl: _lastProbeUrl,
        lastProbeStatus: _lastProbeStatus,
        lastProbeError: _lastProbeError,
        lastProbeDuration: _lastProbeDuration,
      );

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
      unawaited(_probeOnce().then((_) => _rearmPollingIfStateChanged()));
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
  ///
  /// Estrategia: probamos varios endpoints en orden y aceptamos cualquier
  /// respuesta HTTP < 500 como "alcanzable". El razonamiento: el solo
  /// hecho de recibir respuesta (incluso 401 "no auth" o 404 "ruta no
  /// existe") prueba que la red llego al server. Antes el probe pedia
  /// status 2xx/3xx exactos contra /auth/v1/health — si ese path estaba
  /// bloqueado por el proxy o requeria auth, el cajero se quedaba
  /// "offline" indefinidamente aunque el resto del Supabase respondiera.
  Future<void> _probeReachability({bool emit = false}) async {
    if (!_adapterUp) {
      _reachable = false;
      _lastProbeAt = DateTime.now();
      _lastProbeUrl = null;
      _lastProbeStatus = null;
      _lastProbeError = 'adapter down';
      _lastProbeDuration = null;
      return;
    }

    final wasConnected = isConnected;
    final base = Env.supabaseUrl;
    String? lastReason;
    String? lastUrl;
    int? lastStatus;
    bool reached = false;
    final stopwatch = Stopwatch()..start();

    for (final path in _probePaths) {
      final url = '$base$path';
      lastUrl = url;
      try {
        final response = await http.get(Uri.parse(url)).timeout(_probeTimeout);
        lastStatus = response.statusCode;
        // 5xx == server respondio pero esta roto → NO contamos como
        // alcanzable (siguiente probe path puede estar OK).
        if (response.statusCode < 500) {
          reached = true;
          break;
        }
        lastReason = 'status ${response.statusCode} en $path';
      } on TimeoutException {
        lastStatus = null;
        lastReason = 'timeout en $path';
        // Los tres paths son del mismo host: si no contestó uno, los otros
        // tampoco. Probarlos igual triplicaba lo que tarda detectar la caída.
        break;
      } catch (e) {
        lastStatus = null;
        lastReason = 'error en $path: $e';
        if (_isHostUnreachable(e)) break;
      }
    }
    stopwatch.stop();

    _lastProbeAt = DateTime.now();
    _lastProbeUrl = lastUrl;
    _lastProbeStatus = lastStatus;
    _lastProbeError = reached ? null : lastReason;
    _lastProbeDuration = stopwatch.elapsed;

    if (reached) {
      _failedProbes = 0;
      _lastHttpProbeFailedAt = null;
      if (!_reachable) {
        _reachable = true;
        debugPrint('Supabase reachable again');
      }
    } else {
      _markProbeFailure(lastReason ?? 'unknown');
    }

    if (emit && wasConnected != isConnected) {
      _emitCombined();
    }
  }

  /// Errores de sondeo que valen para el HOST entero, no para un path.
  static bool _isHostUnreachable(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('failed host lookup') ||
        msg.contains('network is unreachable') ||
        msg.contains('no route to host') ||
        msg.contains('connection timed out');
  }

  void _markProbeFailure(String reason) {
    _failedProbes++;
    _lastHttpProbeFailedAt = DateTime.now();
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
    // Polling adaptativo: cuando estamos sin red, polleamos cada 5s para
    // recuperar al toque. Cuando estamos OK, cada 30s (el background load
    // es minimo). Si el estado cambia, _reschedulePolling() se re-arma.
    final interval = _reachable ? _probeInterval : _probeIntervalFast;
    _pollingArmedReachable = _reachable;
    _reachabilityTimer = Timer.periodic(interval, (_) async {
      if (!_adapterUp) return;
      await _probeOnce();
      // Primer fallo sin llegar al umbral: confirmar en segundos, no en 30s.
      if (_reachable && _failedProbes > 0) _scheduleConfirmProbe();
      _rearmPollingIfStateChanged();
    });
  }

  /// Con qué estado se armó el timer: si cambió, hay que re-armarlo con la
  /// cadencia correcta (fast↔normal) sin esperar al siguiente tick.
  bool _pollingArmedReachable = true;

  void _rearmPollingIfStateChanged() {
    if (_reachabilityTimer == null) return;
    if (_pollingArmedReachable != _reachable) _startReachabilityPolling();
  }

  void _scheduleConfirmProbe() {
    if (_confirmProbeTimer?.isActive ?? false) return;
    _confirmProbeTimer = Timer(_confirmProbeDelay, () async {
      if (!_adapterUp || !_reachable || _failedProbes == 0) return;
      await _probeOnce();
      _rearmPollingIfStateChanged();
    });
  }

  /// Un solo sondeo a la vez: quien llegue mientras hay uno en curso espera
  /// ese mismo resultado.
  Future<void> _probeOnce() {
    return _inFlightProbe ??= _probeReachability(emit: true)
        .whenComplete(() => _inFlightProbe = null);
  }

  /// Forzar un check ad-hoc. Útil cuando un viewmodel acaba de fallar una
  /// llamada y quiere re-validar el estado sin esperar al próximo poll.
  Future<bool> forceReachabilityCheck() async {
    await _probeOnce();
    _rearmPollingIfStateChanged();
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
    _confirmProbeTimer?.cancel();
    _subscription?.cancel();
    _connectionController.close();
  }
}
