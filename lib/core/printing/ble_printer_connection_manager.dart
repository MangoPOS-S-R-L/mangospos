import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'android_printer_foreground_service.dart';
import 'ble_print_job_queue.dart';
import 'classic_bluetooth.dart';
import 'printer_link.dart';

/// Estado de la conexión a una impresora (PRD BT — modelo de estados). El
/// nombre conserva el prefijo `Ble` por compatibilidad histórica, pero aplica
/// a ambos transportes (BLE/GATT y Classic/RFCOMM).
enum BleConnState { idle, connecting, connected, reconnecting }

/// Resultado de [BlePrinterConnectionManager.printOrEnqueue].
enum BlePrintResult {
  /// Se escribió a la impresora sobre la conexión viva.
  printed,

  /// La impresora no está conectada ahora mismo; el job quedó encolado y se
  /// vaciará en orden al reconectar. El caller debe tratarlo como aceptado
  /// (NO caer al fallback de cloud: el manager es dueño del reintento).
  queued,

  /// No se pudo aceptar el job (caso muy raro: identificador vacío).
  failed,
}

/// Mantiene conexiones **persistentes** a impresoras térmicas y las
/// auto-recupera, igualando el comportamiento "siempre conectado" de Loyverse
/// (PRD BT — Fases 1 y 2 + transporte Classic).
///
/// Es agnóstico al transporte: cada impresora se conecta por [PrinterLink]
/// (BLE/GATT o Classic/RFCOMM), elegido automáticamente — Classic si el equipo
/// lo expone (más rápido / única vía para Classic-only), BLE si no. El manager
/// se encarga de:
///   - conectar y reusar el enlace vivo entre tickets,
///   - detectar caídas y reconectar con backoff exponencial+jitter,
///   - encolar jobs durante la desconexión y vaciarlos en orden al reconectar,
///   - un heartbeat pasivo para detectar caídas silenciosas.
///
/// Persistencia del proceso:
///   - Android: Foreground Service ([AndroidPrinterForegroundService]).
///   - iOS (Tier A): reconexión al volver a foreground (no hay equivalente al
///     FGS; iOS no permite sostener el enlace con la app en background).
///
/// Singleton: la capa de dispatch ([PrintingService]) y la UI comparten la
/// misma instancia vía [instance].
class BlePrinterConnectionManager with WidgetsBindingObserver {
  BlePrinterConnectionManager._();

  static final BlePrinterConnectionManager instance =
      BlePrinterConnectionManager._();

  // ── Parámetros de reconexión ──────────────────────────────────────────────
  static const Duration _connectTimeout = Duration(seconds: 12);
  static const Duration _backoffBase = Duration(milliseconds: 500);
  static const Duration _backoffCap = Duration(seconds: 30);
  static const Duration _heartbeatPeriod = Duration(seconds: 25);

  final BlePrintJobQueue _queue = BlePrintJobQueue();
  final Map<String, _PrinterConnection> _conns = {};
  final Set<String> _desired = {};
  final Set<String> _creating = {};
  final math.Random _rng = math.Random();

  final StreamController<Map<String, BleConnState>> _stateController =
      StreamController<Map<String, BleConnState>>.broadcast();
  Timer? _heartbeat;
  bool _initialized = false;
  bool _observerAttached = false;

  /// Snapshot actual `address → estado` para lecturas síncronas (UI inicial).
  Map<String, BleConnState> get states =>
      {for (final e in _conns.entries) e.key: e.value.state};

