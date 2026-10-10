import 'dart:async';
import 'dart:convert';
import 'order_item_snapshot.dart';
import 'payment_intent_journal.dart';
import 'pending_kitchen_prints.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:mangopos/core/offline/storage/offline_queue_dao.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/offline/hub/hub_client.dart';
import 'package:mangopos/core/offline/hub/hub_lease_service.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_op_log.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
import 'package:mangopos/core/offline/hub/hub_projection_cache.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/core/security/secure_blob_cipher.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class OfflineQueueSyncResult {
  const OfflineQueueSyncResult({
    this.processed = 0,
    this.completed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.pending = 0,
    this.dead = 0,
    this.reconciled = 0,
    this.lastMappedOrderId,
    this.lastError,
    this.conflicts = const <OfflineSyncConflict>[],
    this.leaseLostToDeviceId,
  });

  final int processed;
  final int completed;
  final int failed;
  final int skipped;
  final int pending;

  /// Acciones que ya estaban en el servidor (marcador de idempotencia) y en
  /// esta pasada solo se marcaron completed. No cuentan en [completed], pero
  /// sí cambian la cola: la venta activa puede recargarse.
  final int reconciled;

  /// Acciones que agotaron sus reintentos (>= [OfflinePosService.maxAttempts])
  /// y pasaron a estado `dead`. Ya NO reintentan solas; requieren acción
  /// manual del cajero (reintentar o descartar desde el visor de la cola).
  final int dead;
  final String? lastMappedOrderId;
  final String? lastError;

  /// Acciones que sincronizaron OK pero descubrieron un conflicto con otro
  /// terminal: un item ya borrado, un modificador que ya no existe, un
  /// update sobre un item desaparecido, etc. La accion se marca como
  /// completed (no reintenta) pero el cashier debe saberlo.
  final List<OfflineSyncConflict> conflicts;

  /// H7: no-null cuando este equipo intentó subir el op-log del Hub y la lease
  /// la tenía OTRO equipo (un respaldo promovido). No subió y dejó de ser el
  /// Hub. Trae el id del equipo que tiene la lease ('' si no se supo).
  final String? leaseLostToDeviceId;

  bool get didWork => processed > 0;
  bool get hasFailures => failed > 0;
  bool get hasConflicts => conflicts.isNotEmpty;
  bool get hasDead => dead > 0;
}

/// Descripcion de un conflicto encontrado durante el sync. Se acumulan
/// en [OfflineQueueSyncResult.conflicts] para que la UI los muestre.
class OfflineSyncConflict {
  const OfflineSyncConflict({
    required this.actionType,
    required this.reason,
    this.actionId,
  });

  final String actionType;
  final String? actionId;
  final String reason;
}

/// Marker exception lanzado desde [_replayAction] cuando una accion ya
/// no aplica (item borrado por otro terminal, etc). El loop principal
/// lo captura, marca la accion como completed (idempotente), agrega un
/// [OfflineSyncConflict] al resultado y continua con la siguiente.
class _OfflineSyncSkip implements Exception {
  _OfflineSyncSkip(this.reason);
  final String reason;
  @override
  String toString() => 'OfflineSyncSkip: $reason';
}

/// Comanda impresa por la LAN que todavía no se puede confirmar en cocina
/// solo con sus líneas (20261010_0002). La acción se conserva y NO bloquea las
/// demás acciones de su orden (marca `kitchen_hold`): el alta que trae el
/// mapeo que falta, o un cobro, pueden ir detrás.
/// - [countsAttempt] false: espera sin gastar intentos (el alta de la línea
///   sigue en la cola, o falta la migración en el servidor).
/// - [terminal]: no se resuelve sola (acción de una versión anterior sin sus
///   ids): pasa directo a dead-letter para recuperarla a mano.
class _KitchenRoundHold implements Exception {
  const _KitchenRoundHold(
    this.message, {
    this.countsAttempt = true,
    this.terminal = false,
  });
  final String message;
  final bool countsAttempt;
  final bool terminal;
  @override
  String toString() => message;
}

/// Qué hace la pasada a la nube con una acción de la cola. Lo decide
/// [OfflinePosService._replayGate], la única fuente de esas reglas.
enum _ReplayGate {
  /// Ya completada: nunca se reprocesa.
  completed,

  /// Entregada (o a medio entregar) al Hub: solo el Hub la reenvía.
  hubOwned,

  /// Dead-letter en una pasada sin force.
  dead,

  /// Ya figura subida (marcador de idempotencia): solo se marca completed.
  reconcile,

  /// Falló y su backoff no ha vencido (pasada sin force).
  waitingRetry,

  /// Su orden quedó detenida por una acción anterior en esta pasada.
  blockedBehind,

  /// Se reenvía al servidor.
  replay,
}

/// Delta de KPIs del día calculado SOLO a partir de operaciones offline aún
/// no sincronizadas (cola local). Se suma sobre el último snapshot
/// sincronizado para mostrar el dashboard correcto sin conexión.
class OfflineKpiDelta {
  final double income;
  final double itemsSold;
  final int ordersTotal;
  final int ordersInProgress;
  final int ordersCompleted;

  const OfflineKpiDelta({
    required this.income,
    required this.itemsSold,
    required this.ordersTotal,
    required this.ordersInProgress,
    required this.ordersCompleted,
  });

  static const empty = OfflineKpiDelta(
    income: 0,
    itemsSold: 0,
    ordersTotal: 0,
    ordersInProgress: 0,
    ordersCompleted: 0,
  );

  bool get isEmpty =>
      income == 0 &&
      itemsSold == 0 &&
      ordersTotal == 0 &&
      ordersInProgress == 0 &&
      ordersCompleted == 0;
}

class OfflinePosService {
  OfflinePosService._();

  static final OfflinePosService _instance = OfflinePosService._();
  static const Uuid _uuid = Uuid();
  static const String _statusPending = 'pending';
  static const String _statusProcessing = 'processing';
  static const String _statusCompleted = 'completed';
  static const String _statusFailed = 'failed';

  /// Estado terminal para acciones que agotaron sus reintentos. No vuelven
  /// a procesarse en el sync automático; el cajero las gestiona a mano
  /// (reintentar o descartar). Evita que una acción imposible (constraint
  /// incumplible, recurso borrado en server) reintente para siempre y deje
  /// el badge de pendientes pegado.
  static const String _statusDead = 'dead';

  /// Tope de intentos antes de mandar una acción a dead-letter. Con el
  /// backoff actual (3s, 8s, 15s, 30s, …) 8 intentos ≈ varios minutos de
  /// reintentos antes de rendirse — suficiente para superar caídas
  /// transitorias sin quedar atascado en un error permanente.
  static const int maxAttempts = 8;

  factory OfflinePosService() => _instance;