  /// Stream de snapshots del estado de todas las conexiones (observabilidad UI).
  Stream<Map<String, BleConnState>> get stateStream => _stateController.stream;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;
    await _queue.load();
  }

  // ── API pública ────────────────────────────────────────────────────────────

  /// Declara el conjunto de impresoras que deben permanecer conectadas
  /// (típicamente las impresoras BT activas del negocio). Crea/derriba
  /// conexiones y arranca/detiene el Foreground Service (PRD BT — F1.4: no
  /// corre en vacío).
  Future<void> setDesiredPrinters(Iterable<String> addresses) async {
    await _ensureInit();
    final desired = addresses
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    _desired
      ..clear()
      ..addAll(desired);

    // Derribar conexiones que ya no se desean.
    for (final id in _conns.keys.toList()) {
      if (!desired.contains(id)) {
        await _teardown(id);
      }
    }
    // Asegurar conexión a las deseadas.
    for (final id in desired) {
      await _ensureConnection(id);
    }

    _ensureObserver();
    await _syncForegroundService();
    _ensureHeartbeat();
    _emitState();
  }

  /// Imprime [data] a la impresora [address] sobre la conexión persistente, o
  /// la encola si está reconectando. [jobId] es la clave de idempotencia
  /// (estable por ticket+impresora) para no duplicar papel ante reintentos.
  Future<BlePrintResult> printOrEnqueue({
    required String address,
    required List<int> data,
    required String jobId,
  }) async {
    await _ensureInit();
    final id = address.trim();
    if (id.isEmpty) return BlePrintResult.failed;

    // Asegura conexión viva (y la marca como deseada para que la cubra el FGS
    // y no la derribe el próximo heartbeat).
    _desired.add(id);
    await _ensureConnection(id);
    _ensureObserver();
    await _syncForegroundService();
    _ensureHeartbeat();

    // Durabilidad uniforme: persistimos el job y luego intentamos vaciar. Si la
    // conexión está viva, el flush lo escribe ~de inmediato y lo quita; si no,
    // queda encolado para el reconnect.
    await _queue.enqueue(BlePrintJob(
      jobId: jobId,
      remoteId: id,
      data: data,
      enqueuedAt: DateTime.now(),
    ));

    final conn = _conns[id];
    if (conn != null && conn.state == BleConnState.connected) {
      await _flush(conn);
    }
    return _queue.contains(jobId)
        ? BlePrintResult.queued
        : BlePrintResult.printed;
  }

  /// Apaga todo (logout / shutdown). NO borra la cola persistida.
  Future<void> shutdown() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _desired.clear();
    for (final id in _conns.keys.toList()) {
      await _teardown(id);
    }
    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAttached = false;
    }
    await _syncForegroundService();
    _emitState();
  }

  // ── Ciclo de vida de una conexión ───────────────────────────────────────────

  Future<void> _ensureConnection(String address) async {
    // Ya existe: solo asegura que esté intentando conectar si está idle.
    final existing = _conns[address];
    if (existing != null) {
      if (existing.state == BleConnState.idle) _connect(existing);
      return;
    }
    if (_creating.contains(address)) return; // creación en curso
    _creating.add(address);
    try {
      final link = await _createLink(address);
      // ¿Sigue deseada tras el await? (pudo derribarse mientras tanto)
      if (!_desired.contains(address)) {
        await link.dispose();
        return;
      }
      final conn = _PrinterConnection(address, link);
      _conns[address] = conn;
      // Una sola suscripción al estado del enlace: cualquier caída (incluida
      // una a nivel de OS / IOException del socket) dispara la reconexión.
      conn.linkSub = link.connectionEvents.listen((connected) {
        if (connected) return;
        if (conn.state == BleConnState.connected ||
            conn.state == BleConnState.connecting) {
          _scheduleReconnect(conn);
        }
      });
      _connect(conn);
    } finally {
      _creating.remove(address);
    }
  }

  /// Elige el transporte: Classic si el equipo está pareado y expone SPP (más
  /// rápido / única vía para Classic-only), BLE en caso contrario.
  Future<PrinterLink> _createLink(String address) async {
    if (ClassicBluetooth.isSupportedPlatform &&
        await ClassicBluetooth.isBondedSpp(address)) {
      debugPrint('[PrinterMgr] $address → transporte Classic/RFCOMM');
      return ClassicLink(address);
    }
    return BleLink(address);
  }

  Future<void> _connect(_PrinterConnection conn) async {
    if (conn.state == BleConnState.connecting) return;
    _setState(conn, BleConnState.connecting);
    try {
      await conn.link.connect(timeout: _connectTimeout);
      conn.resetBackoff();
      _setState(conn, BleConnState.connected);
      debugPrint('[PrinterMgr] ${conn.address} conectada (${conn.link.kind.name})');
      await _flush(conn);
    } catch (e) {
      debugPrint('[PrinterMgr] connect ${conn.address} falló: $e');
      _scheduleReconnect(conn);
    }
  }

  void _scheduleReconnect(_PrinterConnection conn) {
    conn.reconnectTimer?.cancel();
    if (!_conns.containsKey(conn.address)) return; // ya no se desea
    _setState(conn, BleConnState.reconnecting);

    // Backoff exponencial 0.5s → 1s → 2s … tope 30s, + jitter (±25%) para no
    // sincronizar reintentos de varias cajas contra la misma impresora.
    final exp = math.min(
      _backoffCap.inMilliseconds,
      _backoffBase.inMilliseconds * math.pow(2, conn.backoffStep).toInt(),
    );
    final jitter = (exp * 0.25 * (_rng.nextDouble() * 2 - 1)).round();
    final delay = Duration(milliseconds: math.max(250, exp + jitter));
    conn.backoffStep++;

    debugPrint(
        '[PrinterMgr] ${conn.address} reconnect en ${delay.inMilliseconds}ms');
    conn.reconnectTimer = Timer(delay, () {
      if (_conns.containsKey(conn.address)) _connect(conn);
    });
  }

  Future<void> _teardown(String address) async {
    final conn = _conns.remove(address);
    if (conn == null) return;
    conn.reconnectTimer?.cancel();
    await conn.linkSub?.cancel();
    await conn.link.disconnect();
    await conn.link.dispose();
  }

  // ── Vaciado de la cola ───────────────────────────────────────────────────────

  /// Escribe en orden todos los jobs encolados para la impresora de [conn].
  /// Reentrante-seguro: si ya hay un flush corriendo, retorna (el que corre
  /// re-lee la cola y recoge los jobs nuevos).
  Future<void> _flush(_PrinterConnection conn) async {
    if (conn.flushing) return;
    if (conn.state != BleConnState.connected) return;
    conn.flushing = true;
    try {
      while (true) {
        final jobs = _queue.jobsFor(conn.address);
        if (jobs.isEmpty) break;
        final job = jobs.first;
        try {
          await conn.link.write(job.data);
          await _queue.remove(job.jobId);
        } catch (e) {
          debugPrint('[PrinterMgr] write ${conn.address} falló: $e');
          // Probable caída del enlace → marca intento y deja que el evento de
          // conexión dispare la reconexión. Si el job superó el tope de
          // intentos se descarta (no bloquea la cabeza de la cola).
          final dropped = await _queue.markFailedAttempt(job.jobId);
          if (!dropped) break; // head-of-line: reintenta tras reconectar.
        }
      }
    } finally {
      conn.flushing = false;
    }
  }

  // ── Heartbeat (F2.4) ──────────────────────────────────────────────────────

  void _ensureHeartbeat() {
    if (_heartbeat != null || _conns.isEmpty) return;
    _heartbeat = Timer.periodic(_heartbeatPeriod, (_) => _heartbeatTick());
  }

  /// Chequeo pasivo: si el estado dice "connected" pero el enlace ya no lo está
  /// (caída silenciosa que el stream no reportó), fuerza reconexión. No escribe
  /// a la impresora para no arriesgar papel/garbage.
  void _heartbeatTick() {
    if (_conns.isEmpty) {
      _heartbeat?.cancel();
      _heartbeat = null;
      return;
    }
    for (final conn in _conns.values) {
      if (conn.state == BleConnState.connected && !conn.link.isConnected) {
        debugPrint('[PrinterMgr] heartbeat: ${conn.address} caída silenciosa');
        _scheduleReconnect(conn);
      }
    }
  }

  // ── iOS Tier A: reconexión al volver a foreground ──────────────────────────

  void _ensureObserver() {
    if (_observerAttached || _conns.isEmpty) return;
    // Solo iOS necesita esto: no hay Foreground Service y los enlaces se
    // suspenden en background. Android los cubre el FGS; macOS/Windows no
    // aplican aquí.
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    WidgetsBinding.instance.addObserver(this);
    _observerAttached = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    // Al volver a foreground, reconecta lo que se haya caído mientras la app
    // estuvo suspendida.
    for (final conn in _conns.values) {
      if (conn.state != BleConnState.connected && !conn.link.isConnected) {
        _connect(conn);
      }
    }
  }

  // ── Estado / FGS ──────────────────────────────────────────────────────────

  void _setState(_PrinterConnection conn, BleConnState s) {
    if (conn.state == s) return;
    conn.state = s;
    _emitState();
  }

  void _emitState() {
    if (_stateController.isClosed) return;
    _stateController.add(states);
  }

  Future<void> _syncForegroundService() async {
    if (_conns.isNotEmpty) {
      await AndroidPrinterForegroundService.start();
    } else {
      await AndroidPrinterForegroundService.stop();
    }
  }
}

/// Estado interno mutable de una conexión a una impresora.
class _PrinterConnection {
  _PrinterConnection(this.address, this.link);

  final String address;
  final PrinterLink link;

  BleConnState state = BleConnState.idle;
  bool flushing = false;

  StreamSubscription<bool>? linkSub;
  Timer? reconnectTimer;
  int backoffStep = 0;

  void resetBackoff() => backoffStep = 0;
}