  /// Heuristica para detectar "item ya no existe" durante el sync. Se
  /// dispara cuando otro terminal borro el mismo item mientras estabamos
  /// offline. El delete del cajero offline ya no aplica (idempotente —
  /// el estado deseado, item ausente, ya se cumple); los updates sobre
  /// ese item se reportan como conflicto visible al cashier.
  static bool _isItemMissingError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('pgrst116') ||
        msg.contains('no rows') ||
        msg.contains('not found');
  }

  /// Heuristica para distinguir errores de conectividad (donde NO tiene
  /// sentido seguir intentando — todas las acciones siguientes fallaran
  /// por la misma razon) de errores logicos (constraint violation, item
  /// ya borrado, RPC validation, etc — esos deben saltarse para no
  /// bloquear el resto de la cola; quedaron marcados con backoff
  /// individual y reintentaran solos).
  static bool _isConnectivityError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('clientexception') ||
        msg.contains('timeoutexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('connection refused') ||
        msg.contains('connection closed') ||
        msg.contains('connection reset') ||
        msg.contains('network is unreachable') ||
        msg.contains('software caused connection abort') ||
        msg.contains('handshake') ||
        // AuthRetryableFetchException: supabase-flutter no pudo refrescar
        // la sesión por red. Es transitorio — no debe contar contra el
        // tope de reintentos ni mandar la acción a dead-letter.
        msg.contains('retryablefetch');
  }

  /// Público: expone la clasificación de errores de TRANSPORTE (red) para que
  /// los viewmodels decidan encolar offline aunque `ConnectivityService`
  /// todavía reporte `isConnected == true` (va 1-2 sondeos atrás — la ventana
  /// "conectado pero malo"). NO clasifica errores de negocio del RPC (RAISE,
  /// constraint, validación) como transporte, así que esos siguen
  /// mostrándose al usuario en vez de encolarse a ciegas.
  static bool isTransportError(Object e) => _isConnectivityError(e);

  /// PGRST202: el servidor todavía no tiene la función del RPC (la app se
  /// publicó antes que su migración, p. ej. `fn_open_offline_sale` de
  /// 20261009_0004). No es culpa de la acción: no cuenta para el dead-letter
  /// y se reintenta con backoff, así se sube sola cuando llegue la migración.
  /// Tampoco corta la pasada: el resto de la cola no depende de esa función.
  /// Los repositorios que convierten ese PGRST202 en «Falta aplicar la
  /// migración …» (alta idempotente de ítems, candado de cobros) cuentan igual.
  static bool _isMissingRpcError(Object e) {
    final msg = e.toString();
    return msg.contains('PGRST202') ||
        msg.toLowerCase().contains('falta aplicar la migración');
  }

  /// client_op_id del alta de ítem (20260929_0001). Las acciones nuevas lo
  /// traen desde el toque: es el mismo que usó el intento online o el proxy
  /// del Hub. Las encoladas por builds anteriores no lo tienen: se deriva uno
  /// DETERMINISTA del id de la acción, así dos replays de la misma acción (la
  /// app murió entre la RPC y el guardado del mapping) no crean dos ítems.
  static String addItemClientOpId(Map<String, dynamic> action) {
    final explicit = action['client_op_id']?.toString();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final actionId = action['op_id'] ?? action['id'];
    return _uuid.v5(Namespace.url.value, 'mangopos:add_item:$actionId');
  }

  Future<StorageService> get _storage async => StorageService.getInstance();

  /// Cifrado en reposo para snapshots de órdenes (datos sensibles: montos,
  /// items, cliente). Migración perezosa de valores legacy en texto plano.
  final SecureBlobCipher _cipher = SecureBlobCipher.instance;

  /// Seam del Hub Local (F3b-3). Cuando el terminal está en modo `hub`,
  /// `HubModeController` setea este uploader (un closure que hace
  /// `HubClient.postOp` contra el Hub alcanzable). Si está seteado,
  /// `enqueueAction` persiste primero en la cola local y dispara el reenvio
  /// al Hub. Sin confirmacion conserva el mismo ID para el siguiente intento.
  /// Null en modo cloud/solo desactiva el reenvio por LAN.
  Future<int?> Function(String businessId, Map<String, dynamic> op)?
  _hubUploader;

  /// Op-log del Hub (F3b-3b). Cuando ESTE dispositivo es el Hub, el uplink
  /// drena este log a Supabase. Misma key/SP que el agente, así que comparten
  /// el mismo registro.
  final HubOpLog _hubOpLog = HubOpLog();
  final HubLeaseService _hubLease = HubLeaseService();
  final Map<String, Future<OfflineQueueSyncResult>> _hubUplinkInFlight = {};
  final Map<String, Future<OfflineQueueSyncResult>> _queueSyncInFlight = {};
  final Map<String, Future<void>> _queueMutations = {};
  final Map<String, Future<void>> _snapshotMutations = {};

  Future<T> _withSnapshotMutation<T>(String key, Future<T> Function() fn) {
    final previous = _snapshotMutations[key] ?? Future<void>.value();
    final run = previous.then((_) => fn());
    final settled = run.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _snapshotMutations[key] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_snapshotMutations[key], settled)) {
          _snapshotMutations.remove(key);
        }
      }),
    );
    return run;
  }

  // Solo serializa escrituras locales breves. Nunca mantener este candado
  // durante un RPC: el cajero debe poder seguir agregando mientras hay sync.
  Future<T> _withQueueMutation<T>(String businessId, Future<T> Function() fn) {
    final previous = _queueMutations[businessId] ?? Future<void>.value();
    final run = previous.then((_) => fn());
    final settled = run.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queueMutations[businessId] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_queueMutations[businessId], settled)) {
          _queueMutations.remove(businessId);
        }
      }),
    );
    return run;
  }

  DateTime? _lastBackupAckAt;
  static const Duration _backupAckEvery = Duration(seconds: 60);

  /// Activa/desactiva el enrutado al Hub. Lo llama HubModeController según el
  /// modo. Pasar null vuelve al encolado local puro.
  void setHubUploader(
    Future<int?> Function(String businessId, Map<String, dynamic> op)? uploader,
  ) {
    _hubUploader = uploader;
  }

  /// Difusor por WS que registra el agente en-proceso (mobile_print_agent) al
  /// arrancar. Cuando el HOST agrega una op a su op-log local, la difunde a los
  /// clientes suscritos igual que las que llegan por POST /hub/ops → las cajas
  /// cliente ven en vivo también las mesas que abre el propio Hub.
  void Function(String businessId, Map<String, dynamic> opWithSeq)?
  _hubBroadcaster;

  void setHubBroadcaster(
    void Function(String businessId, Map<String, dynamic> opWithSeq)? cb,
  ) {
    _hubBroadcaster = cb;
  }

  /// H4: cuando ESTE dispositivo es el Hub (hubHost), sus propias mutaciones se
  /// escriben directo al op-log local compartido (el mismo que sirve el
  /// servidor en-proceso vía /hub/salon y que drena `syncHubOpLog`) y se
  /// difunden por WS (broadcaster). Es el uploader que HubModeController cablea
  /// en modo hubHost. Devuelve el `seq` asignado, o null si falla (el caller
  /// cae a la cola local).
  Future<int?> appendToLocalHubOpLog(
    String businessId,
    Map<String, dynamic> op,
  ) async {
    try {
      final seq = await _hubOpLog.append(businessId, op);
      // H7: espejar al respaldo. La op ya quedó guardada aquí, así que esto es
      // pura red de seguridad — si el respaldo no está o no responde, el Hub
      // sigue igual. Fire-and-forget para no meter latencia de red en el
      // camino del cajero.
      unawaited(_replicateToBackup(businessId, {...op, 'seq': seq}));
      try {
        _hubBroadcaster?.call(businessId, {...op, 'seq': seq});
      } catch (_) {
        // El broadcast es best-effort; el op ya quedó persistido.
      }
      return seq;
    } catch (_) {
      return null;
    }
  }

  /// Manda una op ya aplicada al Hub de respaldo configurado, si lo hay.
  ///
  /// Conserva una segunda copia activa del log. La outbox del terminal retiene
  /// su confirmacion, pero no es una autoridad de recuperacion del Hub.
  ///
  /// El respaldo GUARDA pero no sube nada mientras esté pasivo, así que el
  /// uplink sigue teniendo un solo dueño. Eso es lo que hace segura la
  /// replicación: la idempotencia de este sistema es por dispositivo y la BD no
  /// tiene llave de idempotencia, así que dos equipos subiendo la misma op
  /// harían venta doble e inventario doble.
  Future<void> _replicateToBackup(
    String businessId,
    Map<String, dynamic> op,
  ) async {
    try {
      final backupUrl = await HubConfigService().getBackupUrl(businessId);
      if (backupUrl == null || backupUrl.isEmpty) return;
      await HubClient().replicateOp(backupUrl, {
        ...op,
        'business_id': businessId,
      });
    } catch (_) {
      // Best-effort: el espejo nunca puede afectar la operación del local.
    }
  }

  /// Fix #1 (F3 hardening): cuando ESTE equipo es el Hub host y aplica una
  /// mutación ONLINE (que YA escribió a Supabase por el flujo normal), la
  /// espeja al op-log local SOLO para que las cajas cliente la VEAN por la LAN
  /// (`/hub/salon`, `/hub/order`). Antes el host saltaba el op-log al estar
  /// online → las mesas que abría eran invisibles para los clientes.
  ///
  /// La op se marca `hub_applied: true`: el uplink la PROYECTA pero NUNCA la
  /// vuelve a subir a Supabase (evita doble escritura). Se normaliza para que
  /// lleve `id`/`fingerprint` (dedup). Best-effort: nunca lanza — el espejo al
  /// Hub jamás debe afectar la mutación real del cajero.
  Future<void> publishHostOp(String businessId, Map<String, dynamic> op) async {
    try {
      final normalized = _normalizeAction({...op, 'hub_applied': true});
      await appendToLocalHubOpLog(businessId, normalized);
    } catch (_) {
      // best-effort: el espejo LAN no bloquea ni rompe la caja.
    }
  }

  /// H4: proyecta el salón desde el op-log LOCAL (cuando ESTE equipo es el
  /// Hub). Devuelve la lista de mesas ocupadas con el mismo shape que el
  /// endpoint `/hub/salon`, para que el grid del propio Hub no necesite un
  /// round-trip HTTP a sí mismo. Best-effort: lista vacía ante error.
  Future<List<Map<String, dynamic>>> localHubSalon(String businessId) async {
    try {
      // Memoizado por revisión del op-log (ver [HubProjectionCache]): el
      // host re-proyectaba el log entero en cada refresco de su propio grid.
      return await HubProjectionCache.instance.salon(businessId);
    } catch (_) {
      return const [];
    }
  }

  /// H6: devuelve el op-log LOCAL completo (cuando ESTE equipo es el Hub) para
  /// que el KDS lo proyecte con HubKitchenProjector sin un round-trip HTTP a sí
  /// mismo. Best-effort: lista vacía ante error.
  Future<List<Map<String, dynamic>>> getLocalHubOps(String businessId) async {
    try {
      return await HubProjectionCache.instance.ops(businessId);
    } catch (_) {
      return const [];
    }
  }

  /// H4 m2: proyecta el DETALLE de una orden desde el op-log LOCAL (cuando ESTE
  /// equipo es el Hub) por table_id u order_id. Mismo shape que `/hub/order`.
  /// null si no hay una orden abierta que coincida. Best-effort.
  Future<Map<String, dynamic>?> localHubOrder(
    String businessId, {
    String? tableId,
    String? orderId,
  }) async {
    try {
      final ops = await HubProjectionCache.instance.ops(businessId);
      final order = HubOrderProjector.projectOrder(
        ops,
        tableId: tableId,
        orderId: orderId,
      );
      return order?.toJson();
    } catch (_) {
      return null;
    }
  }

  /// DAO de drift/sqlite para cola + completed_ops + fingerprints.
  /// El resto del cache (snapshots, mappings, catalog, inventory) sigue
  /// en SharedPreferences vía [_storage] — es alcance de Fase 6 solo
  /// migrar lo que tiene problema real de volumen.
  ///
  /// En web es `null`: drift requiere `dart:ffi` que no existe en JS.
  /// Las funciones que tocaban el DAO tienen un guard `kIsWeb` que cae
  /// al path SharedPreferences (volumen aceptable en cajeros web).
  late final OfflineQueueDao? _queueDao = kIsWeb
      ? null
      : OfflineQueueDao(OfflineQueueDb.getInstance());

  /// Guard one-time POR BUSINESS: la primera vez que se toca la cola
  /// tras actualizar la app, importamos lo que haya en SharedPreferences
  /// a sqlite y borramos las SP keys legacy. Necesita ser per-business
  /// porque un owner de varias sucursales tendría las cola legacy
  /// distintas en cada SP key — si lo memoizáramos global, la segunda
  /// sucursal saltaría la migración al cambiar de business y perdería
  /// su cola pendiente.
  final Set<String> _migratedBusinesses = <String>{};
  Future<void> _ensureMigratedFromSp(String businessId) async {
    // En web no hay drift → no hay migración hacia sqlite que hacer.
    // El path web siempre usa SharedPreferences directamente.
    if (kIsWeb) return;
    if (_migratedBusinesses.contains(businessId)) return;
    _migratedBusinesses.add(businessId);
    try {
      final storage = await _storage;
      final legacyQueue =
          await storage.readList(_queueKey(businessId)) ?? const [];
      final legacyOps =
          await storage.readList(_completedOpsKey(businessId)) ?? const [];
      final legacyFps =
          await storage.readList(_completedFingerprintsKey(businessId)) ??
          const [];
      if (legacyQueue.isEmpty && legacyOps.isEmpty && legacyFps.isEmpty) {
        return;
      }
      final queueMaps = legacyQueue
          .whereType<Object?>()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      if (queueMaps.isNotEmpty) {
        await _queueDao!.writeQueue(businessId, queueMaps);
        _bumpQueueRevision(businessId);
      }
      for (final id in legacyOps.map((e) => e.toString())) {
        if (id.isEmpty) continue;
        await _queueDao!.markOpCompleted(businessId: businessId, opId: id);
      }
      for (final fp in legacyFps.map((e) => e.toString())) {
        if (fp.isEmpty) continue;
        await _queueDao!.markFingerprintCompleted(
          businessId: businessId,
          fingerprint: fp,
        );
      }
      // Borramos las claves legacy para que no se queden duplicadas y
      // ocupen espacio. Si la app revierte a una versión vieja, el
      // cajero pierde la cola pendiente — riesgo aceptado: forward-only.
      await storage.delete(_queueKey(businessId));
      await storage.delete(_completedOpsKey(businessId));
      await storage.delete(_completedFingerprintsKey(businessId));
    } catch (e) {
      debugPrint('[offline] migración SP→drift falló: $e');
    }
  }

  /// Cache memoria por businessId del device_id estable para anotar cada
  /// acción encolada con su origen. Lo usan reports/auditoría
  /// multi-terminal (Fase 5 LWW). Si la lectura falla, devolvemos null
  /// y el normalize lo omite — no es bloqueante.
  final Map<String, String> _deviceIdByBusiness = {};
  Future<String?> _resolveDeviceId(String businessId) async {
    final cached = _deviceIdByBusiness[businessId];
    if (cached != null) return cached;
    try {
      final id = await DeviceIdentity.getOrCreateId(businessId);
      _deviceIdByBusiness[businessId] = id;
      return id;
    } catch (_) {
      return null;
    }
  }

  String _snapshotKey(String businessId, String slotId) =>
      'offline_snapshot_${businessId}_$slotId';
  String _retailCartsIndexKey(String businessId) =>
      'retail_carts_index_$businessId';
  String _queueKey(String businessId) => 'offline_queue_$businessId';
  String _printQueueKey(String businessId) => 'offline_print_queue_$businessId';
  String _orderMapKey(String businessId) => 'offline_order_map_$businessId';
  String _itemMapKey(String businessId) => 'offline_item_map_$businessId';
  String _localOrderOpenerKey(String businessId) =>
      'offline_order_opener_$businessId';
  String _cashSessionMapKey(String businessId) =>
      'offline_cash_session_map_$businessId';
  String _completedOpsKey(String businessId) =>
      'offline_completed_ops_$businessId';
  String _completedFingerprintsKey(String businessId) =>
      'offline_completed_fingerprints_$businessId';

  /// Cifra y persiste un snapshot. Centraliza el sellado AES-GCM para que
  /// todos los sitios que escriben snapshots (save, reconcile, remaps) lo
  /// hagan cifrado. Ver [SecureBlobCipher].
  Future<void> _writeSnapshot(
    StorageService storage,
    String key,
    Map<String, dynamic> payload,
  ) async {
    final saved = await storage.write(
      key,
      await _cipher.sealDurable(jsonEncode(payload)),
    );
    if (!saved) throw StateError('No se pudo guardar la orden en este equipo.');
  }

  /// Lee y descifra un snapshot. Devuelve null si no existe o si el
  /// descifrado falla (clave perdida/blob corrupto → el borrador se trata
  /// como inexistente, sin crashear). Tolera valores legacy en texto plano
  /// (migración perezosa vía [SecureBlobCipher.open]).
  Future<Map<String, dynamic>?> _readSnapshot(
    StorageService storage,
    String key,
  ) async {
    final raw = await storage.read(key);
    if (raw == null || raw.isEmpty) return null;
    final plain = await _cipher.open(raw);
    if (plain == null || plain.isEmpty) return null;
    return Map<String, dynamic>.from(jsonDecode(plain) as Map);
  }

  Future<void> saveSnapshot({
    required String businessId,
    required String slotId,
    required String origin,
    String? tableId,
    required CurrentOrderState state,
    bool localOnly = false,
  }) async {
    await _withSnapshotMutation(_snapshotKey(businessId, slotId), () async {
      final storage = await _storage;
      final orderId = state.order?.id;
      if (orderId != null &&
          await isOrderClosedLocally(
            businessId: businessId,
            orderId: orderId,
          )) {
        return;
      }
      final payload = {
        'slot_id': slotId,
        'business_id': businessId,
        'origin': origin,
        'table_id': tableId,
        'local_only': localOnly,
        'saved_at': DateTime.now().toIso8601String(),
        'state': _encodeState(state),
      };
      await _writeSnapshot(storage, _snapshotKey(businessId, slotId), payload);
    });
  }

  /// Alias del producto temporal después de sincronizar su alta.
  Future<String?> mappedRemoteItemId({
    required String businessId,
    required String localItemId,
  }) async => (await _readItemMap(businessId))[localItemId]?.toString();

  /// Aplica una respuesta tardía solo a su orden, conservando las demás
  /// líneas del respaldo vigente bajo el mismo candado que los guardados.
  Future<CurrentOrderState?> updateSnapshot({
    required String businessId,
    required String slotId,
    required String origin,
    String? tableId,
    required CurrentOrderState fallbackState,
    required CurrentOrderState Function(CurrentOrderState) update,
  }) => _withSnapshotMutation(_snapshotKey(businessId, slotId), () async {
    final expectedOrderId = fallbackState.order?.id;
    if (expectedOrderId == null ||
        await isOrderClosedLocally(
          businessId: businessId,
          orderId: expectedOrderId,
        )) {
      return null;
    }
    final storage = await _storage;
    final key = _snapshotKey(businessId, slotId);
    final payload = await _readSnapshot(storage, key);
    final current = payload == null
        ? fallbackState
        : _decodeState(Map<String, dynamic>.from(payload['state'] as Map));
    final currentOrderId = current.order?.id;
    if (currentOrderId != expectedOrderId) {
      final mappings = await _readOrderMap(businessId);
      if (currentOrderId == null ||
          (mappings[currentOrderId] ?? currentOrderId) !=
              (mappings[expectedOrderId] ?? expectedOrderId)) {
        return null;
      }
    }
    final updated = update(current);
    await _writeSnapshot(storage, key, {
      ...?payload,
      'business_id': businessId,
      'slot_id': slotId,
      'origin': payload?['origin'] ?? origin,
      'table_id': payload?['table_id'] ?? tableId,
      'local_only': payload?['local_only'] ?? true,
      'saved_at': DateTime.now().toIso8601String(),
      'state': _encodeState(updated),
    });
    return updated;
  });

  Future<CurrentOrderState?> loadSnapshot({
    required String businessId,
    required String slotId,
  }) async {
    final storage = await _storage;
    final key = _snapshotKey(businessId, slotId);
    try {
      final payload = await _readSnapshot(storage, key);
      if (payload == null) return null;
      final stateMap = Map<String, dynamic>.from(payload['state'] as Map);
      final orderId = (stateMap['order'] as Map?)?['id']?.toString();
      if (orderId != null &&
          await isOrderClosedLocally(
            businessId: businessId,
            orderId: orderId,
          )) {
        // La lectura pudo empezar antes de que una venta nueva ocupara este
        // slot. El cierre elimina sus snapshots mediante la ruta de mutación;
        // una lectura antigua nunca debe borrar el nuevo respaldo.
        return null;
      }
      final reconciledState = await _reconcileEncodedState(
        businessId: businessId,
        state: stateMap,
      );
      // Una lectura no reescribe: el cajero pudo guardar productos nuevos
      // mientras se resolvían los mappings. Reescribir aquí perdía esos items.
      return _decodeState(reconciledState);
    } catch (e) {
      debugPrint('OfflinePosService.loadSnapshot error: $e');
      return null;
    }
  }

  Future<void> remapSnapshotOrderId({
    required String businessId,
    required String localOrderId,
    required String remoteOrderId,
  }) async {
    final storage = await _storage;
    final prefix = 'offline_snapshot_${businessId}_';
    final keys = await storage.getKeysByPrefix(prefix);

    for (final key in keys) {
      try {
        await _withSnapshotMutation(key, () async {
          final payload = await _readSnapshot(storage, key);
          if (payload == null) return;
          final state = Map<String, dynamic>.from(
            payload['state'] as Map? ?? {},
          );
          final order = Map<String, dynamic>.from(state['order'] as Map? ?? {});
          if (order['id'] != localOrderId) return;
          order['id'] = remoteOrderId;
          state['order'] = order;
          payload['state'] = state;
          payload['local_only'] = false;
          await _writeSnapshot(storage, key, payload);
        });
      } catch (e) {
        debugPrint('OfflinePosService.remapSnapshotOrderId error: $e');
      }
    }
  }

  /// Lista las mesas con una cuenta LOCAL de ESTE dispositivo aún no
  /// sincronizada por completo. Cubre dos casos:
  ///   1. Borrador puro: la orden sigue siendo `local-order-…`, así que
  ///      `v_zone_table_status` no la conoce.
  ///   2. Sync PARCIAL: el replay de `open_table` ya creó la orden real y
  ///      remapeó el snapshot (uuid real), pero quedan acciones de CONTENIDO
  ///      (add_item, send_to_kitchen, etc.) sin sincronizar → el server
  ///      muestra la sesión VACÍA. Sin overlay, la mesa se pinta libre y
  ///      `fn_release_empty_tables` puede cerrarla con ítems aún en cola.
  /// El grid del salón las overlaya como ocupadas/pendientes para que NO
  /// desaparezcan al recargar desde el server. La visibilidad ENTRE
  /// terminales es tarea del Hub Local (F3), no de esto. Best-effort: una
  /// entrada corrupta se ignora. Devuelve tableId + conteo de ítems + total
  /// del borrador para pintar la tarjeta.
  Future<List<({String tableId, int itemsCount, double total})>>
  listPendingTableDrafts(String businessId) async {
    final storage = await _storage;
    final prefix = 'offline_snapshot_${businessId}_';
    final keys = await storage.getKeysByPrefix(prefix);

    // Órdenes con CONTENIDO pendiente en la cola (caso 2). Pagos y
    // anulaciones no cuentan como contenido: un void pendiente significa
    // que la cuenta se descartó, y un pago solo no debe revivir la mesa.
    // Se indexa por id crudo Y por id remoto mapeado, porque el snapshot
    // puede estar remapeado mientras las acciones siguen con el id local.
    final pendingContentOrderIds = <String>{};
    final closedOrderIds = <String>{};
    try {
      final queue = await _readQueue(businessId);
      final orderMap = await _readOrderMap(businessId);
      for (final action in queue) {
        final type = action['type']?.toString();
        final orderId = action['order_id']?.toString();
        if (type == null || orderId == null || orderId.isEmpty) continue;
        final mapped = orderMap[orderId]?.toString();
        final closesOrder =
            type == 'void_order' ||
            type == 'release_empty_order' ||
            (type == 'process_payment' &&
                action['close_order'] != false &&
                (action['check_id']?.toString().isEmpty ?? true));
        if (closesOrder && !_isDead(action)) {
          closedOrderIds.add(orderId);
          if (mapped != null && mapped.isNotEmpty) closedOrderIds.add(mapped);
          continue;
        }
        if (_isSettled(action)) continue;
        if (type == 'process_payment') continue;
        pendingContentOrderIds.add(orderId);
        if (mapped != null && mapped.isNotEmpty) {
          pendingContentOrderIds.add(mapped);
        }
      }
      pendingContentOrderIds.removeAll(closedOrderIds);
    } catch (_) {
      // best-effort: sin cola legible, caemos al criterio local-order- solo.
    }

    final result = <({String tableId, int itemsCount, double total})>[];
    for (final key in keys) {
      try {
        final payload = await _readSnapshot(storage, key);
        if (payload == null) continue;
        // Solo cuentas de MESA (no venta rápida/retail).
        if (payload['origin'] != 'table') continue;
        final tableId = payload['table_id'] as String?;
        if (tableId == null || tableId.isEmpty) continue;
        final state = Map<String, dynamic>.from(payload['state'] as Map? ?? {});
        final order = Map<String, dynamic>.from(state['order'] as Map? ?? {});
        final orderId = order['id'] as String?;
        if (orderId == null || orderId.isEmpty) continue;
        final isLocalDraft = orderId.startsWith('local-order-');
        final hasPendingContent = pendingContentOrderIds.contains(orderId);
        // Una cuenta anulada offline no debe seguir ocupando la mesa.
        if (closedOrderIds.contains(orderId)) continue;
        if (!isLocalDraft && !hasPendingContent) continue;
        final items = (state['items'] as List?) ?? const [];
        final total = (order['total'] as num?)?.toDouble() ?? 0;
        result.add((tableId: tableId, itemsCount: items.length, total: total));
      } catch (_) {
        // best-effort: ignorar snapshots corruptos.
      }
    }
    return result;
  }

  /// Persiste el índice de carritos de venta rápida (retail) cifrado: la lista
  /// de pestañas + cuál está activa. Permite reconstruir las pestañas tras un
  /// reinicio/cierre de la app. El estado de cada carrito vive en su propio
  /// snapshot (`slotId` por carrito); esto solo guarda el "mapa".
  Future<void> saveRetailCartsIndex({
    required String businessId,
    required List<Map<String, dynamic>> carts,
    String? activeSlotId,
  }) async {
    final storage = await _storage;
    final payload = {
      'carts': carts,
      'active_slot_id': activeSlotId,
      'saved_at': DateTime.now().toIso8601String(),
    };
    await _writeSnapshot(storage, _retailCartsIndexKey(businessId), payload);
  }

  /// Lee el índice de carritos retail. Null si no existe o el descifrado falla.
  Future<({List<Map<String, dynamic>> carts, String? activeSlotId})?>
  loadRetailCartsIndex({required String businessId}) async {
    final storage = await _storage;
    final raw = await storage.read(_retailCartsIndexKey(businessId));
    if (raw == null || raw.isEmpty) return null;
    final plain = await _cipher.open(raw);
    if (plain == null || plain.isEmpty) return null;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(plain) as Map);
      final carts = (map['carts'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      return (carts: carts, activeSlotId: map['active_slot_id'] as String?);
    } catch (e) {
      debugPrint('OfflinePosService.loadRetailCartsIndex error: $e');
      return null;
    }
  }

  /// Busca el `slot_id` del snapshot cuyo `order.id` coincide con
  /// [localOrderId]. Lo usa el replay para recrear una venta rápida retail por
  /// su carrito (slot) — y enrutar a `fn_open_retail_cart` en vez del RPC
  /// compartido que anularía los demás carritos. Null si no se encuentra.
  Future<String?> findSnapshotSlotForOrder({
    required String businessId,
    required String localOrderId,
  }) async {
    final storage = await _storage;
    final prefix = 'offline_snapshot_${businessId}_';
    final keys = await storage.getKeysByPrefix(prefix);
    for (final key in keys) {
      try {
        final payload = await _readSnapshot(storage, key);
        if (payload == null) continue;
        final state = Map<String, dynamic>.from(payload['state'] as Map? ?? {});
        final order = Map<String, dynamic>.from(state['order'] as Map? ?? {});
        if (order['id'] == localOrderId) {
          return payload['slot_id']?.toString();
        }
      } catch (_) {
        // snapshot corrupto/ilegible → seguimos con el siguiente
      }
    }
    return null;
  }

  /// [opener]: quién abre la venta AHORA (el mesero del PIN, o la cuenta si
  /// se abre sin PIN). Ver [rememberLocalOrderOpener].
  Future<CurrentOrderState> createLocalDraft({
    required String businessId,
    required String origin,
    String? tableId,
    String? slotId,
    String? label,
    ({String? employeeId, String? name})? opener,
  }) async {
    final orderId = 'local-order-${_uuid.v4()}';
    final sessionId = 'local-session-${_uuid.v4()}';
    await rememberLocalOrderOpener(
      businessId: businessId,
      localOrderId: orderId,
      employeeId: opener?.employeeId,
      name: opener?.name,
    );
    final order = Order(
      id: orderId,
      sessionId: sessionId,
      status: 'draft',
      subtotal: 0,
      discounts: 0,
      serviceFee: 0,
      tax: 0,
      total: 0,
      createdAt: DateTime.now(),
    );

    final state = CurrentOrderState(
      loading: false,
      order: order,
      items: const [],
      checks: const [],
      takeout: origin == 'quick',
      origin: origin,
      error: null,
    );

    await saveSnapshot(
      businessId: businessId,
      slotId: slotId ?? tableId ?? origin,
      origin: origin,
      tableId: tableId,
      state: state,
      localOnly: true,
    );

    return state;
  }

  Future<void> enqueueAction({
    required String businessId,
    required Map<String, dynamic> action,
  }) async {
    // Anotamos device_id de origen (audit LWW). Best-effort: si falla
    // la lectura del id no bloqueamos el enqueue.
    final deviceId = await _resolveDeviceId(businessId);
    final enriched = Map<String, dynamic>.from(action);
    final localOrderId = action['order_id']?.toString();
    if (localOrderId != null && localOrderId.startsWith('local-order-')) {
      // El pago/anulación retira el snapshot. Guardar ahora el destino de
      // replay en la acción para poder subirla aun sin ese snapshot.
      final storage = await _storage;
      final keys = await storage.getKeysByPrefix(
        'offline_snapshot_${businessId}_',
      );
      // Atajo: si la acción ya trae su slot, ese snapshot se revisa primero
      // (descifrar todos los snapshots del negocio en cada alta es caro).
      final knownSlot = enriched['slot_id']?.toString();
      if (knownSlot != null && knownSlot.isNotEmpty) {
        final slotKey = _snapshotKey(businessId, knownSlot);
        if (keys.remove(slotKey)) keys.insert(0, slotKey);
      }
      for (final key in keys) {
        try {
          final snapshot = await _readSnapshot(storage, key);
          if ((snapshot?['state'] as Map?)?['order'] is! Map) continue;
          final snapshotOrder = (snapshot!['state'] as Map)['order'] as Map;
          if (snapshotOrder['id'] != localOrderId) continue;
          for (final field in ['origin', 'table_id', 'slot_id']) {
            if (enriched[field] == null && snapshot[field] != null) {
              enriched[field] = snapshot[field];
            }
          }
          break;
        } catch (e) {
          // Un snapshot ilegible (de esta u otra venta) no debe impedir
          // encolar: el enriquecimiento es best-effort y el replay tiene sus
          // respaldos (_resolveTableIdForAction / findSnapshotSlotForOrder).
          debugPrint('[OfflinePos] snapshot ilegible al encolar ($key): $e');
        }
      }
      // Quién la abrió viaja EN la acción: si la sube otro equipo (el Hub),
      // ese no tiene la anotación local y la mesa quedaría a nombre de su
      // cuenta.
      if (enriched['opened_by_employee_id'] == null) {
        final opener = await localOrderOpener(
          businessId: businessId,
          orderId: localOrderId,
        );
        if (opener?.employeeId != null) {
          enriched['opened_by_employee_id'] = opener!.employeeId;
        }
      }
    }
    if (deviceId != null && enriched['device_id'] == null) {
      enriched['device_id'] = deviceId;
    }
    // Normalizamos ANTES de decidir el destino: la op necesita op_id y
    // fingerprint tanto para la cola local como para la idempotencia del Hub.
    final normalized = _normalizeAction(enriched);

    // Persist before network I/O: a lost acknowledgement must retain the same
    // operation ID, and a crash must not erase an accepted user action.
    await _withQueueMutation(businessId, () async {
      final current = await _readQueue(businessId);
      current.add(normalized);
      await _writeQueue(businessId, _compactQueue(current));
    });
    if (_hubUploader != null) {
      unawaited(
        flushPendingToHub(businessId).then<void>(
          (_) {},
          onError: (Object e, StackTrace _) {
            debugPrint('[HubOutbox] reenvio pendiente: $e');
          },
        ),
      );
    }
  }

  /// LAN-only drain, sharing the cloud replay lock. Never move an operation
  /// already attempted against cloud to another replay authority.
  Future<OfflineQueueSyncResult> flushPendingToHub(String businessId) {
    final active = _queueSyncInFlight[businessId];
    if (active != null) return active;
    final run = _flushPendingToHubOnce(businessId).whenComplete(() {
      _queueSyncInFlight.remove(businessId);
    });
    _queueSyncInFlight[businessId] = run;
    return run;
  }

  Future<OfflineQueueSyncResult> _flushPendingToHubOnce(
    String businessId,
  ) async {
    final uploader = _hubUploader;
    if (uploader == null) return const OfflineQueueSyncResult();
    final queue = await _readQueue(businessId);
    var completed = 0;
    String? error;
    final cloudOwnedOrders = _cloudOwnedOrders(queue);
    for (final action in queue) {
      if (_isCompleted(action)) continue;
      if (!identical(uploader, _hubUploader)) break;
      // Do not transfer a partially replayed order to a different authority.
      // Independent new orders can still operate through LAN.
      if (_isCloudOwned(action, cloudOwnedOrders)) {
        error = 'Hay operaciones previas de nube pendientes de conciliar.';
        continue;
      }
      final claimed = await _withQueueMutation(businessId, () async {
        final current = await _readQueue(businessId);
        final index = current.indexWhere((a) => a['id'] == action['id']);
        if (index < 0 || _isCompleted(current[index])) return null;
        final next = _normalizeAction(current[index])
          ..['hub_delivery_started'] = true
          ..['status'] = _statusPending;
        await _upsertActionUnlocked(businessId, next);
        return next;
      });
      if (claimed == null) continue;
      try {
        final seq = await uploader(businessId, claimed);
        if (seq == null) break;
        await _upsertAction(businessId, {
          ...claimed,
          'status': _statusCompleted,
          'hub_seq': seq,
          'completed_at': DateTime.now().toIso8601String(),
        });
        completed++;
      } catch (e) {
        error = FriendlyError.from(e);
        break;
      }
    }
    // Una sola lectura para los dos contadores: sin `dead`, cada pasada en
    // modo Hub dejaba el badge rojo de dead-letter en 0.
    final remaining = await _readQueue(businessId);
    return OfflineQueueSyncResult(
      completed: completed,
      processed: completed,
      pending: remaining.where((action) => !_isSettled(action)).length,
      dead: remaining.where(_isDead).length,
      lastError: error,
    );
  }

  Future<void> enqueuePrintJob({
    required String businessId,
    required Map<String, dynamic> job,
  }) async {
    final storage = await _storage;
    final current =
        await storage.readList(_printQueueKey(businessId)) ?? <dynamic>[];
    current.add({...job, 'queued_at': DateTime.now().toIso8601String()});
    await storage.writeList(_printQueueKey(businessId), current);
  }

  Future<int> pendingActionsCount(String businessId) async {
    final queue = await _readQueue(businessId);
    // Excluye dead-letter: esas no reintentan solas, no son "pendientes
    // de sincronizar" sino "pendientes de revisión manual". Se cuentan
    // aparte con [deadActionsCount] para no dejar el badge pegado.
    return queue.where((item) => !_isSettled(item)).length;
  }

  /// Lightweight badge counts. Native SQLite reads only indexed metadata;
  /// web falls back to a single queue read for both numbers.
  Future<({int pending, int dead})> queueStatusCounts(String businessId) async {
    if (!kIsWeb) {
      await _ensureMigratedFromSp(businessId);
      return _queueDao!.statusCounts(businessId);
    }
    final queue = await _readQueue(businessId);
    var pending = 0;
    var dead = 0;
    for (final action in queue) {
      if (_isDead(action)) {
        dead++;
      } else if (!_isCompleted(action)) {
        pending++;
      }
    }
    return (pending: pending, dead: dead);
  }

  /// ¿Una pasada automática (sin force) subiría o conciliaría algo AHORA?
  /// Solo lectura: no reclama, no escribe, no toca la red.
  ///
  /// Usa las mismas reglas que la pasada ([_replayGate] en la nube,
  /// [_isCloudOwned] en modo Hub), así el uplink no despierta cada 5 s por
  /// acciones en backoff, en dead-letter, entregadas al Hub o detenidas
  /// detrás de un fallo de su misma orden. Una acción que ya figura subida
  /// (marcador de idempotencia) sí cuenta: la pasada la marca completed.
  Future<bool> hasActionsReadyToSync(String businessId) async {
    if (businessId.isEmpty || _queueSyncInFlight.containsKey(businessId)) {
      return false;
    }
    // Atajo nativo: sin pendientes no hace falta leer (ni descifrar) la cola.
    if (!kIsWeb && (await queueStatusCounts(businessId)).pending == 0) {
      return false;
    }
    final queue = await _readQueue(businessId);
    if (_hubUploader != null) {
      final cloudOwnedOrders = _cloudOwnedOrders(queue);
      return queue.any(
        (action) =>
            !_isCompleted(action) && !_isCloudOwned(action, cloudOwnedOrders),
      );
    }
    if (!queue.any((action) => !_isSettled(action))) return false;
    final completedOps = await _readCompletedOps(businessId);
    final completedFingerprints = await _readCompletedFingerprints(businessId);
    final blockedOrders = <String>{};
    for (final action in queue) {
      final gate = _replayGate(
        action,
        force: false,
        completedOps: completedOps,
        completedFingerprints: completedFingerprints,
        blockedOrders: blockedOrders,
      );
      if (gate == _ReplayGate.replay || gate == _ReplayGate.reconcile) {
        return true;
      }
    }
    return false;
  }

  /// Suma las ventas del día que viven SOLO en la cola local (offline, aún no
  /// sincronizadas) para el dashboard sin conexión. Se calcula sobre el último
  /// snapshot online; por eso solo cuenta acciones NO settled (las settled ya
  /// están reflejadas en el server/snapshot).
  ///
  /// [dayStart]/[dayEnd] = ventana local del día (00:00 hoy → 00:00 mañana).
  ///
  /// Nota: en modo Hub (F3) las ops se enrutan al Hub y no quedan en esta cola,
  /// así que este delta es para modo cloud/solo. Los conteos de órdenes son
  /// aproximados (la cola es por-operación, no por-orden); el ingreso y los
  /// items, que es lo que se muestra como headline, sí son exactos.
  Future<OfflineKpiDelta> todayPendingSalesDelta({
    required String businessId,
    required DateTime dayStart,
    required DateTime dayEnd,
  }) async {
    if (businessId.isEmpty) return OfflineKpiDelta.empty;
    final queue = await _readQueue(businessId);

    double income = 0;
    double itemsSold = 0;
    final touchedOrders = <String>{};
    final paidOrders = <String>{};
    final voidedOrders = <String>{};

    for (final action in queue) {
      if (_isSettled(action)) {
        continue; // ya sincronizada → ya está en el snapshot
      }

      final when = _actionLocalTime(action);
      if (when == null || when.isBefore(dayStart) || !when.isBefore(dayEnd)) {
        continue;
      }

      final type = action['type']?.toString();
      final orderId = action['order_id']?.toString();
      switch (type) {
        case 'process_payment':
          final amount = (action['amount'] as num?)?.toDouble() ?? 0;
          final change = (action['change_amount'] as num?)?.toDouble() ?? 0;
          income += amount - change;
          if (orderId != null && orderId.isNotEmpty) {
            paidOrders.add(orderId);
            touchedOrders.add(orderId);
          }
          break;
        case 'add_item':
          itemsSold +=
              (action['qty'] as num?)?.toDouble() ??
              (action['quantity'] as num?)?.toDouble() ??
              0;
          if (orderId != null && orderId.isNotEmpty) touchedOrders.add(orderId);
          break;
        case 'void_order':
          if (orderId != null && orderId.isNotEmpty) voidedOrders.add(orderId);
          break;
        case 'confirm_local_order':
        case 'send_to_kitchen':
          if (orderId != null && orderId.isNotEmpty) touchedOrders.add(orderId);
          break;
      }
    }

    final liveOrders = touchedOrders.difference(voidedOrders);
    final completed = paidOrders.difference(voidedOrders);
    return OfflineKpiDelta(
      income: income,
      itemsSold: itemsSold,
      ordersTotal: liveOrders.length,
      ordersCompleted: completed.length,
      ordersInProgress: liveOrders.difference(completed).length,
    );
  }

  /// Fecha local de una acción de la cola: usa `paid_at` (pagos) si existe, si
  /// no `queued_at`. Null si no se puede parsear.
  DateTime? _actionLocalTime(Map<String, dynamic> action) {
    final raw = (action['paid_at'] ?? action['queued_at'])?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  /// Cantidad de acciones en dead-letter (agotaron reintentos). El shell
  /// las muestra aparte del badge de pendientes para que el cajero sepa
  /// que hay operaciones que requieren su intervención.
  Future<int> deadActionsCount(String businessId) async {
    final queue = await _readQueue(businessId);
    return queue.where(_isDead).length;
  }

  /// Lista las acciones en dead-letter para inspección en la UI (tipo,
  /// último error, intentos, cuándo murió). Copia inmutable.
  Future<List<Map<String, dynamic>>> deadActions(String businessId) async {
    final queue = await _readQueue(businessId);
    return queue
        .where(_isDead)
        .map((a) => Map<String, dynamic>.unmodifiable(a))
        .toList(growable: false);
  }

  /// Lista TODAS las acciones no-completadas (pending/processing/failed/
  /// dead) en orden FIFO para el visor de la cola en la UI: tipo, payload,
  /// intentos, `last_error` y estado. Copias inmutables.
  Future<List<Map<String, dynamic>>> unsettledActions(String businessId) async {
    final queue = await _readQueue(businessId);
    return queue
        .where((a) => !_isCompleted(a))
        .map((a) => Map<String, dynamic>.unmodifiable(a))
        .toList(growable: false);
  }

  /// Resucita las acciones en dead-letter: vuelven a `pending` con el
  /// contador de intentos en cero para que el próximo sync las reintente.
  /// Útil cuando el cajero corrigió la causa raíz (ej: reabrió la mesa).
  /// Devuelve cuántas se reactivaron.
  Future<int> retryDeadActions(String businessId) async {
    if (businessId.isEmpty) return 0;
    final queue = await _readQueue(businessId);
    var revived = 0;
    final next = queue
        .map((action) {
          if (!_isDead(action)) return action;
          revived++;
          final reset = Map<String, dynamic>.from(action)
            ..['status'] = _statusPending
            ..['attempts'] = 0
            ..['last_error'] = null;
          reset.remove('next_retry_at');
          reset.remove('dead_at');
          reset.remove('failed_at');
          return reset;
        })
        .toList(growable: false);
    if (revived > 0) {
      await _writeQueue(businessId, next);
    }
    return revived;
  }

  /// Descarta SOLO las acciones en dead-letter, dejando intactas las
  /// pendientes/en proceso. A diferencia de [clearPendingActions] (que
  /// borra todo lo no-completado), esto es quirúrgico: limpia lo que ya
  /// se rindió sin tocar lo que aún puede sincronizar. NO toca los
  /// markers de idempotencia. Devuelve cuántas se descartaron.
  Future<int> clearDeadActions(String businessId) async {
    if (businessId.isEmpty) return 0;
    final queue = await _readQueue(businessId);
    final survivors = queue.where((a) => !_isDead(a)).toList(growable: false);
    final removed = queue.length - survivors.length;
    if (removed > 0) {
      await _writeQueue(businessId, survivors);
    }
    return removed;
  }

  /// Id remoto mapeado para una orden local (`local-order-…`), o null si la
  /// orden nunca llegó al server. Lo usa el flujo de anulación para decidir
  /// entre descartar la orden local (nunca sincronizó) o anular la real.
  Future<String?> mappedRemoteOrderId({
    required String businessId,
    required String localOrderId,
  }) async {
    if (businessId.isEmpty || localOrderId.isEmpty) return null;
    try {
      final map = await _readOrderMap(businessId);
      final remote = map[localOrderId]?.toString();
      return (remote == null || remote.isEmpty) ? null : remote;
    } catch (_) {
      return null;
    }
  }

  /// Incluye errores pendientes de revisión. Una venta incompleta en nube
  /// nunca debe reemplazar al snapshot que conserva todos sus productos.
  Future<bool> hasUnsettledOrderActions({
    required String businessId,
    required String orderId,
  }) async {
    final mappings = await _readOrderMap(businessId);
    final resolved = mappings[orderId]?.toString() ?? orderId;
    return (await _readQueue(businessId)).any((action) {
      if (_isCompleted(action)) return false;
      final actionOrderId = action['order_id']?.toString();
      return actionOrderId == orderId ||
          actionOrderId == resolved ||
          (actionOrderId != null && mappings[actionOrderId] == resolved);
    });
  }

  /// Las acciones de [orderId] en la cola, con UNA sola lectura (mismo cruce
  /// de ids que [hasUnsettledOrderActions]):
  /// - `unsettled`: alguna sin completar (pendiente, en proceso, fallida o
  ///   muerta). Lo de pantalla es la verdad local.
  /// - `revivingAdds`: algún alta de producto que todavía sube sola
  ///   (pendiente, en proceso o fallida; no muerta). Al subir, el trigger de
  ///   `order_items` (20260819_0004, fn_reopen_orphan_order) RESUCITA la
  ///   cuenta si quedó anulada sin cobro ni NCF, como la anula el barrendero
  ///   de mesas vacías (fn_release_empty_tables). Mientras haya una, esa
  ///   anulación no es definitiva.
  /// Sin acciones sin completar en el negocio (conteo por metadatos, sin
  /// descifrar) ni siquiera lee la cola.
  Future<({bool unsettled, bool revivingAdds})> orderQueueStatus({
    required String businessId,
    required String orderId,
  }) async {
    if (!kIsWeb) {
      final counts = await queueStatusCounts(businessId);
      if (counts.pending + counts.dead == 0) {
        return (unsettled: false, revivingAdds: false);
      }
    }
    final mappings = await _readOrderMap(businessId);
    final resolved = mappings[orderId]?.toString() ?? orderId;
    var unsettled = false;
    for (final action in await _readQueue(businessId)) {
      if (_isCompleted(action)) continue;
      final actionOrderId = action['order_id']?.toString();
      final ofThisOrder =
          actionOrderId == orderId ||
          actionOrderId == resolved ||
          (actionOrderId != null && mappings[actionOrderId] == resolved);
      if (!ofThisOrder) continue;
      unsettled = true;
      if (action['type'] == 'add_item' && !_isDead(action)) {
        return (unsettled: true, revivingAdds: true);
      }
    }
    return (unsettled: unsettled, revivingAdds: false);
  }

  /// Alta en línea terminada: guarda `tmp_` → id real si esa línea está en
  /// una comanda local, para que el replay de la comanda confirme exactamente
  /// esa línea. [force]: la comanda se está imprimiendo ahora (su acción aún
  /// no está en la cola). Si no, solo cuando una comanda pendiente de la cola
  /// la lleva: el mapa no se poda y no se llena con cada alta en línea.
  Future<void> rememberKitchenItemMapping({
    required String businessId,
    required String localItemId,
    required String remoteItemId,
    bool force = false,
  }) async {
    if (!localItemId.startsWith('tmp_')) return;
    if (!force) {
      final pending = await unsettledActions(businessId);
      final referenced = pending.any(
        (action) =>
            _isKitchenRoundAction(action) &&
            _kitchenRoundRawIds(action).contains(localItemId),
      );
      if (!referenced) return;
    }
    await _saveItemMapping(
      businessId: businessId,
      localItemId: localItemId,
      remoteItemId: remoteItemId,
    );
  }

  static bool _isKitchenRoundAction(Map<String, dynamic> action) {
    final type = action['type'];
    return type == 'confirm_local_order' || type == 'send_to_kitchen';
  }

  /// Ids (tal como se imprimieron) de todas las áreas de la comanda.
  static Set<String> _kitchenRoundRawIds(Map<String, dynamic> action) {
    final byArea = action['item_ids_by_area'];
    if (byArea is! Map) return const <String>{};
    return {
      for (final ids in byArea.values)
        if (ids is List)
          for (final id in ids)
            if (id.toString().isNotEmpty) id.toString(),
    };
  }

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// Ids del servidor de las líneas que imprimió una comanda local. Nunca
  /// devuelve la orden entera: si no se pueden resolver todas, retiene la
  /// acción ([_KitchenRoundHold]).
  Future<List<String>> _kitchenRoundItemIds({
    required String businessId,
    required Map<String, dynamic> action,
  }) async {
    final raw = _kitchenRoundRawIds(action);
    if (raw.isEmpty) {
      throw const _KitchenRoundHold(
        'Comanda de una versión anterior, sin el detalle de sus productos: no '
        'se confirma sola en cocina. Revisa la cuenta y vuelve a enviarla si '
        'hace falta.',
        terminal: true,
      );
    }
    final itemMap = await _readItemMap(businessId);
    final resolved = <String>{};
    final unresolved = <String>[];
    for (final id in raw) {
      final remote = id.startsWith('tmp_') ? itemMap[id]?.toString() : id;
      if (remote != null && _uuidPattern.hasMatch(remote)) {
        resolved.add(remote);
      } else {
        unresolved.add(id);
      }
    }
    if (unresolved.isEmpty) return resolved.toList(growable: false);
    // El alta de la línea sigue en la cola (va detrás, o falló y reintenta):
    // al subir guarda el mapeo. Se espera sin gastar intentos.
    final pending = await unsettledActions(businessId);
    final addPending = pending.any(
      (other) =>
          other['type'] == 'add_item' &&
          !_isDead(other) &&
          unresolved.contains(other['item_id']?.toString()),
    );
    throw _KitchenRoundHold(
      addPending
          ? 'La comanda espera que suban sus productos para confirmarse en '
                'cocina.'
          : 'No se pudo identificar ${unresolved.length} producto(s) de la '
                'comanda para confirmarla en cocina.',
      countsAttempt: !addPending,
    );
  }

  static const _kitchenRpcMissingMessage =
      'Falta actualizar el servidor (migración 20261010_0002) para confirmar '
      'esta comanda en cocina. Se conserva hasta entonces.';

  Future<List<String>> resolveKitchenPrintItemIds({
    required String businessId,
    required List<String> itemIds,
  }) async {
    final itemMap = await _readItemMap(businessId);
    return itemIds
        .map((id) {
          if (!id.startsWith('tmp_')) return id;
          final remote = itemMap[id]?.toString();
          if (remote == null || remote.isEmpty) {
            throw StateError('El producto $id aún no está sincronizado.');
          }
          return remote;
        })
        .toList(growable: false);
  }

  /// A transport attempt can have succeeded even when its acknowledgement was
  /// lost. Never discard such an order merely because its mapping is absent.
  Future<bool> mayExistRemotely({
    required String businessId,
    required String orderId,
  }) async {
    final queue = await _readQueue(businessId);
    return queue.any(
      (action) =>
          action['order_id']?.toString() == orderId &&
          (action['hub_delivery_started'] == true ||
              ((action['attempts'] as num?)?.toInt() ?? 0) > 0 ||
              action['status'] == _statusProcessing),
    );
  }

  /// Hide a cancelled local draft without deleting its durable operation log.
  Future<void> removeOrderSnapshots({
    required String businessId,
    required String orderId,
  }) async {
    final storage = await _storage;
    final mappings = await _readOrderMap(businessId);
    final resolvedId = mappings[orderId]?.toString() ?? orderId;
    final keys = await storage.getKeysByPrefix(
      'offline_snapshot_${businessId}_',
    );
    for (final key in keys) {
      try {
        await _withSnapshotMutation(key, () async {
          final payload = await _readSnapshot(storage, key);
          final state = Map<String, dynamic>.from(
            payload?['state'] as Map? ?? {},
          );
          final order = Map<String, dynamic>.from(state['order'] as Map? ?? {});
          final snapshotId = order['id']?.toString();
          if (snapshotId == orderId ||
              snapshotId == resolvedId ||
              (snapshotId != null && mappings[snapshotId] == resolvedId)) {
            await storage.delete(key);
          }
        });
      } catch (e) {
        debugPrint('OfflinePosService.removeOrderSnapshots: $e');
      }
    }
  }

  String _closedOrderKey(String businessId, String orderId) =>
      'offline_closed_order_${businessId}_$orderId';

  /// A confirmed full payment wins over late snapshot writes and stale Hub
  /// projections for this exact order, without affecting a new table session.
  Future<void> markOrderClosedLocally({
    required String businessId,
    required String orderId,
  }) async {
    final storage = await _storage;
    final saved = await storage.write(
      _closedOrderKey(businessId, orderId),
      DateTime.now().toUtc().toIso8601String(),
    );
    if (!saved) throw StateError('No se pudo guardar el cierre local.');
    await removeOrderSnapshots(businessId: businessId, orderId: orderId);
  }

  Future<bool> isOrderClosedLocally({
    required String businessId,
    required String orderId,
  }) async {
    final storage = await _storage;
    if (await storage.read(_closedOrderKey(businessId, orderId)) != null) {
      return true;
    }
    final mappings = await _readOrderMap(businessId);
    final resolved = mappings[orderId]?.toString() ?? orderId;
    if (resolved != orderId &&
        await storage.read(_closedOrderKey(businessId, resolved)) != null) {
      return true;
    }
    for (final entry in mappings.entries) {
      if (entry.value == resolved &&
          await storage.read(_closedOrderKey(businessId, entry.key)) != null) {
        return true;
      }
    }
    return false;
  }

  /// Descarta por completo una orden LOCAL que el cajero anuló antes de que
  /// sincronizara: elimina sus acciones no-completadas de la cola (open_table,
  /// add_item, …) y borra sus snapshots. Sin esto, la cola recreaba la mesa
  /// en el server al reconectar (mesa fantasma) y el snapshot mantenía la
  /// mesa "ocupada" en el overlay del salón para siempre.
  ///
  /// SOLO aplica a órdenes `local-order-…` SIN mapping a server (si ya
  /// sincronizó, lo correcto es anular la orden real vía void_order). Las
  /// acciones ya `completed` se conservan como histórico de idempotencia.
  ///
  /// Una orden con un cobro en la cola NO se descarta y devuelve `false`: ya
  /// se cobró sin internet (salió la precuenta y el cliente pagó). Borrarla
  /// perdía la venta entera — productos, cobro y comprobante — sin dejar
  /// rastro en el servidor.
  Future<bool> discardLocalOrder({
    required String businessId,
    required String localOrderId,
  }) async {
    if (businessId.isEmpty || !localOrderId.startsWith('local-order-')) {
      return false;
    }
    // Cola: fuera todas las acciones pendientes/failed/dead de esa orden. Se
    // revisa y se escribe dentro del mismo candado que `enqueueAction`, para
    // que un cobro encolado justo ahora no se cuele entre la revisión y el
    // borrado.
    final bool discarded;
    try {
      discarded = await _withQueueMutation(businessId, () async {
        final queue = await _readQueue(businessId);
        if (queue.any((a) => _isUnsettledPaymentFor(a, localOrderId))) {
          return false;
        }
        final survivors = queue
            .where((a) {
              if (_isCompleted(a)) return true;
              return a['order_id']?.toString() != localOrderId;
            })
            .toList(growable: false);
        if (survivors.length != queue.length) {
          await _writeQueue(businessId, survivors);
        }
        return true;
      });
    } catch (e) {
      // Sin poder leer la cola no se sabe si hay un cobro: no se borra nada.
      debugPrint('OfflinePosService.discardLocalOrder cola: $e');
      return false;
    }
    if (!discarded) return false;
    try {
      await removeOrderSnapshots(businessId: businessId, orderId: localOrderId);
    } catch (e) {
      debugPrint('OfflinePosService.discardLocalOrder snapshots: $e');
    }
    return true;
  }

  /// True si la cola tiene un cobro de [orderId] que todavía no subió: la
  /// venta ya se cobró sin internet. Anularla o descartarla borraría ese cobro
  /// (orden local) o lo dejaría sin orden abierta a la que aplicarse al
  /// sincronizar (orden del servidor).
  ///
  /// Si la cola no se puede leer devuelve `true`: ante la duda no se toca una
  /// venta que pudo haberse cobrado.
  Future<bool> hasQueuedPayment({
    required String businessId,
    required String orderId,
  }) async {
    if (businessId.isEmpty || orderId.isEmpty) return false;
    try {
      final mappings = await _readOrderMap(businessId);
      final queue = await _readQueue(businessId);
      return queue.any(
        (a) => _isUnsettledPaymentFor(a, orderId, orderMappings: mappings),
      );
    } catch (e) {
      debugPrint('OfflinePosService.hasQueuedPayment: $e');
      return true;
    }
  }

  bool _isUnsettledPaymentFor(
    Map<String, dynamic> action,
    String orderId, {
    Map<String, dynamic> orderMappings = const {},
  }) {
    if (_isCompleted(action) || action['type'] != 'process_payment') {
      return false;
    }
    final actionOrderId = action['order_id']?.toString();
    if (actionOrderId == null || actionOrderId.isEmpty) return false;
    // La pantalla usa el UUID remoto tras el primer replay, pero el cobro
    // durable conserva el ID local. Ambos siguen siendo la misma venta,
    // incluso cuando ese cobro quedó failed/dead y necesita revisión.
    final resolvedOrderId = orderMappings[orderId]?.toString() ?? orderId;
    final resolvedActionId =
        orderMappings[actionOrderId]?.toString() ?? actionOrderId;
    return actionOrderId == orderId || resolvedActionId == resolvedOrderId;
  }

  /// Operaciones de dinero o caja: «Limpiar cola» nunca las descarta.
  static const Set<String> _moneyActionTypes = {
    'process_payment',
    'cash_transaction',
    'open_cash_session',
    'close_cash_session',
  };

  /// Respaldo cifrado de lo que «Limpiar cola» descartó: cada limpieza en su
  /// propia clave (sin tope, nada se pisa ni se poda hasta conciliarlo). El
  /// sufijo es el instante en microsegundos con ancho fijo, así el orden de
  /// las claves es el orden de las limpiezas.
  String _discardedBackupPrefix(String businessId) =>
      'offline_queue_discarded_${businessId}_';

  /// Reparte lo no sincronizado entre lo que «Limpiar cola» puede descartar
  /// y lo que conserva: dinero y caja, TODO lo de una cuenta con un cobro
  /// pendiente (por id local o remoto: sin sus productos el cobro quedaría
  /// sin cuenta a la que aplicarse) y lo que una pasada está procesando.
  Future<({List<Map<String, dynamic>> discard, int kept})> _splitClearable(
    String businessId,
  ) async {
    final queue = await _readQueue(businessId);
    final orderMap = await _readOrderMap(businessId);
    Set<String> idsOf(Map<String, dynamic> action) {
      final raw = action['order_id']?.toString();
      if (raw == null || raw.isEmpty) return const {};
      final mapped = orderMap[raw]?.toString();
      return {raw, if (mapped != null && mapped.isNotEmpty) mapped};
    }

    final unsettled = queue.where((a) => !_isCompleted(a)).toList();
    final moneyOrderIds = <String>{
      for (final action in unsettled)
        if (_moneyActionTypes.contains(action['type'])) ...idsOf(action),
    };
    final discard = <Map<String, dynamic>>[];
    var kept = 0;
    for (final action in unsettled) {
      final keep =
          _moneyActionTypes.contains(action['type']) ||
          action['status'] == _statusProcessing ||
          idsOf(action).any(moneyOrderIds.contains);
      if (keep) {
        kept++;
      } else {
        discard.add(action);
      }
    }
    return (discard: discard, kept: kept);
  }

  /// Qué haría «Limpiar cola…» ahora, sin tocar nada.
  Future<({int discardable, int kept})> previewClearPendingActions(
    String businessId,
  ) async {
    if (businessId.isEmpty) return (discardable: 0, kept: 0);
    final split = await _splitClearable(businessId);
    return (discardable: split.discard.length, kept: split.kept);
  }

  /// «Limpiar cola…» del indicador de sincronización: recurso de emergencia
  /// para acciones bloqueadas por errores irresolubles (ej: order_id que ya
  /// no existe en server).
  ///
  /// NUNCA descarta dinero: cobros, movimientos y aperturas/cierres de caja,
  /// ni ninguna acción de una cuenta con un cobro pendiente, ni lo que una
  /// pasada está procesando. Antes de descartar respalda lo descartado
  /// (payload completo, estado, error, quién y cuándo) cifrado en este equipo;
  /// si el respaldo no se puede guardar, no descarta nada.
  ///
  /// NO toca completed_ops/fingerprints: esos son markers que evitan
  /// re-aplicar acciones que SI llegaron al server. Borrarlos podria
  /// causar dobles ventas si una accion completed se re-encola luego.
  ///
  /// Devuelve cuántas acciones descartó.
  Future<int> clearPendingActions(
    String businessId, {
    String? discardedBy,
  }) async {
    if (businessId.isEmpty) return 0;
    final split = await _splitClearable(businessId);
    final ids = {
      for (final action in split.discard)
        if ((action['id']?.toString() ?? '').isNotEmpty)
          action['id'].toString(),
    };
    if (ids.isEmpty) return 0;
    await _backupDiscardedActions(
      businessId,
      split.discard,
      discardedBy: discardedBy,
    );
    if (kIsWeb) {
      final queue = await _readQueue(businessId);
      await _writeQueue(
        businessId,
        queue.where((a) => !ids.contains(a['id']?.toString())).toList(),
      );
      return ids.length;
    }
    try {
      return await _queueDao!.deleteActionsByIds(businessId, ids);
    } finally {
      _bumpQueueRevision(businessId);
    }
  }

  Future<void> _backupDiscardedActions(
    String businessId,
    List<Map<String, dynamic>> actions, {
    String? discardedBy,
  }) async {
    final storage = await _storage;
    final now = DateTime.now();
    final stamp = now.microsecondsSinceEpoch.toString().padLeft(20, '0');
    final discardedAt = now.toIso8601String();
    final entries = <Object?>[
      for (final action in actions)
        {
          ...action,
          'business_id': businessId,
          'discarded_at': discardedAt,
          'discarded_by': ?discardedBy,
        },
    ];
    try {
      await _writeSnapshot(
        storage,
        '${_discardedBackupPrefix(businessId)}$stamp',
        {'actions': entries},
      );
    } catch (e) {
      throw StateError(
        'No se pudo respaldar la cola antes de limpiarla; no se descartó '
        'nada. $e',
      );
    }
  }

  /// Lo que «Limpiar cola» descartó en este equipo, para revisarlo o
  /// recuperarlo (lo más reciente al final).
  Future<List<Map<String, dynamic>>> discardedActionsBackup(
    String businessId,
  ) async {
    if (businessId.isEmpty) return const [];
    final storage = await _storage;
    final keys = (await storage.getKeysByPrefix(
      _discardedBackupPrefix(businessId),
    )).toList()..sort();
    final result = <Map<String, dynamic>>[];
    for (final key in keys) {
      final payload = await _readSnapshot(storage, key);
      result.addAll(
        (payload?['actions'] as List? ?? const []).whereType<Map>().map(
          (a) => Map<String, dynamic>.from(a),
        ),
      );
    }
    return result;
  }

  /// Borra los datos OFFLINE de un negocio. Pensado para dos momentos:
  ///   - **Logout**: que el siguiente cajero no vea órdenes/pagos del
  ///     anterior (los snapshots y la cola contienen montos y detalle de
  ///     venta). Se llama con `includeReadCaches: false` para conservar
  ///     catálogo/inventario y acelerar el re-login.
  ///   - **Cambio de negocio**: `includeReadCaches: true` para no mezclar
  ///     catálogo/inventario/zonas del negocio anterior.
  ///
  /// Borra: cola de acciones (todos los estados), snapshots de órdenes,
  /// mappings local→remoto y cola de impresión. Opcionalmente los caches
  /// de catálogo/inventario/zonas.
  ///
  /// NO toca: roster ni device binding (son a nivel de dispositivo y se
  /// necesitan para el login por PIN offline), ni los marcadores de
  /// idempotencia (`completed_ops`/`fingerprints` — solo ids/hashes, no
  /// sensibles, y evitan re-aplicar lo que ya llegó al server).
  ///
  /// ⚠️ Borra la cola aunque tenga pendientes sin sincronizar. El caller
  /// (logout) DEBE chequear [pendingActionsCount] antes y advertir.
  Future<void> clearOfflineBusinessData(
    String businessId, {
    bool includeReadCaches = false,
    bool preservePending = false,
  }) async {
    if (businessId.isEmpty) return;
    final storage = await _storage;

    // Logout: NO descartar operaciones offline sin sincronizar. Conservamos la
    // cola no-completada (pending/processing/failed/dead) + snapshots, mappings
    // y cola de impresión (estado que el sync necesita y que no debe perderse al
    // cerrar sesión). Solo podamos lo ya `completed`. El siguiente login (mismo
    // u otro cajero) retoma el sync de lo pendiente.
    if (preservePending) {
      if (kIsWeb) {
        final queue = await _readQueue(businessId);
        final unsynced = queue
            .where((a) => a['status']?.toString() != _statusCompleted)
            .toList(growable: false);
        await _writeQueue(businessId, unsynced);
      } else {
        await _queueDao!.deleteCompletedActions(businessId);
      }
      return;
    }

    // 1. Cola de acciones (transaccional, contiene payloads de venta).
    if (kIsWeb) {
      await storage.delete(_queueKey(businessId));
    } else {
      // deleteAllPending borra TODAS las filas del business (cualquier
      // status), no solo pendientes — el nombre es histórico.
      await _queueDao!.deleteAllPending(businessId);
    }

    // 2. Snapshots de órdenes activas (montos, items, cuentas).
    await storage.deleteByPrefix('offline_snapshot_${businessId}_');
    // 2b. Cobros divididos a medias (montos, métodos, NCF offline).
    await const PaymentIntentJournal().deleteForBusiness(businessId);

    // 3. Mappings local→remoto y cola de impresión.
    await storage.delete(_orderMapKey(businessId));
    await storage.delete(_localOrderOpenerKey(businessId));
    await storage.delete(_itemMapKey(businessId));
    await storage.delete(_cashSessionMapKey(businessId));
    await storage.delete(_printQueueKey(businessId));

    // 4. Caches de lectura: solo en cambio de negocio. En logout se
    //    conservan para acelerar el re-login (no son sensibles).
    if (includeReadCaches) {
      await storage.delete('offline_catalog_$businessId');
      await storage.deleteByPrefix('offline_inventory_snapshot_${businessId}_');
      await storage.delete('offline_zones_snapshot_$businessId');
      // Nota: `offline_zone_status_snapshot_{zoneId}` está scopeado por
      // zona, no por negocio, así que no se puede targetear acá. Es cache
      // stale no sensible; se sobreescribe al cargar zonas del nuevo
      // negocio. Documentado como residual menor.
    }
  }

  Future<OfflineQueueSyncResult> syncPendingActions({
    required String businessId,
    required SalesRepository salesRepository,
    required PrintingService printingService,
    required InventoryRepository inventoryRepository,
    required CashierRepository cashierRepository,
    bool force = false,
  }) {
    final active = _queueSyncInFlight[businessId];
    if (active != null) return active;
    final run =
        _syncPendingActionsOnce(
          businessId: businessId,
          salesRepository: salesRepository,
          printingService: printingService,
          inventoryRepository: inventoryRepository,
          cashierRepository: cashierRepository,
          force: force,
        ).whenComplete(() {
          _queueSyncInFlight.remove(businessId);
        });
    _queueSyncInFlight[businessId] = run;
    return run;
  }

  Future<OfflineQueueSyncResult> _syncPendingActionsOnce({
    required String businessId,
    required SalesRepository salesRepository,
    required PrintingService printingService,
    required InventoryRepository inventoryRepository,
    required CashierRepository cashierRepository,
    required bool force,
  }) async {
    if (_hubUploader != null) return _flushPendingToHubOnce(businessId);
    final queue = await _readQueue(businessId);
    if (queue.isEmpty) {
      // Sin acciones pendientes → toda comanda offline ya se re-despachó
      // vía send_to_kitchen; limpiamos la cola de impresión stale.
      await _drainStalePrintQueue(businessId, queue);
      return const OfflineQueueSyncResult();
    }

    var processed = 0;
    var completed = 0;
    var failed = 0;
    var skipped = 0;
    var reconciled = 0;
    String? lastMappedOrderId;
    String? lastError;
    final conflicts = <OfflineSyncConflict>[];

    final completedOps = await _readCompletedOps(businessId);
    final completedFingerprints = await _readCompletedFingerprints(businessId);
    final blockedOrders = <String>{};

    for (var i = 0; i < queue.length; i++) {
      final action = queue[i];
      final orderId = action['order_id']?.toString();
      final actionId = action['id']?.toString();
      // Mismas reglas que hasActionsReadyToSync (ver _replayGate).
      switch (_replayGate(
        action,
        force: force,
        completedOps: completedOps,
        completedFingerprints: completedFingerprints,
        blockedOrders: blockedOrders,
      )) {
        case _ReplayGate.completed:
        case _ReplayGate.dead:
          continue;
        case _ReplayGate.hubOwned:
        case _ReplayGate.waitingRetry:
        case _ReplayGate.blockedBehind:
          skipped++;
          continue;
        case _ReplayGate.reconcile:
          queue[i] = Map<String, dynamic>.from(action)
            ..['status'] = _statusCompleted
            ..['completed_at'] =
                action['completed_at'] ?? DateTime.now().toIso8601String();
          await _upsertAction(businessId, queue[i]);
          reconciled++;
          continue;
        case _ReplayGate.replay:
          break;
      }

      final processing = await _withQueueMutation(businessId, () async {
        // La compactación pudo cambiar o cancelar esta acción mientras el
        // RPC anterior estaba en vuelo. Reclamar la versión vigente.
        final current = await _readQueue(businessId);
        final index = current.indexWhere((a) => a['id'] == actionId);
        if (index < 0 || _isCompleted(current[index])) return null;
        final claimed =
            _normalizeAction(Map<String, dynamic>.from(current[index]))
              ..['status'] = _statusProcessing
              ..['processing_started_at'] = DateTime.now().toIso8601String();
        await _upsertActionUnlocked(businessId, claimed);
        return claimed;
      });
      if (processing == null) continue;
      processed++;
      queue[i] = processing;
      // UPSERT puntual de la action que cambió de estado, en lugar de
      // reescribir la lista completa (O(n²) con N actions y N pasos).

      bool breakLoop = false;
      try {
        final mappedOrderId = await _replayAction(
          businessId: businessId,
          action: processing,
          salesRepository: salesRepository,
          printingService: printingService,
          inventoryRepository: inventoryRepository,
          cashierRepository: cashierRepository,
          conflicts: conflicts,
        );
        lastMappedOrderId = mappedOrderId ?? lastMappedOrderId;
        final done = Map<String, dynamic>.from(processing)
          ..['status'] = _statusCompleted
          ..['completed_at'] = DateTime.now().toIso8601String()
          ..['last_error'] = null;
        if (mappedOrderId != null && mappedOrderId.isNotEmpty) {
          done['resolved_order_id'] = mappedOrderId;
        }
        queue[i] = done;
        completed++;
        if (actionId != null && actionId.isNotEmpty) {
          await _markOpCompleted(businessId: businessId, opId: actionId);
        }
        final fingerprint = processing['fingerprint']?.toString();
        if (fingerprint != null && fingerprint.isNotEmpty) {
          await _markFingerprintCompleted(
            businessId: businessId,
            fingerprint: fingerprint,
          );
        }
      } on _KitchenRoundHold catch (hold) {
        // Comanda sin confirmar todavía: se conserva sin bloquear su orden.
        final attempts =
            ((processing['attempts'] as num?)?.toInt() ?? 0) +
            (hold.countsAttempt ? 1 : 0);
        lastError = hold.message;
        final dies =
            hold.terminal || (hold.countsAttempt && attempts >= maxAttempts);
        final updated = Map<String, dynamic>.from(processing)
          ..['attempts'] = attempts
          ..['last_error'] = hold.message
          ..['failed_at'] = DateTime.now().toIso8601String()
          ..['kitchen_hold'] = true;
        if (dies) {
          updated['status'] = _statusDead;
          updated['dead_at'] = DateTime.now().toIso8601String();
          updated.remove('next_retry_at');
        } else {
          updated['status'] = _statusFailed;
          updated['next_retry_at'] = DateTime.now()
              .add(Duration(seconds: _retryDelaySeconds(attempts < 1 ? 1 : attempts)))
              .toIso8601String();
        }
        queue[i] = updated;
        failed++;
      } on _OfflineSyncSkip catch (skip) {
        // Conflicto cross-device detectado: la accion ya no aplica porque
        // otro terminal modifico el mismo recurso (ej. item borrado).
        // Tratamos como completed (idempotente — el estado deseado ya
        // existe o la accion no tiene sentido) pero anotamos el conflicto
        // para que el cashier lo vea en el snackbar post-sync.
        conflicts.add(
          OfflineSyncConflict(
            actionType: processing['type']?.toString() ?? 'unknown',
            actionId: actionId,
            reason: skip.reason,
          ),
        );
        final done = Map<String, dynamic>.from(processing)
          ..['status'] = _statusCompleted
          ..['completed_at'] = DateTime.now().toIso8601String()
          ..['skip_reason'] = skip.reason
          ..['last_error'] = null;
        queue[i] = done;
        completed++;
        if (actionId != null && actionId.isNotEmpty) {
          await _markOpCompleted(businessId: businessId, opId: actionId);
        }
        final fingerprint = processing['fingerprint']?.toString();
        if (fingerprint != null && fingerprint.isNotEmpty) {
          await _markFingerprintCompleted(
            businessId: businessId,
            fingerprint: fingerprint,
          );
        }
      } catch (e) {
        final attempts = ((processing['attempts'] as num?)?.toInt() ?? 0) + 1;
        lastError = FriendlyError.from(e);
        final isConnectivity = _isConnectivityError(e);
        final isMissingRpc = _isMissingRpcError(e);
        if (isMissingRpc) {
          debugPrint(
            '[OfflinePos] AVISO: el servidor no tiene la función de '
            '${processing['type']} (PGRST202); falta aplicar su migración. '
            'Se reintenta sin mandarla a dead-letter. $e',
          );
        }
        // Dead-letter: si una acción NO de conectividad agotó sus
        // reintentos, deja de reintentar sola y pasa a estado terminal
        // `dead`. Los errores de conectividad NUNCA matan la acción —
        // son transitorios y no cuentan contra el tope (no hay culpa de
        // la acción si no hay red). Así un error permanente (constraint,
        // recurso borrado en server) no reintenta para siempre ni deja
        // el badge de pendientes pegado. Una función que aún no existe en
        // el servidor (PGRST202) tampoco la mata: se arregla aplicando la
        // migración, no tocando la acción.
        final shouldDie =
            !isConnectivity && !isMissingRpc && attempts >= maxAttempts;
        final updated = Map<String, dynamic>.from(processing)
          ..['attempts'] = attempts
          ..['last_error'] = lastError
          ..['failed_at'] = DateTime.now().toIso8601String();
        if (shouldDie) {
          updated['status'] = _statusDead;
          updated['dead_at'] = DateTime.now().toIso8601String();
          updated.remove('next_retry_at');
        } else {
          updated['status'] = _statusFailed;
          updated['next_retry_at'] = DateTime.now()
              .add(Duration(seconds: _retryDelaySeconds(attempts)))
              .toIso8601String();
        }
        queue[i] = updated;
        failed++;
        if (orderId != null) blockedOrders.add(orderId);
        // Solo cortar si fue por conectividad — todas las siguientes
        // van a fallar por lo mismo. Errores logicos (constraint, RPC
        // reject, item ya borrado por otro terminal) los saltamos para
        // no bloquear la cola; la accion fallida ya tiene su backoff
        // individual y reintenta sola en el siguiente trigger.
        breakLoop = isConnectivity;
      }

      // UPSERT puntual del action final (completed o failed). Idem
      // optimización anterior: evita reescribir la cola entera.
      await _upsertAction(businessId, queue[i]);
      if (breakLoop) break;
    }

    // Sin nada completado no hay qué podar: no reescribir (DELETE + INSERT
    // cifrado) la cola entera en cada pasada.
    if (completed > 0 || reconciled > 0) await _pruneQueue(businessId);
    final remaining = await _readQueue(businessId);
    await _drainStalePrintQueue(businessId, remaining);
    final pending = remaining.where((item) => !_isSettled(item)).length;
    final dead = remaining.where(_isDead).length;
    return OfflineQueueSyncResult(
      processed: processed,
      completed: completed,
      failed: failed,
      skipped: skipped,
      pending: pending,
      dead: dead,
      reconciled: reconciled,
      lastMappedOrderId: lastMappedOrderId,
      lastError: lastError,
      conflicts: List<OfflineSyncConflict>.unmodifiable(conflicts),
    );
  }

  /// Uplink único Hub→Supabase (F3b-3b). Cuando ESTE dispositivo es el Hub y
  /// vuelve la conexión, drena su op-log a Supabase replayando cada op EN
  /// ORDEN seq (FIFO) con la MISMA lógica que la cola por-device
  /// (`_replayAction` + markers de idempotencia + mappings local→remoto).
  ///
  /// Resolución de IDs entre terminales: el op-log trae `local-order-X` /
  /// `tmp_Y` de varios terminales. No hace falta un mecanismo nuevo: como el
  /// replay corre en orden seq, la primera op que referencia un id local
  /// crea el recurso en server y guarda el mapping en este dispositivo (el
  /// Hub); las ops siguientes lo resuelven. El FIFO garantiza creación antes
  /// que mutación.
  ///
  /// Idempotencia: usa `completed_ops`/`fingerprints` como la cola normal, así
  /// que re-correr es seguro. Solo limpia el op-log si todo subió sin fallos;
  /// si algo falló, lo deja para reintentar (los ya completados se saltan por
  /// marker). Uplink único = el Hub es el único que sube → cero duplicación.
  Future<OfflineQueueSyncResult> syncHubOpLog({
    required String businessId,
    required SalesRepository salesRepository,
    required PrintingService printingService,
    required InventoryRepository inventoryRepository,
    required CashierRepository cashierRepository,
  }) {
    // Una sola subida a la vez por negocio. En el Hub corren dos disparadores
    // (el drenaje de 4 s y las pasadas de sync de SalesViewModel): si se
    // pisaban, los dos leían la misma op pendiente antes de que alguno la
    // marcara completada y la subían dos veces. El segundo recibe el
    // resultado del primero.
    final running = _hubUplinkInFlight[businessId];
    if (running != null) return running;
    final run =
        _syncHubOpLogOnce(
          businessId: businessId,
          salesRepository: salesRepository,
          printingService: printingService,
          inventoryRepository: inventoryRepository,
          cashierRepository: cashierRepository,
        ).whenComplete(() {
          _hubUplinkInFlight.remove(businessId);
        });
    _hubUplinkInFlight[businessId] = run;
    return run;
  }

  Future<OfflineQueueSyncResult> _syncHubOpLogOnce({
    required String businessId,
    required SalesRepository salesRepository,
    required PrintingService printingService,
    required InventoryRepository inventoryRepository,
    required CashierRepository cashierRepository,
  }) async {
    // Marca de agua ANTES de leer: toda op con seq ≤ uplinkSeq está en `ops`.
    // Es el tope de la poda de abajo.
    final uplinkSeq = await _hubOpLog.currentSeq(businessId);
    final ops = await _hubOpLog.since(businessId); // orden seq (FIFO)
    if (ops.isEmpty) return const OfflineQueueSyncResult();

    // H7 — Candado 1: solo el equipo con ROL de Hub sube el op-log del Hub.
    //
    // Este método corre en TODO equipo: las pasadas de sync de SalesViewModel
    // lo llaman con kHubModeEnabled. Mientras la réplica al respaldo no funcionaba,
    // el op-log de cajas y respaldos estaba vacío y esto salía arriba. Con la
    // réplica funcionando, el RESPALDO tiene el op-log lleno de copias: sin
    // este candado las subía cada 3 minutos en paralelo con el Hub, y como la
    // BD no tiene llave de idempotencia cada venta se aplicaba dos veces. La
    // lease sola no alcanza: sin fila, el primero que confirma se la queda, y
    // podía ser el respaldo pasivo.
    final role = await HubConfigService().getDeviceRole(businessId);
    if (!hubUplinkAllowedForRole(role)) return const OfflineQueueSyncResult();

    final completedOps = await _readCompletedOps(businessId);
    final completedFingerprints = await _readCompletedFingerprints(businessId);
    final pendingOps = ops
        .where(
          (op) => !_isHubOpUploaded(op, completedOps, completedFingerprints),
        )
        .length;

    // H7 — Candado 2: la lease en Supabase, solo si hay algo que SUBIR. Si otro
    // equipo fue promovido a Hub, este NO sube y deja de actuar como Hub. Con el
    // log lleno solo de mesas abiertas ya aplicadas no se pregunta cada 4 s: el
    // latido de HubHostUplink la revisa aparte.
    if (pendingOps > 0) {
      final gate = await checkHubLease(businessId, pendingOps: pendingOps);
      switch (gate.decision) {
        case HubUplinkDecision.proceed:
          break;
        case HubUplinkDecision.skipRetryLater:
          return const OfflineQueueSyncResult();
        case HubUplinkDecision.stepDown:
          return OfflineQueueSyncResult(leaseLostToDeviceId: gate.holder ?? '');
      }
    }

    var processed = 0;
    var completed = 0;
    var failed = 0;
    String? lastMappedOrderId;
    String? lastError;
    final conflicts = <OfflineSyncConflict>[];

    final blockedOrders = <String>{};
    for (final op in ops) {
      final opId = op['op_id']?.toString() ?? op['id']?.toString();
      final fingerprint = op['fingerprint']?.toString();
      // Fix #1: op que el propio Hub host ya aplicó a Supabase (mutación online
      // espejada al op-log SOLO para visibilidad LAN) → NO re-subir; ya vive en
      // el server. Se cuenta como completada para la idempotencia/poda.
      if (op['hub_applied'] == true) {
        completed++;
        continue;
      }
      // Ya aplicada (re-run o subió antes) → idempotente, saltar.
      if ((opId != null && completedOps.contains(opId)) ||
          (_fingerprintWasCompleted(fingerprint, completedFingerprints))) {
        completed++;
        continue;
      }
      final orderId = op['order_id']?.toString();
      if (orderId != null && blockedOrders.contains(orderId)) continue;
      processed++;
      try {
        final mapped = await _replayAction(
          businessId: businessId,
          action: op,
          salesRepository: salesRepository,
          printingService: printingService,
          inventoryRepository: inventoryRepository,
          cashierRepository: cashierRepository,
          conflicts: conflicts,
        );
        lastMappedOrderId = mapped ?? lastMappedOrderId;
        completed++;
        if (opId != null && opId.isNotEmpty) {
          await _markOpCompleted(businessId: businessId, opId: opId);
        }
        if (fingerprint != null && fingerprint.isNotEmpty) {
          await _markFingerprintCompleted(
            businessId: businessId,
            fingerprint: fingerprint,
          );
        }
      } on _KitchenRoundHold catch (hold) {
        if (hold.terminal) {
          // El Hub no tiene dead-letter: se reporta sin confirmar nada.
          conflicts.add(
            OfflineSyncConflict(
              actionType: op['type']?.toString() ?? 'unknown',
              actionId: opId,
              reason: hold.message,
            ),
          );
          completed++;
          if (opId != null && opId.isNotEmpty) {
            await _markOpCompleted(businessId: businessId, opId: opId);
          }
        } else {
          // Se reintenta en la próxima subida, sin frenar su orden.
          failed++;
          lastError = hold.message;
        }
      } on _OfflineSyncSkip catch (skip) {
        // Conflicto cross-terminal: la op ya no aplica (item borrado, etc.).
        // Idempotente: la marcamos completada y reportamos.
        conflicts.add(
          OfflineSyncConflict(
            actionType: op['type']?.toString() ?? 'unknown',
            actionId: opId,
            reason: skip.reason,
          ),
        );
        completed++;
        if (opId != null && opId.isNotEmpty) {
          await _markOpCompleted(businessId: businessId, opId: opId);
        }
      } catch (e) {
        failed++;
        if (orderId != null) blockedOrders.add(orderId);
        lastError = FriendlyError.from(e);
        // Si volvió a caer la red, cortamos: el resto fallaría igual y se
        // reintenta en el próximo uplink (los completados se saltan).
        if (_isConnectivityError(e)) break;
      }
    }

    // Fix #2: solo podamos si todo subió (si algo falló lo conservamos para
    // reintentar; la idempotencia evita doble aplicación). Antes esto vaciaba
    // el op-log completo con clear() → borraba el estado vivo del salón que las
    // cajas cliente proyectan. Ahora conservamos las ops de las mesas AÚN
    // ABIERTAS (incl. las `hub_applied` del host) y podamos el resto: órdenes
    // cerradas/anuladas y ops sin order_id (caja/inventario) ya subidas.
    Set<String>? prunedKeep;
    var pruned = false;
    if (failed == 0) {
      final remaining = await _hubOpLog.since(businessId, seq: 0);
      final keep = HubOrderProjector.openOrderIds(remaining);
      // Tope `uplinkSeq`: lo que entró DURANTE esta subida todavía no subió y no
      // se puede podar, aunque su orden ya esté cerrada (venta rápida) o no
      // tenga orden (movimiento de caja). Antes se borraba sin llegar a Supabase.
      final quedan = await _hubOpLog.retainOrders(
        businessId,
        keep,
        upToSeq: uplinkSeq,
      );
      pruned = quedan < remaining.length;
      prunedKeep = keep;
    }

    // H7: avisar al respaldo qué ya está en Supabase, para que no lo repita si
    // lo promueven. Cuenta todo lo que este equipo dio por completado: aplicado
    // online por el host (`hub_applied`), subido en esta vuelta, o ya subido
    // antes (por op_id o por fingerprint). Lo que falló NO va: sigue pendiente.
    // Fire-and-forget: el respaldo es red de seguridad, no dependencia.
    final doneOps = await _readCompletedOps(businessId);
    final doneFingerprints = await _readCompletedFingerprints(businessId);
    final ackedOpIds = <String>{};
    for (final op in ops) {
      final id = _hubOpId(op);
      if (id != null && _isHubOpUploaded(op, doneOps, doneFingerprints)) {
        ackedOpIds.add(id);
      }
    }
    // Se manda cuando algo cambió, y al menos cada minuto aunque no: si un ack
    // se perdió (respaldo apagado un rato), la poda del siguiente lo corrige.
    final now = DateTime.now();
    final ackDue =
        _lastBackupAckAt == null ||
        now.difference(_lastBackupAckAt!) >= _backupAckEvery;
    if (ackedOpIds.isNotEmpty && (processed > 0 || pruned || ackDue)) {
      _lastBackupAckAt = now;
      unawaited(
        _ackBackup(
          businessId,
          ackedOpIds,
          keepOrderIds: prunedKeep,
          upToSeq: prunedKeep == null ? null : uplinkSeq,
        ),
      );
    }

    return OfflineQueueSyncResult(
      processed: processed,
      completed: completed,
      failed: failed,
      pending: failed,
      lastMappedOrderId: lastMappedOrderId,
      lastError: lastError,
      conflicts: List<OfflineSyncConflict>.unmodifiable(conflicts),
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // Cola y completed-ops: wrappers con branch web/nativo
  // ───────────────────────────────────────────────────────────────────
  // En nativo (Windows, macOS, Linux, Android, iOS) todas estas
  // operaciones van al DAO drift (`_queueDao!`) que es O(log n) por op.
  // En web, no podemos usar drift (no hay `dart:ffi`), así que caen
  // a SharedPreferences via `_storage`. SP es O(n) en cada op porque
  // serializa la lista entera, pero para cajeros web (caso secundario
  // del POS) el volumen es bajo y aceptable.

  Future<List<Map<String, dynamic>>> _readQueue(String businessId) async {
    if (kIsWeb) {
      final storage = await _storage;
      final raw = await storage.readList(_queueKey(businessId)) ?? const [];
      return raw
          .whereType<Object?>()
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: true);
    }
    await _ensureMigratedFromSp(businessId);
    return _queueDao!.readQueue(businessId);
  }

  Future<void> _writeQueue(
    String businessId,
    List<Map<String, dynamic>> queue,
  ) async {
    try {
      if (kIsWeb) {
        final storage = await _storage;
        final saved = await storage.writeList(_queueKey(businessId), queue);
        if (!saved) {
          throw StateError('No se pudo guardar la operación offline.');
        }
        return;
      }
      await _queueDao!.writeQueue(businessId, queue);
    } finally {
      _bumpQueueRevision(businessId);
    }
  }

  // Contador de escrituras de la cola y del mapping de órdenes, por negocio.
  // Ver [queueRevision].
  final Map<String, int> _queueRevisions = <String, int>{};

  /// Cambia cada vez que se agrega o se actualiza una acción de la cola de
  /// [businessId], o el mapping local→remoto de sus órdenes (borrar no cuenta:
  /// no puede crear pendientes). Si no cambió, lo que se leyó de la cola sigue
  /// valiendo: `_loadOrderDetail` lo usa para no volver a leer (y descifrar)
  /// la cola completa después de cada lectura del servidor.
  int queueRevision(String businessId) => _queueRevisions[businessId] ?? 0;

  void _bumpQueueRevision(String businessId) =>
      _queueRevisions[businessId] = queueRevision(businessId) + 1;

  /// H7: confirma la lease del Hub en Supabase. Si es de OTRO equipo (un
  /// respaldo fue promovido), cede: pasa este equipo a respaldo y lo registra.
  /// Lo usan el uplink, antes de subir, y el latido de HubHostUplink, para
  /// enterarse aunque no haya nada que subir.
  Future<({HubUplinkDecision decision, String? holder})> checkHubLease(
    String businessId, {
    int? pendingOps,
  }) async {
    final lease = await _hubLease.acquire(businessId);
    final decision = decideHubUplink(lease);
    if (decision == HubUplinkDecision.stepDown) {
      await _stepDownAfterLeaseLost(
        businessId,
        lease,
        pendingOps ?? await pendingHubUplinkCount(businessId),
      );
    }
    return (decision: decision, holder: lease.holderDeviceId);
  }

  /// Ops del op-log del Hub que todavía NO están en Supabase. Ajustes lo usa
  /// para no dejar que el Hub cambie de rol con ventas sin subir: solo el
  /// equipo con rol Hub las sube, así que quedarían varadas.
  Future<int> pendingHubUplinkCount(String businessId) async {
    final ops = await _hubOpLog.since(businessId);
    if (ops.isEmpty) return 0;
    final doneOps = await _readCompletedOps(businessId);
    final doneFingerprints = await _readCompletedFingerprints(businessId);
    return ops
        .where((op) => !_isHubOpUploaded(op, doneOps, doneFingerprints))
        .length;
  }

  /// Operaciones del Hub que aún no tienen confirmación durable en Supabase.
  /// La conciliación del salón no puede tratar un autocierre remoto como una
  /// anulación definitiva mientras estas operaciones conserven contenido.
  Future<List<Map<String, dynamic>>> unsettledHubActions(
    String businessId,
  ) async {
    final ops = await _hubOpLog.since(businessId);
    if (ops.length != await _hubOpLog.length(businessId)) {
      throw StateError('No se pudo leer toda la cola del Hub.');
    }
    if (ops.isEmpty) return const [];
    final doneOps = await _readCompletedOps(businessId);
    final doneFingerprints = await _readCompletedFingerprints(businessId);
    return ops
        .where((op) => !_isHubOpUploaded(op, doneOps, doneFingerprints))
        .map((op) => Map<String, dynamic>.unmodifiable(op))
        .toList(growable: false);
  }

  static String? _hubOpId(Map<String, dynamic> op) {
    final id = op['op_id']?.toString() ?? op['id']?.toString();
    return (id == null || id.isEmpty) ? null : id;
  }

  /// ¿La op ya está en Supabase? Aplicada online por el host (`hub_applied`) o
  /// subida antes (por op_id o por fingerprint). Mismo criterio con el que el
  /// loop de [syncHubOpLog] la salta.
  static bool _isHubOpUploaded(
    Map<String, dynamic> op,
    Set<String> doneOps,
    Set<String> doneFingerprints,
  ) {
    if (op['hub_applied'] == true) return true;
    final id = _hubOpId(op);
    if (id != null && doneOps.contains(id)) return true;
    final fp = op['fingerprint']?.toString();
    return _fingerprintWasCompleted(fp, doneFingerprints);
  }

  /// H7: marca como completadas ops que el Hub primario ya subió (llegan por
  /// `/hub/replica/ack` al respaldo). Si este equipo es promovido a Hub, su
  /// uplink las salta en vez de subirlas de nuevo. Devuelve cuántas marcó.
  Future<int> markHubOpsCompleted(
    String businessId,
    Iterable<String> opIds,
  ) async {
    var marcadas = 0;
    for (final id in opIds) {
      if (id.isEmpty) continue;
      await _markOpCompleted(businessId: businessId, opId: id);
      marcadas++;
    }
    return marcadas;
  }

  /// H7: otro equipo tiene la lease (un respaldo fue promovido). Este equipo NO
  /// sube, pasa a respaldo y deja registrado el porqué para que Ajustes → Red
  /// local lo explique. Su op-log NO se borra: lo que alcanzó a replicarse lo
  /// sube el Hub nuevo, y lo que no queda a salvo en este disco y visible en el
  /// aviso — en vez de subirse dos veces.
  Future<void> _stepDownAfterLeaseLost(
    String businessId,
    HubLeaseResult lease,
    int pendingOps,
  ) async {
    debugPrint(
      '[HubUplink] la lease la tiene ${lease.holderDeviceId}: este equipo deja '
      'de ser el Hub y NO sube ($pendingOps ops quedan en su disco).',
    );
    try {
      final config = HubConfigService();
      await config.setDeviceRole(businessId, HubDeviceRole.hubBackup);
      await config.writeLeaseLost(
        businessId,
        holderDeviceId: lease.holderDeviceId,
        epoch: lease.epoch,
        pendingOps: pendingOps,
      );
    } catch (e) {
      debugPrint('[HubUplink] no se pudo registrar la cesión del Hub: $e');
    }
  }

  /// Manda al respaldo configurado el ack de lo ya subido. Best-effort.
  Future<void> _ackBackup(
    String businessId,
    Set<String> opIds, {
    Set<String>? keepOrderIds,
    int? upToSeq,
  }) async {
    try {
      final backupUrl = await HubConfigService().getBackupUrl(businessId);
      if (backupUrl == null || backupUrl.isEmpty) return;
      await HubClient().ackReplica(
        backupUrl,
        businessId: businessId,
        completedOpIds: opIds,
        keepOrderIds: keepOrderIds,
        upToSeq: upToSeq,
      );
    } catch (_) {
      // Best-effort: el ack nunca puede afectar el uplink del Hub.
    }
  }

  Future<void> _markOpCompleted({
    required String businessId,
    required String opId,
  }) async {
    if (kIsWeb) {
      final storage = await _storage;
      final current =
          (await storage.readList(_completedOpsKey(businessId)) ?? const [])
              .map((e) => e.toString())
              .toSet();
      if (!current.add(opId)) return;
      await storage.writeList(_completedOpsKey(businessId), current.toList());
      return;
    }
    await _queueDao!.markOpCompleted(businessId: businessId, opId: opId);
  }

  Future<void> _markFingerprintCompleted({
    required String businessId,
    required String fingerprint,
  }) async {
    if (kIsWeb) {
      final storage = await _storage;
      final current =
          (await storage.readList(_completedFingerprintsKey(businessId)) ??
                  const [])
              .map((e) => e.toString())
              .toSet();
      if (!current.add(fingerprint)) return;
      await storage.writeList(
        _completedFingerprintsKey(businessId),
        current.toList(),
      );
      return;
    }
    await _queueDao!.markFingerprintCompleted(
      businessId: businessId,
      fingerprint: fingerprint,
    );
  }

  Future<Set<String>> _readCompletedOps(String businessId) async {
    if (kIsWeb) {
      final storage = await _storage;
      final raw =
          await storage.readList(_completedOpsKey(businessId)) ?? const [];
      return raw.map((e) => e.toString()).toSet();
    }
    return _queueDao!.readCompletedOps(businessId);
  }

  Future<Set<String>> _readCompletedFingerprints(String businessId) async {
    if (kIsWeb) {
      final storage = await _storage;
      final raw =
          await storage.readList(_completedFingerprintsKey(businessId)) ??
          const [];
      return raw.map((e) => e.toString()).toSet();
    }
    return _queueDao!.readCompletedFingerprints(businessId);
  }

  Future<void> _upsertAction(String businessId, Map<String, dynamic> action) =>
      _withQueueMutation(
        businessId,
        () => _upsertActionUnlocked(businessId, action),
      );

  Future<void> _upsertActionUnlocked(
    String businessId,
    Map<String, dynamic> action,
  ) async {
    if (kIsWeb) {
      // SP no soporta upsert atómico — read+modify+write completo.
      final queue = await _readQueue(businessId);
      final id = action['id']?.toString();
      if (id == null || id.isEmpty) return;
      final idx = queue.indexWhere((a) => a['id']?.toString() == id);
      if (idx >= 0) {
        queue[idx] = action;
      } else {
        queue.add(action);
      }
      await _writeQueue(businessId, queue);
      return;
    }
    try {
      await _queueDao!.upsertAction(businessId, action);
    } finally {
      _bumpQueueRevision(businessId);
    }
  }

  Future<void> _pruneCompletedOlderThan(Duration olderThan) async {
    if (kIsWeb) {
      // En web los completed_ops/fingerprints van a SP — no hay índice
      // por fecha. Estrategia simple: cap por count en lugar de tiempo.
      // El cap real lo hacían los métodos legacy con `length > 500`.
      // Acá no podemos saber la fecha de cada entrada, así que ignoramos
      // el prune en web — la lista crece linealmente pero las apps web
      // del POS tienen volumen bajo.
      return;
    }
    await _queueDao!.pruneCompletedOlderThan(olderThan);
  }

  Map<String, dynamic> _normalizeAction(Map<String, dynamic> action) {
    final normalized = {
      'id': action['id']?.toString() ?? 'offline-op-${_uuid.v4()}',
      'type': action['type'],
      'status': action['status']?.toString() ?? _statusPending,
      'attempts': (action['attempts'] as num?)?.toInt() ?? 0,
      'queued_at': action['queued_at'] ?? DateTime.now().toIso8601String(),
      ...action,
    };
    if (action['type'] == 'kds_item_status' &&
        const {'preparing', 'ready', 'served'}.contains(action['status'])) {
      normalized['kds_status'] = action['kds_status'] ?? action['status'];
      normalized['status'] = _statusPending;
    }
    normalized['fingerprint'] =
        action['fingerprint']?.toString() ??
        _buildActionFingerprint(normalized);
    return normalized;
  }

  // Dos rondas idénticas de cocina (o dos cobros por el mismo importe)
  // son intenciones distintas. Solo el ID estable identifica un reintento.
  String _buildActionFingerprint(Map<String, dynamic> action) =>
      'op:${action['op_id'] ?? action['id']}';

  static bool _fingerprintWasCompleted(
    String? fingerprint,
    Set<String> completed,
  ) =>
      fingerprint != null &&
      fingerprint.startsWith('op:') &&
      completed.contains(fingerprint);

  /// ¿Hay un envío a cocina en la cola DESPUÉS del alta en [addIndex]?
  ///
  /// No filtra por orden a propósito: la misma orden puede ir con id local o
  /// del servidor según la acción. Si el envío era de otra orden, el ítem
  /// llega como borrador y se borra como borrador: sin registro ni aviso.
  static bool _kitchenSentAfter(
    List<Map<String, dynamic>> queue,
    int addIndex,
  ) {
    for (var i = addIndex + 1; i < queue.length; i++) {
      final type = queue[i]['type'];
      if (type == 'send_to_kitchen' || type == 'confirm_local_order') {
        return true;
      }
    }
    return false;
  }

  List<Map<String, dynamic>> _compactQueue(List<Map<String, dynamic>> queue) {
    final result = <Map<String, dynamic>>[];

    for (final raw in queue) {
      final action = Map<String, dynamic>.from(raw);
      // Dejamos pasar intactas las resueltas (completed/dead) y las que
      // están en proceso: no se fusionan ni se cancelan con acciones
      // nuevas. Una dead-letter no debe absorber un add nuevo del mismo
      // item temporal.
      if (_isSettled(action) ||
          action['status'] == _statusProcessing ||
          action['hub_delivery_started'] == true) {
        result.add(action);
        continue;
      }

      final type = action['type']?.toString();
      final itemId = action['item_id']?.toString();
      final orderId = action['order_id']?.toString();

      if (itemId != null && itemId.startsWith('tmp_')) {
        final addIndex = result.lastIndexWhere(
          (entry) =>
              !_isSettled(entry) &&
              entry['status'] != _statusProcessing &&
              entry['hub_delivery_started'] != true &&
              entry['item_snapshot'] == null &&
              ((entry['attempts'] as num?)?.toInt() ?? 0) == 0 &&
              entry['type'] == 'add_item' &&
              entry['item_id']?.toString() == itemId,
        );

        if (addIndex >= 0) {
          final base = Map<String, dynamic>.from(result[addIndex]);
          // Si la comanda ya salió (impresa en local) después del alta,
          // quitar el producto o bajarle la cantidad NO se funde con el alta
          // como si nunca hubiera existido: viaja al servidor tal cual, que
          // lo registra y le avisa al dueño (20261007_0001).
          final sentToKitchen = _kitchenSentAfter(result, addIndex);
          if (type == 'delete_item' && !sentToKitchen) {
            result.removeAt(addIndex);
            continue;
          }
          if (type == 'update_item_quantity' && !sentToKitchen) {
            base['qty'] = action['quantity'] ?? action['qty'] ?? base['qty'];
            result[addIndex] = base;
            continue;
          }
          if (type == 'update_item_notes') {
            base['notes'] = action['notes'];
            result[addIndex] = base;
            continue;
          }
          if (type == 'toggle_item_takeout') {
            base['takeout'] = action['is_takeout'] == true;
            result[addIndex] = base;
            continue;
          }
          if (type == 'move_item_to_check') {
            base['check_pos'] = action['check_pos'] ?? base['check_pos'];
            result[addIndex] = base;
            continue;
          }
        }
      }

      int existingIndex = -1;
      if (type == 'mark_order_takeout' &&
          orderId != null &&
          orderId.isNotEmpty) {
        existingIndex = result.lastIndexWhere(
          (entry) =>
              !_isSettled(entry) &&
              entry['status'] != _statusProcessing &&
              entry['hub_delivery_started'] != true &&
              entry['type'] == 'mark_order_takeout' &&
              entry['order_id']?.toString() == orderId,
        );
      } else if ({
            'update_item_quantity',
            'update_item_notes',
            'toggle_item_takeout',
            'move_item_to_check',
          }.contains(type) &&
          itemId != null &&
          itemId.isNotEmpty) {
        existingIndex = result.lastIndexWhere(
          (entry) =>
              !_isSettled(entry) &&
              entry['status'] != _statusProcessing &&
              entry['hub_delivery_started'] != true &&
              entry['type'] == type &&
              entry['item_id']?.toString() == itemId,
        );
        // Una cantidad nueva no reemplaza a una de ANTES del envío a cocina:
        // quedaría aplicada antes del envío y el servidor nunca vería que se
        // quitó algo que cocina ya imprimió.
        if (type == 'update_item_quantity' &&
            existingIndex >= 0 &&
            _kitchenSentAfter(result, existingIndex)) {
          existingIndex = -1;
        }
      }

      if (existingIndex >= 0) {
        result[existingIndex] = action;
      } else {
        result.add(action);
      }
    }

    return result;
  }

  bool _isCompleted(Map<String, dynamic> action) =>
      action['status']?.toString() == _statusCompleted;

  bool _isDead(Map<String, dynamic> action) =>
      action['status']?.toString() == _statusDead;

  /// Una acción "resuelta" ya no espera sincronización automática: o se
  /// completó, o murió (dead-letter). El badge de pendientes y el prune
  /// usan esto para no contar lo que no va a reintentar solo.
  bool _isSettled(Map<String, dynamic> action) =>
      _isCompleted(action) || _isDead(action);

  bool _isReadyToRetry(Map<String, dynamic> action) {
    final nextRetryAt = action['next_retry_at']?.toString();
    if (nextRetryAt == null || nextRetryAt.isEmpty) return true;
    final parsed = DateTime.tryParse(nextRetryAt);
    if (parsed == null) return true;
    return !parsed.isAfter(DateTime.now());
  }

  /// Decide qué hace la pasada a la nube con [action]. Única fuente de las
  /// reglas de elegibilidad: la usan [_syncPendingActionsOnce] y
  /// [hasActionsReadyToSync], así el uplink no despierta por algo que la
  /// pasada va a saltar. Anota en [blockedOrders] las órdenes que dejan de
  /// avanzar en esta pasada (el orden de las reglas importa: la conciliación
  /// por marcador va antes del backoff y del bloqueo por orden).
  _ReplayGate _replayGate(
    Map<String, dynamic> action, {
    required bool force,
    required Set<String> completedOps,
    required Set<String> completedFingerprints,
    required Set<String> blockedOrders,
  }) {
    final orderId = action['order_id']?.toString();
    // Las completadas nunca se reprocesan. Las dead-letter no reintentan
    // en el sync automático, pero en el manual (force = botón
    // "Sincronizar ahora") se les da otra oportunidad: el cajero pidió
    // sincronizar la cola completa, no solo lo pendiente.
    if (_isCompleted(action)) return _ReplayGate.completed;
    // The Hub may have committed despite a lost reply. Only resend there,
    // never replay this operation independently against the cloud.
    if (action['hub_delivery_started'] == true) {
      if (orderId != null) blockedOrders.add(orderId);
      return _ReplayGate.hubOwned;
    }
    final kitchenHold = action['kitchen_hold'] == true;
    if (!force && _isDead(action)) {
      if (orderId != null && !kitchenHold) blockedOrders.add(orderId);
      return _ReplayGate.dead;
    }
    final actionId = action['id']?.toString();
    if ((actionId != null && completedOps.contains(actionId)) ||
        _fingerprintWasCompleted(
          action['fingerprint']?.toString(),
          completedFingerprints,
        )) {
      return _ReplayGate.reconcile;
    }
    if (!force && !_isReadyToRetry(action)) {
      if (orderId != null && !kitchenHold) blockedOrders.add(orderId);
      return _ReplayGate.waitingRetry;
    }
    if (orderId != null && blockedOrders.contains(orderId)) {
      return _ReplayGate.blockedBehind;
    }
    return _ReplayGate.replay;
  }

  /// Órdenes que la nube ya empezó a recibir (un intento previo, o una
  /// reclamación que quedó a medias). En modo Hub no pasan a otra autoridad.
  Set<String> _cloudOwnedOrders(List<Map<String, dynamic>> queue) => queue
      .where(
        (action) =>
            ((action['attempts'] as num?)?.toInt() ?? 0) > 0 ||
            (action['status'] == _statusProcessing &&
                action['hub_delivery_started'] != true),
      )
      .map((action) => action['order_id']?.toString())
      .whereType<String>()
      .toSet();

  /// Regla del drenaje al Hub (la comparte [hasActionsReadyToSync]): una
  /// acción dead, ya intentada contra la nube o de una orden que la nube ya
  /// empezó a recibir no se manda al Hub.
  bool _isCloudOwned(
    Map<String, dynamic> action,
    Set<String> cloudOwnedOrders,
  ) =>
      _isDead(action) ||
      cloudOwnedOrders.contains(action['order_id']?.toString()) ||
      ((action['attempts'] as num?)?.toInt() ?? 0) > 0 ||
      (action['status'] == _statusProcessing &&
          action['hub_delivery_started'] != true);

  int _retryDelaySeconds(int attempt) {
    if (attempt <= 1) return 3;
    if (attempt == 2) return 8;
    if (attempt == 3) return 15;
    return 30;
  }

  Future<String?> _replayAction({
    required String businessId,
    required Map<String, dynamic> action,
    required SalesRepository salesRepository,
    required PrintingService printingService,
    required InventoryRepository inventoryRepository,
    required CashierRepository cashierRepository,
    required List<OfflineSyncConflict> conflicts,
  }) async {
    final type = action['type']?.toString();
    switch (type) {
      case 'open_cash_session':
        // Llamamos al RPC real. El response lleva `session_id` (uuid
        // remoto). Guardamos el mapping local→remoto para que los
        // payments encolados después con cashier_session_id local
        // puedan traducirse al remoto en su propio replay.
        Map<String, dynamic> response;
        try {
          response = await cashierRepository.openSession(
            cashRegisterId: action['cash_register_id']?.toString() ?? '',
            userId: action['user_id']?.toString() ?? '',
            startAmount: ((action['start_amount'] ?? 0) as num).toDouble(),
            deviceId: action['device_id']?.toString() ?? '',
            deviceName: action['device_name']?.toString(),
          );
        } on CashRegisterException catch (e) {
          // Mientras este equipo estaba sin red, ya habia una caja abierta en
          // el server que le tocaba (modo "1 sola caja", o la del mismo
          // cajero/equipo). Sin esto la apertura local moria y arrastraba
          // cada cobro encolado contra su id local. Solo se adopta si el
          // server confirma que esa caja es de ESTE negocio.
          final existing = e.existingSessionId;
          if (existing == null ||
              existing.isEmpty ||
              e.existingBusinessId != businessId) {
            rethrow;
          }
          debugPrint(
            '[offline] open_cash_session: ya habia caja abierta '
            '($existing, ${e.errorCode}); los cobros locales se cuelgan de '
            'ella. Monto de apertura local descartado: '
            '${action['start_amount']}',
          );
          response = {'session_id': existing};
        }
        final remoteSessionId = response['session_id']?.toString();
        final localSessionId = action['local_session_id']?.toString();
        if (remoteSessionId != null &&
            remoteSessionId.isNotEmpty &&
            localSessionId != null &&
            localSessionId.isNotEmpty) {
          await _saveCashSessionMapping(
            businessId: businessId,
            localSessionId: localSessionId,
            remoteSessionId: remoteSessionId,
          );
        }
        return null;
      case 'close_cash_session':
        // Cierre encolado cuando el cajero confirmó el cierre (con o sin
        // varianza) pero la red se cayó mid-call. El cashier UI ya vio el
        // resumen y considera la caja cerrada localmente; este replay
        // garantiza que el server quede en el mismo estado.
        //
        // Resolución del session_id: si el cajero abrió caja offline, el
        // id que tenemos es `local-cash-session-X` y hay que traducirlo
        // al uuid remoto via el mapping guardado en open_cash_session.
        // FIFO de la cola garantiza que open_cash_session ya pasó.
        var closeSessionId = action['session_id']?.toString() ?? '';
        if (closeSessionId.startsWith('local-cash-session-')) {
          final sessionMap = await _readCashSessionMap(businessId);
          final remote = sessionMap[closeSessionId]?.toString();
          if (remote == null || remote.isEmpty) {
            throw Exception(
              'No se pudo resolver la sesión de caja local '
              '$closeSessionId al cerrarla. ¿open_cash_session se replayó?',
            );
          }
          closeSessionId = remote;
        }
        try {
          await cashierRepository.closeSession(
            sessionId: closeSessionId,
            endAmount: ((action['end_amount'] ?? 0) as num).toDouble(),
            notes: action['notes']?.toString(),
            forceWithOpenTables: action['force_with_open_tables'] == true,
          );
        } on CashRegisterException catch (e) {
          // Si la sesión ya está cerrada (otro terminal / replay duplicado)
          // tratamos el action como completado: el estado deseado ya se
          // cumple (sesión cerrada). El resto de excepciones de negocio
          // (OPEN_TABLES_EXIST, SESSION_NOT_FOUND) sí las propagamos para
          // que el cajero las vea en el sync result.
          if (e.errorCode == 'SESSION_ALREADY_CLOSED') {
            throw _OfflineSyncSkip(
              'Sesión $closeSessionId ya estaba cerrada en server.',
            );
          }
          rethrow;
        }
        return null;
      case 'cash_transaction':
        // Movimiento manual de caja (depósito/retiro/gasto) encolado sin
        // red. Resolvemos el session_id local→remoto igual que
        // close_cash_session; el FIFO de la cola garantiza que
        // open_cash_session ya se replayó antes.
        //
        // Limitación v1: el RPC fn_cash_transaction_create estampa
        // created_at = now() (no acepta timestamp), así que el movimiento
        // queda fechado al momento del sync, no al offline. La sesión a la
        // que pertenece sí es la correcta (se pasa explícita). Si la razón
        // exigía aprobación de supervisor y no se capturó offline, el RPC
        // la rechaza y la acción cae a dead-letter (visible al cajero) —
        // nunca se omite la validación.
        var txnSessionId = action['session_id']?.toString() ?? '';
        if (txnSessionId.startsWith('local-cash-session-')) {
          final sessionMap = await _readCashSessionMap(businessId);
          final remote = sessionMap[txnSessionId]?.toString();
          if (remote == null || remote.isEmpty) {
            throw Exception(
              'No se pudo resolver la sesión de caja local $txnSessionId '
              'para el movimiento. ¿open_cash_session se replayó?',
            );
          }
          txnSessionId = remote;
        }
        await cashierRepository.createManualTransaction(
          sessionId: txnSessionId,
          amount: ((action['amount'] ?? 0) as num).toDouble(),
          type: action['cash_type']?.toString() ?? 'withdrawal',
          reasonCode: action['reason_code']?.toString() ?? '',
          description: action['description']?.toString(),
          createdBy: action['created_by']?.toString(),
          approvedBy: action['approved_by']?.toString(),
        );
        return null;
      case 'inventory_adjust':
        // El RPC fn_inventory_adjust calcula delta server-side con FOR
        // UPDATE: si otro terminal tocó el stock mientras estábamos
        // offline, el server toma el conteo físico que el cajero
        // ingresó (LWW) y emite el movement con su created_at real al
        // sync. El cache local ya fue actualizado optimísticamente.
        await inventoryRepository.adjustInventory(
          queueOnNetworkFailure: false,
          businessId: businessId,
          warehouseId: action['warehouse_id']?.toString() ?? '',
          itemId: action['item_id']?.toString() ?? '',
          countedQuantity: ((action['counted_quantity'] ?? 0) as num)
              .toDouble(),
          reasonCode: action['reason_code']?.toString() ?? 'other',
          notes: action['notes']?.toString(),
          costPerUnit: action['cost_per_unit'] == null
              ? null
              : (action['cost_per_unit'] as num).toDouble(),
        );
        return null;
      case 'inventory_movement':
        final movementCost = action['cost_per_unit'] == null
            ? null
            : (action['cost_per_unit'] as num).toDouble();
        final outflowReason = action['reason_code']?.toString();
        final operationId = action['reference_id']?.toString();
        if (action['reference_type']?.toString() == 'manual_outflow' &&
            outflowReason != null &&
            outflowReason.isNotEmpty) {
          // Salida / merma: por la función de salidas, con su motivo y su
          // llave. Si la réplica ya había llegado y solo se perdió la
          // respuesta, el servidor la reconoce y no resta dos veces.
          await inventoryRepository.recordOutflow(
            queueOnNetworkFailure: false,
            businessId: businessId,
            warehouseId: action['warehouse_id']?.toString() ?? '',
            itemId: action['item_id']?.toString() ?? '',
            quantity: ((action['quantity'] ?? 0) as num).toDouble(),
            reasonCode: outflowReason,
            // La nota ya viene armada ("Vencido — …").
            reasonLabel: '',
            notes: action['notes']?.toString(),
            costPerUnit: movementCost,
            operationId: operationId,
            destination: action['destination']?.toString(),
          );
          return null;
        }
        await inventoryRepository.recordMovement(
          queueOnNetworkFailure: false,
          businessId: businessId,
          warehouseId: action['warehouse_id']?.toString() ?? '',
          itemId: action['item_id']?.toString() ?? '',
          movementType: action['movement_type']?.toString() ?? 'adjustment_out',
          quantity: ((action['quantity'] ?? 0) as num).toDouble(),
          costPerUnit: movementCost,
          notes: action['notes']?.toString(),
          referenceType: action['reference_type']?.toString(),
          referenceId: operationId,
        );
        return null;
      case 'open_table':
        // H4 (modo hub): la caja abrió una mesa como borrador local y notificó
        // al Hub. Al subir a Supabase abrimos la mesa REAL y guardamos el
        // mapping local→remoto; los add_item siguientes (en orden seq)
        // resuelven vía ese mapping. Idempotente: si ya existe el mapping,
        // _resolveOrderIdForAction lo devuelve sin recrear la mesa.
        return await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
      case 'kds_item_status':
        // H6: cambio de estado del KDS hecho sin nube (preparing/ready/served).
        // Al subir, resolvemos el ítem real (tmp→uuid vía mapping) y
        // actualizamos su status + timestamp (igual que KitchenRepository).
        // `served` se persiste como `ready` (el ítem ya se despachó). Es
        // best-effort: si el ítem ya no existe (borrado en otra caja), se
        // ignora — idempotente.
        try {
          final kdsItemId = await _resolveItemIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
          final rawStatus = (action['kds_status'] ?? action['status'])
              ?.toString();
          if (!const {'preparing', 'ready', 'served'}.contains(rawStatus)) {
            throw StateError(
              'OFFLINE_KDS_STATUS_REQUIRED: falta el estado de cocina.',
            );
          }
          final status = rawStatus == 'served' ? 'ready' : rawStatus;
          await salesRepository.updateOfflineKitchenItemStatus(
            itemId: kdsItemId,
            status: status!,
            at: DateTime.tryParse('${action['queued_at']}') ?? DateTime.now(),
          );
          return kdsItemId;
        } catch (e) {
          if (_isItemMissingError(e)) {
            throw _OfflineSyncSkip(
              'El item de cocina ya no existe en el servidor.',
            );
          }
          rethrow;
        }
      case 'add_item':
        final resolvedOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        final localItemId = action['item_id']?.toString();
        final itemMap = await _readItemMap(businessId);
        final existingItemId = itemMap[localItemId]?.toString();
        var itemExists = true;
        final String createdItemId;
        if (existingItemId != null && existingItemId.isNotEmpty) {
          createdItemId = existingItemId;
        } else {
          // Mismo client_op_id que el intento online / proxy del Hub: si ese
          // intento sí hizo commit (respuesta perdida), el servidor devuelve
          // el MISMO ítem en vez de crear otro (20260929_0001).
          final snapshot = action['item_snapshot'];
          final added = await salesRepository.addItemFromMenuIdempotent(
            clientOpId: addItemClientOpId(action),
            orderId: resolvedOrderId,
            menuItemId: action['menu_item_id']?.toString() ?? '',
            quantity: ((action['qty'] ?? 1) as num).toDouble(),
            checkPosition: (action['check_pos'] as num?)?.toInt() ?? 1,
            isTakeout: action['takeout'] == true,
            notes: action['notes']?.toString(),
            createdByEmployeeId: snapshot is Map
                ? snapshot['created_by_employee_id']?.toString()
                : null,
          );
          createdItemId = added.itemId;
          itemExists = added.itemExists;
        }
        if (localItemId != null && localItemId.isNotEmpty) {
          await _saveItemMapping(
            businessId: businessId,
            localItemId: localItemId,
            remoteItemId: createdItemId,
          );
          await remapSnapshotItemId(
            businessId: businessId,
            localItemId: localItemId,
            remoteItemId: createdItemId,
          );
        }

        // Re-aplicar modifiers seleccionados al item recién creado en el
        // server. La acción los lleva como snapshot en `selected_modifiers`
        // (List<{name, qty, price, menu_item_id?, modifier_id?}>). Antes esto se
        // perdía: la orden offline
        // llegaba al server SIN modifiers, dejando totales inconsistentes.
        // Ítem creado y después borrado (el op ya se aplicó una vez): sus
        // extras no se re-aplican; el alta queda saldada tal cual.
        final rawModifiers = action['selected_modifiers'];
        if (itemExists && rawModifiers is List && rawModifiers.isNotEmpty) {
          final modifiers = rawModifiers
              .whereType<Map>()
              .map<Map<String, dynamic>>((m) => Map<String, dynamic>.from(m))
              .toList(growable: false);
          if (modifiers.isNotEmpty) {
            try {
              // Retry the initial snapshot on the SAME mapped item, rather
              // than inserting the item or its modifiers a second time.
              await salesRepository.replaceOrderItemModifiers(
                itemId: createdItemId,
                modifiers: modifiers,
              );
            } catch (e) {
              // Keep the action pending and block dependent operations. A
              // partial item must not be treated as a fully synchronized sale.
              debugPrint(
                'Offline sync: error agregando modifiers a $createdItemId: $e',
              );
              final productName =
                  action['product_name']?.toString().trim() ?? 'un item';
              conflicts.add(
                OfflineSyncConflict(
                  actionType: 'add_item_modifier',
                  actionId: action['id']?.toString(),
                  reason:
                      'Los modificadores de "$productName" siguen pendientes. '
                      'No se sincronizara el cobro de esta orden hasta resolverlos.',
                ),
              );
              rethrow;
            }
          }
        }
        return resolvedOrderId;
      case 'delete_item':
        // Tombstone: delete es idempotente. Si el item ya no existe
        // (probablemente otro terminal lo borro mientras estabamos
        // offline) el estado deseado ya se cumple → no hay conflicto
        // que notificar al cajero, terminamos como completed silente.
        try {
          final resolvedItemId = await _resolveItemIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
          await salesRepository.deleteItem(itemId: resolvedItemId);
          // Motivo y operador del borrado (20260919_0002). Nunca lanza.
          await salesRepository.noteItemRemoval(
            itemId: resolvedItemId,
            reason: action['reason']?.toString(),
            employeeId: action['employee_id']?.toString(),
            reasonCode: action['reason_code']?.toString(),
            isWaste: action['is_waste'] as bool?,
          );
        } catch (e) {
          if (!_isItemMissingError(e)) rethrow;
        }
        try {
          return await _resolveOrderIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
        } catch (_) {
          return null;
        }
      case 'update_item_quantity':
        try {
          final resolvedItemId = await _resolveItemIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
          await salesRepository.updateItemQuantity(
            itemId: resolvedItemId,
            quantity: ((action['quantity'] ?? action['qty'] ?? 1) as num)
                .toDouble(),
          );
        } catch (e) {
          if (_isItemMissingError(e)) {
            throw _OfflineSyncSkip(
              'No se pudo actualizar la cantidad de un item: ya fue eliminado por otro terminal.',
            );
          }
          rethrow;
        }
        try {
          return await _resolveOrderIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
        } catch (_) {
          return null;
        }
      case 'update_item_notes':
        try {
          final resolvedItemId = await _resolveItemIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
          await salesRepository.updateItemNotes(
            itemId: resolvedItemId,
            notes: action['notes']?.toString() ?? '',
          );
        } catch (e) {
          if (_isItemMissingError(e)) {
            throw _OfflineSyncSkip(
              'No se pudo actualizar la nota de un item: ya fue eliminado por otro terminal.',
            );
          }
          rethrow;
        }
        try {
          return await _resolveOrderIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
        } catch (_) {
          return null;
        }
      case 'toggle_item_takeout':
        try {
          final resolvedItemId = await _resolveItemIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
          await salesRepository.toggleItemTakeout(
            itemId: resolvedItemId,
            isTakeout: action['is_takeout'] == true,
          );
        } catch (e) {
          if (_isItemMissingError(e)) {
            throw _OfflineSyncSkip(
              'No se pudo cambiar para-llevar de un item: ya fue eliminado por otro terminal.',
            );
          }
          rethrow;
        }
        try {
          return await _resolveOrderIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
        } catch (_) {
          return null;
        }
      case 'move_item_to_check':
        try {
          final resolvedItemId = await _resolveItemIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
          await salesRepository.moveItemToCheck(
            itemId: resolvedItemId,
            checkPosition: (action['check_pos'] as num?)?.toInt() ?? 1,
          );
        } catch (e) {
          if (_isItemMissingError(e)) {
            throw _OfflineSyncSkip(
              'No se pudo mover un item a otra cuenta: ya fue eliminado por otro terminal.',
            );
          }
          rethrow;
        }
        try {
          return await _resolveOrderIdForAction(
            businessId: businessId,
            action: action,
            salesRepository: salesRepository,
          );
        } catch (_) {
          return null;
        }
      case 'mark_order_takeout':
        final resolvedOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        await salesRepository.markOrderTakeout(
          orderId: resolvedOrderId,
          takeout: action['takeout'] == true,
        );
        return resolvedOrderId;
      case 'void_order':
        // Anulación encolada cuando el cajero tocó "Anular orden" pero la
        // red se cayó antes/durante el closeOrder. La UI ya consideró la
        // orden anulada localmente (reset del state); este replay
        // garantiza que el server quede en el mismo estado.
        //
        // El RPC fn_close_order_and_table anula la orden pero no escribe la
        // razón. Tras anular, persistimos la nota de auditoría aparte
        // (F2.3) con el actor/timestamp capturados al momento del void, no
        // los del sync. Best-effort: si la nota falla no rompemos la
        // anulación (lo crítico es que la orden quede void).
        final voidOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        // Un void encolado nunca anula una venta cobrada (ni con cobros
        // parciales): se encoló sobre una pantalla o un respaldo previos al
        // cobro. fn_void_order_if_unpaid (20261009_0007) comprueba y anula en
        // una sola transacción con la orden bloqueada, como el cobro, así que
        // otra caja que cobre al mismo tiempo nunca queda anulada. annulOrder
        // (la anulación explícita con motivo) no pasa por la cola. Cubre
        // también el op-log del Hub, que comparte este replay.
        String? guardedResult;
        try {
          guardedResult = await salesRepository.voidOrderIfUnpaid(voidOrderId);
        } catch (e) {
          // Sin la migración: el camino anterior, leer y después cerrar.
          if (!_isMissingRpcError(e)) rethrow;
        }
        if (guardedResult != null && guardedResult != 'voided') {
          throw _OfflineSyncSkip(
            'Orden $voidOrderId no se anula en server: $guardedResult.',
          );
        }
        if (guardedResult == null) {
          // Si la lectura falla, el error sigue su reintento normal (la red
          // no la manda a dead-letter); si la orden no aparece en el negocio,
          // se conserva el comportamiento de siempre.
          final serverOrder = await salesRepository.getOrder(
            voidOrderId,
            businessId: businessId,
          );
          if (serverOrder != null &&
              (serverOrder.isPaid ||
                  serverOrder.isCancelled ||
                  serverOrder.status == 'void' ||
                  serverOrder.closedAt != null)) {
            throw _OfflineSyncSkip(
              'Orden $voidOrderId ya estaba ${serverOrder.status} en server: '
              'no se anula.',
            );
          }
          try {
            await salesRepository.closeOrder(
              orderId: voidOrderId,
              status: 'void',
            );
          } catch (e) {
            // Si la orden ya está cerrada (otro terminal anuló o cobró,
            // o este replay corrió duplicado) tratamos el action como
            // completado — el estado deseado ya se cumple.
            if (_isItemMissingError(e) ||
                e.toString().toLowerCase().contains('already')) {
              throw _OfflineSyncSkip(
                'Orden $voidOrderId ya estaba cerrada en server.',
              );
            }
            rethrow;
          }
        }
        final voidReason = action['reason']?.toString();
        if (voidReason != null && voidReason.trim().isNotEmpty) {
          try {
            await salesRepository.appendVoidAuditNote(
              orderId: voidOrderId,
              reason: voidReason,
              userName: action['void_by']?.toString(),
              voidedAt: DateTime.tryParse(
                action['voided_at']?.toString() ?? '',
              ),
              businessId: businessId,
            );
          } catch (e) {
            // Best-effort: la orden ya quedó anulada (lo crítico). Si la
            // nota de auditoría no se pudo escribir, lo logueamos y
            // seguimos — no reintentamos el void por esto.
            debugPrint('void_order replay: nota de auditoría falló: $e');
          }
        }
        return voidOrderId;
      case 'release_empty_order':
        final releaseOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        await salesRepository.releaseEmptyTableIfNeeded(
          releaseOrderId,
          businessId: businessId,
        );
        return releaseOrderId;
      case 'send_to_kitchen':
      case 'confirm_local_order':
        final resolvedOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        final printedAreas = ((action['printed_areas'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toSet();
        final missingAreas = ((action['missing_areas'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toSet();

        // Comanda YA impresa localmente en todas sus áreas: el replay solo
        // debe confirmar los items en server (draft → pending), NO volver a
        // imprimir. Antes re-despachaba todas las áreas = comanda duplicada
        // (o entera, con rondas viejas) al sincronizar.
        if (printedAreas.isNotEmpty && missingAreas.isEmpty) {
          // Solo las líneas de esta comanda (20261010_0002). La orden entera
          // pasaba a 'pending' también lo agregado después de imprimirla, que
          // quedaba «enviado» sin haber salido a cocina. Sin todos sus ids,
          // o sin la migración, la acción se conserva (_KitchenRoundHold).
          final roundItemIds = await _kitchenRoundItemIds(
            businessId: businessId,
            action: action,
          );
          try {
            await salesRepository.confirmItemsToKitchen(
              resolvedOrderId,
              roundItemIds,
            );
          } catch (e) {
            if (_isMissingRpcError(e)) {
              throw const _KitchenRoundHold(
                _kitchenRpcMissingMessage,
                countsAttempt: false,
              );
            }
            rethrow;
          }
          return resolvedOrderId;
        }

        // Áreas que no salieron: se imprimen y confirman SOLO las líneas de
        // esta comanda, nunca lo agregado después (ver arriba).
        final roundItemIds = await _kitchenRoundItemIds(
          businessId: businessId,
          action: action,
        );
        try {
          final printResult = await printingService.sendOrderToKitchen(
            orderId: resolvedOrderId,
            businessId: businessId,
            // Ver nota arriba: el replay nunca fusiona comandas.
            allowKitchenMerge: false,
            // Las áreas ya impresas localmente solo se marcan; se imprimen
            // únicamente las que quedaron sin impresora.
            excludeAreaCodes: printedAreas,
            onlyItemIds: roundItemIds.toSet(),
          );
          final roundId = action['id']?.toString();
          if (roundId != null && roundId.isNotEmpty) {
            if (printResult.pendingPrintAreas.isNotEmpty) {
              final rawItemsByArea = action['item_ids_by_area'];
              await PendingKitchenPrints.instance.record(
                businessId: businessId,
                roundId: roundId,
                orderId: action['order_id']?.toString() ?? resolvedOrderId,
                tableName: action['table_name']?.toString() ?? 'Mesa',
                itemIdsByArea: {
                  for (final areaCode in printResult.pendingPrintAreas)
                    areaCode:
                        rawItemsByArea is Map &&
                            rawItemsByArea[areaCode] is List
                        ? (rawItemsByArea[areaCode] as List)
                              .map((id) => id.toString())
                              .toList(growable: false)
                        : <String>[],
                },
              );
            }
            await PendingKitchenPrints.instance.resolveAreas(
              businessId: businessId,
              roundId: roundId,
              acceptedAreas: {
                ...printResult.directAreas,
                ...printResult.escalatedAreas,
              },
            );
          }
        } catch (e) {
          // Replay idempotente: si un intento previo (o otra caja) ya marcó
          // los ítems enviados a cocina, la orden no tiene drafts y
          // sendOrderToKitchen truena con un error PERMANENTE — reintentar
          // jamás lo arregla y la operación se vuelve veneno en la cola
          // (caso real 2026-07-25: "Crear orden · 7 intentos · No hay items
          // nuevos pendientes de enviar a cocina"). El estado deseado ya
          // existe en el server → resolvemos la operación como completada.
          final msg = e.toString().toLowerCase();
          if (msg.contains('no hay items nuevos pendientes') ||
              msg.contains('la orden no tiene items')) {
            throw _OfflineSyncSkip(
              'Orden $resolvedOrderId ya estaba enviada a cocina en server.',
            );
          }
          if (_isMissingRpcError(e)) {
            throw const _KitchenRoundHold(
              _kitchenRpcMissingMessage,
              countsAttempt: false,
            );
          }
          rethrow;
        }
        return resolvedOrderId;
      case 'set_delivery_fee':
        // Fee de delivery propio fijado offline. FIFO garantiza que esto se
        // replaya ANTES del process_payment de la misma orden (se encola en
        // el gate, antes del cobro), así el total del server ya incluye el fee
        // cuando llega el pago. Ver docs/PRD_DELIVERY_FEE_PROPIO.md.
        final resolvedOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        await salesRepository.setDeliveryFee(
          orderId: resolvedOrderId,
          amount: ((action['amount'] ?? 0) as num).toDouble(),
        );
        return resolvedOrderId;
      case 'process_payment':
        final resolvedOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        // Si la acción fue encolada offline trae paid_at (ISO-8601 UTC).
        // Al replayar preservamos esa fecha como payments.created_at vía el
        // RPC (parámetro p_paid_at). Si falta o no parsea, paidAt queda
        // null y el RPC cae al comportamiento online (now()).
        DateTime? paidAt;
        final rawPaidAt = action['paid_at']?.toString();
        if (rawPaidAt != null && rawPaidAt.isNotEmpty) {
          paidAt = DateTime.tryParse(rawPaidAt);
        }
        // cashier_session_id local (`local-cash-session-X`) → uuid
        // remoto via mapping guardado al replay de open_cash_session.
        // FIFO de la cola garantiza que open_cash_session ya pasó
        // cuando este payment se replaya.
        var cashierSessionId = action['cashier_session_id']?.toString();
        if (cashierSessionId != null &&
            cashierSessionId.startsWith('local-cash-session-')) {
          final sessionMap = await _readCashSessionMap(businessId);
          final remote = sessionMap[cashierSessionId]?.toString();
          if (remote == null || remote.isEmpty) {
            throw Exception(
              'No se pudo resolver la sesión de caja local '
              '$cashierSessionId al sincronizar el pago. ¿La acción '
              'open_cash_session se replayó antes?',
            );
          }
          cashierSessionId = remote;
        }
        // F4: si el cobro se emitió offline con un NCF asignado por el Hub,
        // viaja en la acción. Se reenvía al RPC (p_offline_ncf) para que el
        // fiscal_document se registre con ESE número sin regenerarlo, junto
        // con su tipo (para que fd.ncf_type coincida con el NCF impreso).
        final offlineNcf = action['offline_ncf']?.toString();
        // NOTA DE VENTA: el cobro se hizo pidiendo documento no fiscal. La
        // marca va ANTES del RPC porque el trigger de cierre — que corre
        // dentro de ese RPC — es quien decide si emite nota o NCF.
        if (action.containsKey('is_sales_note')) {
          await salesRepository.markAsSalesNote(
            orderId: resolvedOrderId,
            checkId: action['check_id']?.toString(),
            value: action['is_sales_note'] == true,
          );
        }
        await salesRepository.processPayment(
          orderId: resolvedOrderId,
          checkId: action['check_id']?.toString(),
          paymentMethodId: action['payment_method_id']?.toString() ?? '',
          amount: ((action['amount'] ?? 0) as num).toDouble(),
          splitSequence: (action['split_sequence'] as num?)?.toInt() ?? 0,
          closeOrder: action['close_order'] != false,
          closeCheck: action['close_check'] != false,
          reference: action['reference']?.toString(),
          customerId: action['customer_id']?.toString(),
          customerRnc: action['customer_rnc']?.toString(),
          fiscalType: action['requested_ncf_type']?.toString(),
          cashierSessionId: cashierSessionId,
          changeAmount: ((action['change_amount'] ?? 0) as num).toDouble(),
          paidAt: paidAt,
          offlineNcf: (offlineNcf != null && offlineNcf.isNotEmpty)
              ? offlineNcf
              : null,
        );
        return resolvedOrderId;
      default:
        throw UnsupportedError('Offline action no soportada: $type');
    }
  }

  Future<String> _resolveOrderIdForAction({
    required String businessId,
    required Map<String, dynamic> action,
    required SalesRepository salesRepository,
  }) async {
    final originalOrderId = action['order_id']?.toString();
    if (originalOrderId == null || originalOrderId.isEmpty) {
      throw Exception('Acción offline sin order_id');
    }

    if (!originalOrderId.startsWith('local-order-')) {
      return originalOrderId;
    }

    final currentMap = await _readOrderMap(businessId);
    final existing = currentMap[originalOrderId]?.toString();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final origin = action['origin']?.toString();
    if (origin == null || origin.isEmpty) {
      throw Exception(
        'No se puede recrear automáticamente una orden local sin origen',
      );
    }

    Map<String, dynamic> created;
    if (origin == 'table' || origin == 'delivery') {
      final tableId = await _resolveTableIdForAction(
        businessId: businessId,
        action: action,
      );
      if (tableId == null || tableId.isEmpty) {
        throw Exception(
          'No se pudo resolver la mesa para sincronizar la orden local',
        );
      }
      // El mesero que la abrió sin red. Sin él la mesa nacía a nombre de la
      // cuenta que sincroniza y así salían su precuenta y su factura.
      final fromAction = action['opened_by_employee_id']?.toString().trim();
      final openedByEmployeeId =
          (fromAction != null && fromAction.isNotEmpty ? fromAction : null) ??
          (await localOrderOpener(
            businessId: businessId,
            orderId: originalOrderId,
          ))?.employeeId;
      try {
        created = await salesRepository.openTable(
          tableId: tableId,
          userId: null,
          peopleCount: 1,
          openedByEmployeeId: openedByEmployeeId,
        );
      } catch (e) {
        // La atribución nunca detiene una venta. Si el servidor ya no acepta
        // a ese mesero (lo desactivaron o borraron mientras no había red:
        // EMPLOYEE_NOT_IN_BUSINESS), sus ítems y su cobro quedaban detrás de
        // esta acción hasta el dead-letter. fn_open_table valida al empleado
        // antes de tomar el candado y de escribir nada, así que reabrir sin
        // él no duplica la mesa. Se pierde solo la atribución en el servidor
        // (la mesa queda a nombre de la cuenta que sincroniza, como antes de
        // registrar al mesero); la anotación local de quién la abrió se
        // conserva para lo que este equipo imprime sin red.
        if (openedByEmployeeId == null ||
            !e.toString().contains('EMPLOYEE_NOT_IN_BUSINESS')) {
          rethrow;
        }
        debugPrint(
          '[OfflinePos] El servidor rechazó al mesero $openedByEmployeeId '
          'de $originalOrderId: la mesa se abre sin él. $e',
        );
        created = await salesRepository.openTable(
          tableId: tableId,
          userId: null,
          peopleCount: 1,
        );
      }
    } else {
      // Retail: si esta orden local pertenece a un carrito de venta rápida
      // (slot 'quick-…'), recrearla con fn_open_retail_cart (mesa virtual
      // dedicada por carrito) para NO anular los demás carritos. El RPC
      // compartido fn_open_manual_or_quick cerraría la sesión quick previa.
      String? retailSlot;
      if (origin == 'quick') {
        retailSlot =
            action['slot_id']?.toString() ??
            await findSnapshotSlotForOrder(
              businessId: businessId,
              localOrderId: originalOrderId,
            );
        // Tras cobrar offline se retira el snapshot/pestaña, pero la venta
        // aún tiene que subir. Una clave determinista conserva su identidad
        // y evita anular otra venta usando la mesa quick compartida.
        if (retailSlot == null || !retailSlot.startsWith('quick-')) {
          retailSlot =
              'quick-${originalOrderId.substring('local-order-'.length)}';
        }
      }
      if (retailSlot != null && retailSlot.startsWith('quick-')) {
        created = await salesRepository.openRetailCart(
          slot: retailSlot,
          businessId: businessId,
          peopleCount: 1,
        );
      } else if (origin == 'manual') {
        created = await salesRepository.openOfflineSale(
          origin: origin,
          slot: 'manual-${originalOrderId.substring('local-order-'.length)}',
          businessId: businessId,
        );
      } else {
        created = await salesRepository.openManualOrQuick(
          origin: origin,
          customerName: null,
          peopleCount: 1,
          businessId: businessId,
        );
      }
    }
    final remoteOrderId = created['order_id']?.toString();
    if (remoteOrderId == null || remoteOrderId.isEmpty) {
      throw Exception('No se pudo recrear la orden remota para sincronizar');
    }

    await _saveOrderMapping(
      businessId: businessId,
      localOrderId: originalOrderId,
      remoteOrderId: remoteOrderId,
    );
    await remapSnapshotOrderId(
      businessId: businessId,
      localOrderId: originalOrderId,
      remoteOrderId: remoteOrderId,
    );
    return remoteOrderId;
  }

  Future<String?> _resolveTableIdForAction({
    required String businessId,
    required Map<String, dynamic> action,
  }) async {
    final explicit = action['table_id']?.toString();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    final originalOrderId = action['order_id']?.toString();
    if (originalOrderId == null || originalOrderId.isEmpty) return null;

    final storage = await _storage;
    final prefix = 'offline_snapshot_${businessId}_';
    final keys = await storage.getKeysByPrefix(prefix);

    for (final key in keys) {
      try {
        final payload = await _readSnapshot(storage, key);
        if (payload == null) continue;
        final state = Map<String, dynamic>.from(payload['state'] as Map? ?? {});
        final order = Map<String, dynamic>.from(state['order'] as Map? ?? {});
        if (order['id']?.toString() != originalOrderId) continue;
        final tableId = payload['table_id']?.toString();
        if (tableId != null && tableId.isNotEmpty) {
          return tableId;
        }
      } catch (_) {}
    }

    return null;
  }

  Future<String> _resolveItemIdForAction({
    required String businessId,
    required Map<String, dynamic> action,
    required SalesRepository salesRepository,
  }) async {
    final rawItemId = action['item_id']?.toString();
    if (rawItemId != null &&
        rawItemId.isNotEmpty &&
        !rawItemId.startsWith('tmp_')) {
      return rawItemId;
    }

    if (rawItemId != null && rawItemId.isNotEmpty) {
      final currentMap = await _readItemMap(businessId);
      final existing = currentMap[rawItemId]?.toString();
      if (existing != null && existing.isNotEmpty) {
        return existing;
      }
    }

    // Matching by product/name (or the last row) can edit a different round
    // of the same product. Missing identity is a dependency, not a deletion.
    throw StateError(
      'OFFLINE_ITEM_MAPPING_REQUIRED: falta sincronizar '
      'la identidad del item $rawItemId. No se modifico otro producto.',
    );
  }

  Future<void> remapSnapshotItemId({
    required String businessId,
    required String localItemId,
    required String remoteItemId,
  }) async {
    final storage = await _storage;
    final prefix = 'offline_snapshot_${businessId}_';
    final keys = await storage.getKeysByPrefix(prefix);

    for (final key in keys) {
      try {
        await _withSnapshotMutation(key, () async {
          final payload = await _readSnapshot(storage, key);
          if (payload == null) return;
          final state = Map<String, dynamic>.from(
            payload['state'] as Map? ?? {},
          );
          var changed = false;
          final items = ((state['items'] as List?) ?? const [])
              .map((entry) {
                final item = Map<String, dynamic>.from(entry as Map);
                if (item['id']?.toString() == localItemId) {
                  item['id'] = remoteItemId;
                  changed = true;
                }
                return item;
              })
              .toList(growable: false);
          if (!changed) return;
          state['items'] = items;
          payload['state'] = state;
          await _writeSnapshot(storage, key, payload);
        });
      } catch (e) {
        debugPrint('OfflinePosService.remapSnapshotItemId error: $e');
      }
    }
  }

  Future<Map<String, dynamic>> _reconcileEncodedState({
    required String businessId,
    required Map<String, dynamic> state,
  }) async {
    final orderMap = await _readOrderMap(businessId);
    final itemMap = await _readItemMap(businessId);
    final reconciled = Map<String, dynamic>.from(state);

    final rawOrder = reconciled['order'];
    if (rawOrder is Map) {
      final order = Map<String, dynamic>.from(rawOrder);
      final orderId = order['id']?.toString();
      final mappedOrderId = orderId == null
          ? null
          : orderMap[orderId]?.toString();
      if (mappedOrderId != null && mappedOrderId.isNotEmpty) {
        order['id'] = mappedOrderId;
        reconciled['order'] = order;
      }
    }

    final rawItems = (reconciled['items'] as List?) ?? const [];
    reconciled['items'] = rawItems
        .map((entry) {
          final item = Map<String, dynamic>.from(entry as Map);
          final itemId = item['id']?.toString();
          final mappedItemId = itemId == null
              ? null
              : itemMap[itemId]?.toString();
          if (mappedItemId != null && mappedItemId.isNotEmpty) {
            item['id'] = mappedItemId;
          }
          final orderId = item['order_id']?.toString();
          final mappedOrderId = orderId == null
              ? null
              : orderMap[orderId]?.toString();
          if (mappedOrderId != null && mappedOrderId.isNotEmpty) {
            item['order_id'] = mappedOrderId;
          }
          return item;
        })
        .toList(growable: false);

    final rawChecks = (reconciled['checks'] as List?) ?? const [];
    reconciled['checks'] = rawChecks
        .map((entry) {
          final check = Map<String, dynamic>.from(entry as Map);
          final orderId = check['order_id']?.toString();
          final mappedOrderId = orderId == null
              ? null
              : orderMap[orderId]?.toString();
          if (mappedOrderId != null && mappedOrderId.isNotEmpty) {
            check['order_id'] = mappedOrderId;
          }
          return check;
        })
        .toList(growable: false);

    return reconciled;
  }

  Future<void> _pruneQueue(String businessId) async {
    await _withQueueMutation(businessId, () async {
      // Nunca podar desde la foto anterior al sync: borraría las ventas que
      // entraron mientras la red estaba ocupada.
      final queue = await _readQueue(businessId);
      final pending = queue
          .where((item) => !_isCompleted(item))
          .toList(growable: false);
      final completed = queue.where(_isCompleted).toList(growable: false);
      final keepCompleted = completed.length > 20
          ? completed.sublist(completed.length - 20)
          : completed;
      final compacted = [...pending, ...keepCompleted];
      await _writeQueue(businessId, compacted);
    });
    // Cap del histórico de completed_ops/fingerprints en sqlite: borramos
    // entradas más viejas de 30 días. Antes el cap era 500 entries en
    // memoria; el cap por tiempo es más robusto y predecible.
    await _pruneCompletedOlderThan(const Duration(days: 30));
  }

  /// Limpia la cola de impresión offline (`offline_print_queue_*`) cuando
  /// ya no quedan envíos a cocina pendientes.
  ///
  /// Contexto: al enviar una orden a cocina sin red, `sendLocalOrderToKitchen`
  /// imprime a las impresoras cacheadas y, para áreas sin impresora cacheada,
  /// agrega una entrada a `offline_print_queue` (a modo de registro). PERO el
  /// mismo flujo encola además un `send_to_kitchen`; su replay llama a
  /// `sendOrderToKitchen` (online), que re-despacha TODAS las áreas y escala
  /// a la cola cloud las que no tienen impresora. Es decir, el re-despacho ya
  /// está garantizado por el replay.
  ///
  /// Por eso NO reenviamos desde aquí (sería doble impresión): solo
  /// recolectamos las entradas stale para que la cola no crezca sin límite
  /// (gap "se llena pero no se drena"). Esperamos a que no queden
  /// send_to_kitchen/confirm_local_order pendientes; en ese punto toda
  /// comanda encolada ya fue re-despachada por su acción.
  Future<void> _drainStalePrintQueue(
    String businessId,
    List<Map<String, dynamic>> queue,
  ) async {
    final hasPendingKitchenSend = queue.any(
      (a) =>
          !_isSettled(a) &&
          (a['type'] == 'send_to_kitchen' ||
              a['type'] == 'confirm_local_order'),
    );
    if (hasPendingKitchenSend) return;
    final storage = await _storage;
    final existing = await storage.readList(_printQueueKey(businessId));
    if (existing != null && existing.isNotEmpty) {
      await storage.delete(_printQueueKey(businessId));
    }
  }

  Future<Map<String, dynamic>> _readOrderMap(String businessId) async {
    final storage = await _storage;
    return await storage.readJson(_orderMapKey(businessId)) ??
        <String, dynamic>{};
  }

  Future<void> _saveOrderMapping({
    required String businessId,
    required String localOrderId,
    required String remoteOrderId,
  }) async {
    await _withQueueMutation(businessId, () async {
      final storage = await _storage;
      final current = await _readOrderMap(businessId);
      current[localOrderId] = remoteOrderId;
      try {
        if (!await storage.writeJson(_orderMapKey(businessId), current)) {
          throw StateError(
            'No se pudo guardar la identidad de la venta sincronizada.',
          );
        }
      } finally {
        // Una acción de la venta local pasa a ser de su orden remota.
        _bumpQueueRevision(businessId);
      }
    });
  }

  /// Anota quién abrió una venta sin red, en el momento de abrirla: el
  /// mesero del PIN o, sin PIN, la cuenta que la abre. Sirve para dos cosas:
  ///   - El replay lo manda como `opened_by_employee_id` al crear la mesa
  ///     real. Sin esto el servidor la dejaba a nombre de la cuenta que
  ///     sincroniza, y la precuenta/factura salían con ese nombre.
  ///   - Sin red, el «MESERO:» impreso sale de aquí y no de quien esté
  ///     logueado al imprimir.
  /// Nunca lanza: perder la anotación no puede tumbar la apertura.
  Future<void> rememberLocalOrderOpener({
    required String businessId,
    required String localOrderId,
    String? employeeId,
    String? name,
  }) async {
    final cleanEmployee = employeeId?.trim() ?? '';
    final cleanName = name?.trim() ?? '';
    if (businessId.isEmpty || (cleanEmployee.isEmpty && cleanName.isEmpty)) {
      return;
    }
    try {
      final storage = await _storage;
      final key = _localOrderOpenerKey(businessId);
      final current = await storage.readJson(key) ?? <String, dynamic>{};
      // Solo hace falta mientras la venta no sube y se imprime: una semana
      // sobra y evita que el mapa crezca para siempre.
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      current.removeWhere((_, value) {
        final at = DateTime.tryParse('${(value as Map?)?['at']}');
        return at == null || at.isBefore(cutoff);
      });
      current[localOrderId] = {
        if (cleanEmployee.isNotEmpty) 'employee_id': cleanEmployee,
        if (cleanName.isNotEmpty) 'name': cleanName,
        'at': DateTime.now().toIso8601String(),
      };
      await storage.writeJson(key, current);
    } catch (e) {
      debugPrint('[offline] no se pudo anotar quién abrió $localOrderId: $e');
    }
  }

  /// Quién abrió la venta [orderId] sin red (ver [rememberLocalOrderOpener]).
  /// Acepta el id local o el remoto que le tocó al sincronizar. Null si este
  /// equipo no la abrió sin red.
  Future<({String? employeeId, String? name})?> localOrderOpener({
    required String businessId,
    required String orderId,
  }) async {
    if (businessId.isEmpty || orderId.isEmpty) return null;
    try {
      final storage = await _storage;
      final openers =
          await storage.readJson(_localOrderOpenerKey(businessId)) ??
          <String, dynamic>{};
      var raw = openers[orderId];
      if (raw == null && !orderId.startsWith('local-order-')) {
        final mappings = await _readOrderMap(businessId);
        for (final entry in mappings.entries) {
          if (entry.value?.toString() == orderId) {
            raw = openers[entry.key];
            if (raw != null) break;
          }
        }
      }
      if (raw is! Map) return null;
      String? clean(Object? value) {
        final text = value?.toString().trim();
        return (text == null || text.isEmpty) ? null : text;
      }

      final employeeId = clean(raw['employee_id']);
      final name = clean(raw['name']);
      if (employeeId == null && name == null) return null;
      return (employeeId: employeeId, name: name);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _readItemMap(String businessId) async {
    final storage = await _storage;
    return await storage.readJson(_itemMapKey(businessId)) ??
        <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _readCashSessionMap(String businessId) async {
    final storage = await _storage;
    return await storage.readJson(_cashSessionMapKey(businessId)) ??
        <String, dynamic>{};
  }

  Future<void> _saveCashSessionMapping({
    required String businessId,
    required String localSessionId,
    required String remoteSessionId,
  }) async {
    await _withQueueMutation(businessId, () async {
      final storage = await _storage;
      final current = await _readCashSessionMap(businessId);
      current[localSessionId] = remoteSessionId;
      if (!await storage.writeJson(_cashSessionMapKey(businessId), current)) {
        throw StateError(
          'No se pudo guardar la identidad de la caja sincronizada.',
        );
      }
    });
  }

  Future<void> _saveItemMapping({
    required String businessId,
    required String localItemId,
    required String remoteItemId,
  }) async {
    await _withQueueMutation(businessId, () async {
      final storage = await _storage;
      final current = await _readItemMap(businessId);
      current[localItemId] = remoteItemId;
      if (!await storage.writeJson(_itemMapKey(businessId), current)) {
        throw StateError(
          'No se pudo guardar la identidad del item sincronizado.',
        );
      }
    });
  }

  Map<String, dynamic> _encodeState(CurrentOrderState state) {
    return {
      'loading': state.loading,
      'error': state.error,
      'takeout': state.takeout,
      'origin': state.origin,
      'delivery_type': state.deliveryType,
      'delivery_address': state.deliveryAddress,
      'selected_check_id': state.selectedCheckId,
      'customer_id': state.customerId,
      'customer_name': state.customerName,
      'session_note': state.sessionNote,
      'order': state.order == null ? null : _encodeOrder(state.order!),
      'items': state.items
          .map(OrderItemSnapshot.encode)
          .toList(growable: false),
      'checks': state.checks.map(_encodeOrderCheck).toList(growable: false),
    };
  }

  CurrentOrderState _decodeState(Map<String, dynamic> map) {
    return CurrentOrderState(
      loading: map['loading'] == true,
      error: map['error']?.toString(),
      takeout: map['takeout'] == true,
      origin: map['origin']?.toString(),
      // Los respaldos anteriores no incluían estos campos: siguen siendo
      // legibles y devuelven null hasta cargar los datos de la sesión.
      deliveryType: map['delivery_type']?.toString(),
      deliveryAddress: map['delivery_address']?.toString(),
      selectedCheckId: map['selected_check_id']?.toString(),
      customerId: map['customer_id']?.toString(),
      customerName: map['customer_name']?.toString(),
      sessionNote: map['session_note']?.toString(),
      order: map['order'] is Map
          ? Order.fromMap(Map<String, dynamic>.from(map['order'] as Map))
          : null,
      items: ((map['items'] as List?) ?? const [])
          .map(
            (e) =>
                OrderItemSnapshot.decode(Map<String, dynamic>.from(e as Map)),
          )
          .toList(growable: false),
      checks: ((map['checks'] as List?) ?? const [])
          .map((e) => OrderCheck.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> _encodeOrder(Order order) => order.toMap();

  Map<String, dynamic> _encodeOrderCheck(OrderCheck check) => {
    'id': check.id,
    'order_id': check.orderId,
    'label': check.label,
    'position': check.position,
    'is_closed': check.isClosed,
    'subtotal': check.subtotal,
    'discounts': check.discounts,
    'service_fee': check.serviceFee,
    'tax': check.tax,
    'total': check.total,
    'customer_id': check.customerId,
    'customer_name': check.customerName,
    'customer_rnc': check.customerRnc,
    'requested_ncf_type': check.requestedNcfType,
  };
}
