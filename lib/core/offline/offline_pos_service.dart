import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:mangopos/core/offline/storage/offline_queue_dao.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/offline/hub/hub_op_log.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
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
    this.lastMappedOrderId,
    this.lastError,
    this.conflicts = const <OfflineSyncConflict>[],
  });

  final int processed;
  final int completed;
  final int failed;
  final int skipped;
  final int pending;

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
    return msg.contains('no se pudo resolver el item') ||
        msg.contains('pgrst116') ||
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

  Future<StorageService> get _storage async => StorageService.getInstance();

  /// Cifrado en reposo para snapshots de órdenes (datos sensibles: montos,
  /// items, cliente). Migración perezosa de valores legacy en texto plano.
  final SecureBlobCipher _cipher = SecureBlobCipher.instance;

  /// Seam del Hub Local (F3b-3). Cuando el terminal está en modo `hub`,
  /// `HubModeController` setea este uploader (un closure que hace
  /// `HubClient.postOp` contra el Hub alcanzable). Si está seteado,
  /// `enqueueAction` envía la op al Hub en vez de a la cola local; si el Hub
  /// no responde (devuelve null o lanza), cae a la cola local — el
  /// comportamiento de siempre. Null en modo cloud/solo → cero cambio.
  Future<int?> Function(String businessId, Map<String, dynamic> op)?
      _hubUploader;

  /// Op-log del Hub (F3b-3b). Cuando ESTE dispositivo es el Hub, el uplink
  /// drena este log a Supabase. Misma key/SP que el agente, así que comparten
  /// el mismo registro.
  final HubOpLog _hubOpLog = HubOpLog();

  /// Activa/desactiva el enrutado al Hub. Lo llama HubModeController según el
  /// modo. Pasar null vuelve al encolado local puro.
  void setHubUploader(
    Future<int?> Function(String businessId, Map<String, dynamic> op)?
        uploader,
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
  Future<void> publishHostOp(
    String businessId,
    Map<String, dynamic> op,
  ) async {
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
      final ops = await _hubOpLog.since(businessId, seq: 0);
      return HubOrderProjector.projectSalon(ops)
          .map((t) => t.toJson())
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// H6: devuelve el op-log LOCAL completo (cuando ESTE equipo es el Hub) para
  /// que el KDS lo proyecte con HubKitchenProjector sin un round-trip HTTP a sí
  /// mismo. Best-effort: lista vacía ante error.
  Future<List<Map<String, dynamic>>> getLocalHubOps(String businessId) async {
    try {
      return await _hubOpLog.since(businessId, seq: 0);
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
      final ops = await _hubOpLog.since(businessId, seq: 0);
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
    await storage.write(key, await _cipher.seal(jsonEncode(payload)));
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
    final storage = await _storage;
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
  }

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
      final reconciledState = await _reconcileEncodedState(
        businessId: businessId,
        state: stateMap,
      );
      payload['state'] = reconciledState;
      await _writeSnapshot(storage, key, payload);
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
        final payload = await _readSnapshot(storage, key);
        if (payload == null) continue;
        final state = Map<String, dynamic>.from(payload['state'] as Map? ?? {});
        final order = Map<String, dynamic>.from(state['order'] as Map? ?? {});
        if (order['id'] != localOrderId) continue;
        order['id'] = remoteOrderId;
        state['order'] = order;
        payload['state'] = state;
        payload['local_only'] = false;
        await _writeSnapshot(storage, key, payload);
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
    final voidedOrderIds = <String>{};
    try {
      final queue = await _readQueue(businessId);
      final orderMap = await _readOrderMap(businessId);
      for (final action in queue) {
        if (_isSettled(action)) continue;
        final type = action['type']?.toString();
        final orderId = action['order_id']?.toString();
        if (type == null || orderId == null || orderId.isEmpty) continue;
        final mapped = orderMap[orderId]?.toString();
        if (type == 'void_order') {
          voidedOrderIds.add(orderId);
          if (mapped != null && mapped.isNotEmpty) voidedOrderIds.add(mapped);
          continue;
        }
        if (type == 'process_payment') continue;
        pendingContentOrderIds.add(orderId);
        if (mapped != null && mapped.isNotEmpty) {
          pendingContentOrderIds.add(mapped);
        }
      }
      pendingContentOrderIds.removeAll(voidedOrderIds);
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
        if (voidedOrderIds.contains(orderId)) continue;
        if (!isLocalDraft && !hasPendingContent) continue;
        final items = (state['items'] as List?) ?? const [];
        final total = (order['total'] as num?)?.toDouble() ?? 0;
        result.add((
          tableId: tableId,
          itemsCount: items.length,
          total: total,
        ));
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
    await storage.write(
      _retailCartsIndexKey(businessId),
      await _cipher.seal(jsonEncode(payload)),
    );
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

  Future<CurrentOrderState> createLocalDraft({
    required String businessId,
    required String origin,
    String? tableId,
    String? slotId,
    String? label,
  }) async {
    final orderId = 'local-order-${_uuid.v4()}';
    final sessionId = 'local-session-${_uuid.v4()}';
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
    if (deviceId != null && enriched['device_id'] == null) {
      enriched['device_id'] = deviceId;
    }
    // Normalizamos ANTES de decidir el destino: la op necesita op_id y
    // fingerprint tanto para la cola local como para la idempotencia del Hub.
    final normalized = _normalizeAction(enriched);

    // F3b-3: en modo hub, enrutamos la op al Hub Local en vez de a la cola
    // local. Si el Hub la acepta (seq != null), terminamos: el Hub es ahora
    // el dueño de esa op y su uplink la subirá a Supabase. Si el Hub no
    // responde, caemos a la cola local — exactamente el comportamiento de
    // modo solo. El uploader es null en cloud/solo → este bloque no corre.
    final uploader = _hubUploader;
    if (uploader != null) {
      try {
        final seq = await uploader(businessId, normalized);
        if (seq != null) return;
      } catch (_) {
        // Hub inalcanzable o error → fallback a cola local.
      }
    }

    final current = await _readQueue(businessId);
    current.add(normalized);
    final compacted = _compactQueue(current);
    await _writeQueue(businessId, compacted);
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
      if (_isSettled(action)) continue; // ya sincronizada → ya está en el snapshot

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
          itemsSold += (action['qty'] as num?)?.toDouble() ??
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
  Future<List<Map<String, dynamic>>> unsettledActions(
    String businessId,
  ) async {
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
    final next = queue.map((action) {
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
    }).toList(growable: false);
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
    final survivors =
        queue.where((a) => !_isDead(a)).toList(growable: false);
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

  /// Descarta por completo una orden LOCAL que el cajero anuló antes de que
  /// sincronizara: elimina sus acciones no-completadas de la cola (open_table,
  /// add_item, …) y borra sus snapshots. Sin esto, la cola recreaba la mesa
  /// en el server al reconectar (mesa fantasma) y el snapshot mantenía la
  /// mesa "ocupada" en el overlay del salón para siempre.
  ///
  /// SOLO aplica a órdenes `local-order-…` SIN mapping a server (si ya
  /// sincronizó, lo correcto es anular la orden real vía void_order). Las
  /// acciones ya `completed` se conservan como histórico de idempotencia.
  Future<void> discardLocalOrder({
    required String businessId,
    required String localOrderId,
  }) async {
    if (businessId.isEmpty || !localOrderId.startsWith('local-order-')) {
      return;
    }
    // Cola: fuera todas las acciones pendientes/failed/dead de esa orden.
    try {
      final queue = await _readQueue(businessId);
      final survivors = queue.where((a) {
        if (_isCompleted(a)) return true;
        return a['order_id']?.toString() != localOrderId;
      }).toList(growable: false);
      if (survivors.length != queue.length) {
        await _writeQueue(businessId, survivors);
      }
    } catch (e) {
      debugPrint('OfflinePosService.discardLocalOrder cola: $e');
    }
    // Snapshots: cualquier slot (tableId o legacy sessionId) cuya orden sea
    // la descartada. Con esto el overlay del salón libera la mesa.
    try {
      final storage = await _storage;
      final prefix = 'offline_snapshot_${businessId}_';
      final keys = await storage.getKeysByPrefix(prefix);
      for (final key in keys) {
        try {
          final payload = await _readSnapshot(storage, key);
          if (payload == null) continue;
          final state =
              Map<String, dynamic>.from(payload['state'] as Map? ?? {});
          final order =
              Map<String, dynamic>.from(state['order'] as Map? ?? {});
          if (order['id']?.toString() != localOrderId) continue;
          await storage.delete(key);
        } catch (_) {
          // snapshot corrupto → seguimos con el siguiente.
        }
      }
    } catch (e) {
      debugPrint('OfflinePosService.discardLocalOrder snapshots: $e');
    }
  }

  /// Descarta todas las acciones de la cola para este business. Pensado
  /// para el boton "Limpiar cola" del banner offline — recurso de
  /// emergencia cuando hay acciones bloqueadas por bugs anteriores o
  /// conflictos irresolubles (ej: order_id que ya no existe en server).
  ///
  /// NO toca completed_ops/fingerprints: esos son markers que evitan
  /// re-aplicar acciones que SI llegaron al server. Borrarlos podria
  /// causar dobles ventas si una accion completed se re-encola luego.
  ///
  /// Devuelve cuantas acciones se borraron para feedback al cajero.
  Future<int> clearPendingActions(String businessId) async {
    if (businessId.isEmpty) return 0;
    return _deleteAllPending(businessId);
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

    // 3. Mappings local→remoto y cola de impresión.
    await storage.delete(_orderMapKey(businessId));
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
  }) async {
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
    String? lastMappedOrderId;
    String? lastError;
    final conflicts = <OfflineSyncConflict>[];

    final completedOps = await _readCompletedOps(businessId);
    final completedFingerprints =
        await _readCompletedFingerprints(businessId);

    for (var i = 0; i < queue.length; i++) {
      final action = queue[i];
      final actionId = action['id']?.toString();
      final fingerprint = action['fingerprint']?.toString();
      // Las completadas nunca se reprocesan. Las dead-letter no reintentan
      // en el sync automático, pero en el manual (force = botón
      // "Sincronizar ahora") se les da otra oportunidad: el cajero pidió
      // sincronizar la cola completa, no solo lo pendiente.
      if (_isCompleted(action)) continue;
      if (!force && _isDead(action)) continue;
      if ((actionId != null && completedOps.contains(actionId)) ||
          (fingerprint != null && completedFingerprints.contains(fingerprint))) {
        queue[i] = Map<String, dynamic>.from(action)
          ..['status'] = _statusCompleted
          ..['completed_at'] = action['completed_at'] ?? DateTime.now().toIso8601String();
        continue;
      }
      if (!force && !_isReadyToRetry(action)) {
        skipped++;
        continue;
      }

      processed++;
      final processing = Map<String, dynamic>.from(action)
        ..['status'] = _statusProcessing
        ..['processing_started_at'] = DateTime.now().toIso8601String();
      queue[i] = processing;
      // UPSERT puntual de la action que cambió de estado, en lugar de
      // reescribir la lista completa (O(n²) con N actions y N pasos).
      await _upsertAction(businessId, processing);

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
          await _markOpCompleted(
            businessId: businessId,
            opId: actionId,
          );
        }
        final fingerprint = processing['fingerprint']?.toString();
        if (fingerprint != null && fingerprint.isNotEmpty) {
          await _markFingerprintCompleted(
            businessId: businessId,
            fingerprint: fingerprint,
          );
        }
      } on _OfflineSyncSkip catch (skip) {
        // Conflicto cross-device detectado: la accion ya no aplica porque
        // otro terminal modifico el mismo recurso (ej. item borrado).
        // Tratamos como completed (idempotente — el estado deseado ya
        // existe o la accion no tiene sentido) pero anotamos el conflicto
        // para que el cashier lo vea en el snackbar post-sync.
        conflicts.add(OfflineSyncConflict(
          actionType: processing['type']?.toString() ?? 'unknown',
          actionId: actionId,
          reason: skip.reason,
        ));
        final done = Map<String, dynamic>.from(processing)
          ..['status'] = _statusCompleted
          ..['completed_at'] = DateTime.now().toIso8601String()
          ..['skip_reason'] = skip.reason
          ..['last_error'] = null;
        queue[i] = done;
        completed++;
        if (actionId != null && actionId.isNotEmpty) {
          await _markOpCompleted(
            businessId: businessId,
            opId: actionId,
          );
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
        // Dead-letter: si una acción NO de conectividad agotó sus
        // reintentos, deja de reintentar sola y pasa a estado terminal
        // `dead`. Los errores de conectividad NUNCA matan la acción —
        // son transitorios y no cuentan contra el tope (no hay culpa de
        // la acción si no hay red). Así un error permanente (constraint,
        // recurso borrado en server) no reintenta para siempre ni deja
        // el badge de pendientes pegado.
        final shouldDie = !isConnectivity && attempts >= maxAttempts;
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

    await _pruneQueue(businessId, queue);
    await _drainStalePrintQueue(businessId, queue);
    final pending = queue.where((item) => !_isSettled(item)).length;
    final dead = queue.where(_isDead).length;
    return OfflineQueueSyncResult(
      processed: processed,
      completed: completed,
      failed: failed,
      skipped: skipped,
      pending: pending,
      dead: dead,
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
  }) async {
    final ops = await _hubOpLog.since(businessId); // orden seq (FIFO)
    if (ops.isEmpty) return const OfflineQueueSyncResult();

    var processed = 0;
    var completed = 0;
    var failed = 0;
    String? lastMappedOrderId;
    String? lastError;
    final conflicts = <OfflineSyncConflict>[];
    final completedOps = await _readCompletedOps(businessId);
    final completedFingerprints = await _readCompletedFingerprints(businessId);

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
          (fingerprint != null && completedFingerprints.contains(fingerprint))) {
        completed++;
        continue;
      }
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
              businessId: businessId, fingerprint: fingerprint);
        }
      } on _OfflineSyncSkip catch (skip) {
        // Conflicto cross-terminal: la op ya no aplica (item borrado, etc.).
        // Idempotente: la marcamos completada y reportamos.
        conflicts.add(OfflineSyncConflict(
          actionType: op['type']?.toString() ?? 'unknown',
          actionId: opId,
          reason: skip.reason,
        ));
        completed++;
        if (opId != null && opId.isNotEmpty) {
          await _markOpCompleted(businessId: businessId, opId: opId);
        }
      } catch (e) {
        failed++;
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
    if (failed == 0) {
      final remaining = await _hubOpLog.since(businessId, seq: 0);
      final keep = HubOrderProjector.openOrderIds(remaining);
      if (keep.isEmpty) {
        await _hubOpLog.clear(businessId);
      } else {
        await _hubOpLog.retainOrders(businessId, keep);
      }
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
    if (kIsWeb) {
      final storage = await _storage;
      await storage.writeList(_queueKey(businessId), queue);
      return;
    }
    await _queueDao!.writeQueue(businessId, queue);
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

  Future<void> _upsertAction(
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
    await _queueDao!.upsertAction(businessId, action);
  }

  Future<int> _deleteAllPending(String businessId) async {
    if (kIsWeb) {
      final queue = await _readQueue(businessId);
      final beforeCount = queue
          .where((a) => a['status']?.toString() != _statusCompleted)
          .length;
      final remaining = queue
          .where((a) => a['status']?.toString() == _statusCompleted)
          .toList();
      await _writeQueue(businessId, remaining);
      return beforeCount;
    }
    return _queueDao!.deleteAllPending(businessId);
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
    normalized['fingerprint'] =
        action['fingerprint']?.toString() ?? _buildActionFingerprint(normalized);
    return normalized;
  }

  String _buildActionFingerprint(Map<String, dynamic> action) {
    final type = action['type']?.toString() ?? 'unknown';
    final orderId = action['order_id']?.toString() ?? '';
    final itemId = action['item_id']?.toString() ?? '';
    final menuItemId = action['menu_item_id']?.toString() ?? '';
    final checkPos = action['check_pos']?.toString() ?? '';
    final qty = action['quantity']?.toString() ?? action['qty']?.toString() ?? '';
    final notes = action['notes']?.toString() ?? '';
    final takeout = (action['takeout'] == true || action['is_takeout'] == true)
        ? '1'
        : '0';
    final productId = action['product_id']?.toString() ?? '';
    return [
      type,
      orderId,
      itemId,
      menuItemId,
      productId,
      checkPos,
      qty,
      takeout,
      notes,
    ].join('|');
  }

  List<Map<String, dynamic>> _compactQueue(List<Map<String, dynamic>> queue) {
    final result = <Map<String, dynamic>>[];

    for (final raw in queue) {
      final action = Map<String, dynamic>.from(raw);
      // Dejamos pasar intactas las resueltas (completed/dead) y las que
      // están en proceso: no se fusionan ni se cancelan con acciones
      // nuevas. Una dead-letter no debe absorber un add nuevo del mismo
      // item temporal.
      if (_isSettled(action) || action['status'] == _statusProcessing) {
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
              entry['type'] == 'add_item' &&
              entry['item_id']?.toString() == itemId,
        );

        if (addIndex >= 0) {
          final base = Map<String, dynamic>.from(result[addIndex]);
          if (type == 'delete_item') {
            result.removeAt(addIndex);
            continue;
          }
          if (type == 'update_item_quantity') {
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
      if (type == 'mark_order_takeout' && orderId != null && orderId.isNotEmpty) {
        existingIndex = result.lastIndexWhere(
          (entry) =>
              !_isSettled(entry) &&
              entry['type'] == 'mark_order_takeout' &&
              entry['order_id']?.toString() == orderId,
        );
      } else if ({
        'update_item_quantity',
        'update_item_notes',
        'toggle_item_takeout',
        'move_item_to_check',
      }.contains(type) && itemId != null && itemId.isNotEmpty) {
        existingIndex = result.lastIndexWhere(
          (entry) =>
              !_isSettled(entry) &&
              entry['type'] == type &&
              entry['item_id']?.toString() == itemId,
        );
      } else if ({'send_to_kitchen', 'confirm_local_order'}.contains(type) && orderId != null && orderId.isNotEmpty) {
        existingIndex = result.lastIndexWhere(
          (entry) =>
              !_isSettled(entry) &&
              (entry['type'] == 'send_to_kitchen' || entry['type'] == 'confirm_local_order') &&
              entry['order_id']?.toString() == orderId,
        );
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
        final response = await cashierRepository.openSession(
          cashRegisterId: action['cash_register_id']?.toString() ?? '',
          userId: action['user_id']?.toString() ?? '',
          startAmount: ((action['start_amount'] ?? 0) as num).toDouble(),
          deviceId: action['device_id']?.toString() ?? '',
          deviceName: action['device_name']?.toString(),
        );
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
          businessId: businessId,
          warehouseId: action['warehouse_id']?.toString() ?? '',
          itemId: action['item_id']?.toString() ?? '',
          countedQuantity:
              ((action['counted_quantity'] ?? 0) as num).toDouble(),
          reasonCode: action['reason_code']?.toString() ?? 'other',
          notes: action['notes']?.toString(),
          costPerUnit: action['cost_per_unit'] == null
              ? null
              : (action['cost_per_unit'] as num).toDouble(),
        );
        return null;
      case 'inventory_movement':
        await inventoryRepository.recordMovement(
          businessId: businessId,
          warehouseId: action['warehouse_id']?.toString() ?? '',
          itemId: action['item_id']?.toString() ?? '',
          movementType: action['movement_type']?.toString() ?? 'adjustment_out',
          quantity: ((action['quantity'] ?? 0) as num).toDouble(),
          costPerUnit: action['cost_per_unit'] == null
              ? null
              : (action['cost_per_unit'] as num).toDouble(),
          notes: action['notes']?.toString(),
          referenceType: action['reference_type']?.toString(),
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
          final rawStatus = action['status']?.toString() ?? 'preparing';
          final status = rawStatus == 'served' ? 'ready' : rawStatus;
          final updates = <String, dynamic>{'status': status};
          // toUtc: sin él, Dart manda hora local SIN offset y Postgres la
          // interpreta como UTC → el timestamp queda 4h en el pasado (RD) y
          // "Completados hoy" (día local de ready_at) pierde el ítem.
          if (status == 'preparing') {
            updates['started_at'] = DateTime.now().toUtc().toIso8601String();
          } else if (status == 'ready') {
            updates['ready_at'] = DateTime.now().toUtc().toIso8601String();
          }
          await Supabase.instance.client
              .from('order_items')
              .update(updates)
              .eq('id', kdsItemId);
          return kdsItemId;
        } catch (e) {
          debugPrint('[sync] kds_item_status replay falló (ignorado): $e');
          return null;
        }
      case 'add_item':
        final resolvedOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        final createdItemId = await salesRepository.addItemFromMenu(
          orderId: resolvedOrderId,
          menuItemId: action['menu_item_id']?.toString() ?? '',
          quantity: ((action['qty'] ?? 1) as num).toDouble(),
          checkPosition: (action['check_pos'] as num?)?.toInt() ?? 1,
          isTakeout: action['takeout'] == true,
          notes: action['notes']?.toString(),
        );
        final localItemId = action['item_id']?.toString();
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
        // (List<{name, qty, price, menu_item_id?}>). Antes esto se perdía: la orden offline
        // llegaba al server SIN modifiers, dejando totales inconsistentes.
        final rawModifiers = action['selected_modifiers'];
        if (rawModifiers is List && rawModifiers.isNotEmpty) {
          final modifiers = rawModifiers
              .whereType<Map>()
              .map<Map<String, dynamic>>(
                (m) => Map<String, dynamic>.from(m),
              )
              .toList(growable: false);
          if (modifiers.isNotEmpty) {
            try {
              await salesRepository.addOrderItemModifiers(
                itemId: createdItemId,
                modifiers: modifiers,
              );
            } catch (e) {
              // No abortamos el sync por un fallo de modifiers — el item
              // ya está en el server. Pero ahora SI lo reportamos como
              // conflicto para que el cashier sepa que el total puede
              // estar diferente de lo que pidio offline (precio del
              // modificador cambio, o ya no existe, etc).
              debugPrint(
                'Offline sync: error agregando modifiers a $createdItemId: $e',
              );
              final productName =
                  action['product_name']?.toString().trim() ?? 'un item';
              conflicts.add(OfflineSyncConflict(
                actionType: 'add_item_modifier',
                actionId: action['id']?.toString(),
                reason:
                    'Los modificadores de "$productName" no se pudieron aplicar (cambiaron de precio o ya no existen). Revisa el total.',
              ));
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
        final voidReason = action['reason']?.toString();
        if (voidReason != null && voidReason.trim().isNotEmpty) {
          try {
            await salesRepository.appendVoidAuditNote(
              orderId: voidOrderId,
              reason: voidReason,
              userName: action['void_by']?.toString(),
              voidedAt: DateTime.tryParse(action['voided_at']?.toString() ?? ''),
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
          try {
            // Sin fusión: el replay reproduce envíos encolados uno detrás de
            // otro y todos caerían dentro de la ventana, uniendo en una sola
            // comanda rondas que en el salón fueron distintas.
            await salesRepository.sendToKitchen(
              resolvedOrderId,
              allowMerge: false,
            );
          } catch (e) {
            // Idempotente: si ya no hay drafts (otro replay/otra caja la
            // confirmó), el estado deseado ya existe.
            final msg = e.toString().toLowerCase();
            if (!msg.contains('no hay items') && !_isItemMissingError(e)) {
              rethrow;
            }
          }
          return resolvedOrderId;
        }

        try {
          await printingService.sendOrderToKitchen(
            orderId: resolvedOrderId,
            businessId: businessId,
            // Ver nota arriba: el replay nunca fusiona comandas.
            allowKitchenMerge: false,
            // Acciones nuevas traen las áreas ya impresas localmente: esas
            // solo se marcan, se reimprimen únicamente las que quedaron sin
            // impresora. Acciones legacy (sin el campo) re-despachan todo,
            // como antes.
            excludeAreaCodes: printedAreas,
          );
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
        await salesRepository.processPayment(
          orderId: resolvedOrderId,
          checkId: action['check_id']?.toString(),
          paymentMethodId: action['payment_method_id']?.toString() ?? '',
          amount: ((action['amount'] ?? 0) as num).toDouble(),
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
      throw Exception('No se puede recrear automáticamente una orden local sin origen');
    }

    Map<String, dynamic> created;
    if (origin == 'table') {
      final tableId = await _resolveTableIdForAction(
        businessId: businessId,
        action: action,
      );
      if (tableId == null || tableId.isEmpty) {
        throw Exception('No se pudo resolver la mesa para sincronizar la orden local');
      }
      created = await salesRepository.openTable(
        tableId: tableId,
        userId: null,
        peopleCount: 1,
      );
    } else {
      // Retail: si esta orden local pertenece a un carrito de venta rápida
      // (slot 'quick-…'), recrearla con fn_open_retail_cart (mesa virtual
      // dedicada por carrito) para NO anular los demás carritos. El RPC
      // compartido fn_open_manual_or_quick cerraría la sesión quick previa.
      String? retailSlot;
      if (origin == 'quick') {
        retailSlot = await findSnapshotSlotForOrder(
          businessId: businessId,
          localOrderId: originalOrderId,
        );
      }
      if (retailSlot != null && retailSlot.startsWith('quick-')) {
        created = await salesRepository.openRetailCart(
          slot: retailSlot,
          businessId: businessId,
          peopleCount: 1,
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
    if (rawItemId != null && rawItemId.isNotEmpty && !rawItemId.startsWith('tmp_')) {
      return rawItemId;
    }

    if (rawItemId != null && rawItemId.isNotEmpty) {
      final currentMap = await _readItemMap(businessId);
      final existing = currentMap[rawItemId]?.toString();
      if (existing != null && existing.isNotEmpty) {
        return existing;
      }
    }

    final resolvedOrderId = await _resolveOrderIdForAction(
      businessId: businessId,
      action: action,
      salesRepository: salesRepository,
    );

    final items = await salesRepository.getOrderItems(
      resolvedOrderId,
      includeModifiers: true,
      onlyOpen: true,
    );

    final productId = action['product_id']?.toString();
    final productName = action['product_name']?.toString().trim().toLowerCase();
    final notes = action['notes']?.toString().trim();
    final isTakeout = action['is_takeout'] == true || action['takeout'] == true;

    OrderItem? matched;
    for (final item in items.reversed) {
      final sameProductId =
          productId != null && productId.isNotEmpty && item.productId == productId;
      final sameName =
          productName != null && productName.isNotEmpty && item.productName.trim().toLowerCase() == productName;
      final sameNotes = notes == null || notes.isEmpty || (item.notes?.trim() ?? '') == notes;
      final sameTakeout = item.isTakeout == isTakeout;
      if ((sameProductId || sameName) && sameNotes && sameTakeout) {
        matched = item;
        break;
      }
    }

    matched ??= items.isNotEmpty ? items.last : null;
    if (matched == null) {
      throw Exception('No se pudo resolver el item offline para sincronizar');
    }

    if (rawItemId != null && rawItemId.isNotEmpty) {
      await _saveItemMapping(
        businessId: businessId,
        localItemId: rawItemId,
        remoteItemId: matched.id,
      );
      await remapSnapshotItemId(
        businessId: businessId,
        localItemId: rawItemId,
        remoteItemId: matched.id,
      );
    }

    return matched.id;
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
        final payload = await _readSnapshot(storage, key);
        if (payload == null) continue;
        final state = Map<String, dynamic>.from(payload['state'] as Map? ?? {});
        final items = ((state['items'] as List?) ?? const []).map((entry) {
          final item = Map<String, dynamic>.from(entry as Map);
          if (item['id']?.toString() == localItemId) {
            item['id'] = remoteItemId;
          }
          return item;
        }).toList(growable: false);
        state['items'] = items;
        payload['state'] = state;
        await _writeSnapshot(storage, key, payload);
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
      final mappedOrderId = orderId == null ? null : orderMap[orderId]?.toString();
      if (mappedOrderId != null && mappedOrderId.isNotEmpty) {
        order['id'] = mappedOrderId;
        reconciled['order'] = order;
      }
    }

    final rawItems = (reconciled['items'] as List?) ?? const [];
    reconciled['items'] = rawItems.map((entry) {
      final item = Map<String, dynamic>.from(entry as Map);
      final itemId = item['id']?.toString();
      final mappedItemId = itemId == null ? null : itemMap[itemId]?.toString();
      if (mappedItemId != null && mappedItemId.isNotEmpty) {
        item['id'] = mappedItemId;
      }
      final orderId = item['order_id']?.toString();
      final mappedOrderId = orderId == null ? null : orderMap[orderId]?.toString();
      if (mappedOrderId != null && mappedOrderId.isNotEmpty) {
        item['order_id'] = mappedOrderId;
      }
      return item;
    }).toList(growable: false);

    final rawChecks = (reconciled['checks'] as List?) ?? const [];
    reconciled['checks'] = rawChecks.map((entry) {
      final check = Map<String, dynamic>.from(entry as Map);
      final orderId = check['order_id']?.toString();
      final mappedOrderId = orderId == null ? null : orderMap[orderId]?.toString();
      if (mappedOrderId != null && mappedOrderId.isNotEmpty) {
        check['order_id'] = mappedOrderId;
      }
      return check;
    }).toList(growable: false);

    return reconciled;
  }

  Future<void> _pruneQueue(
    String businessId,
    List<Map<String, dynamic>> queue,
  ) async {
    final pending = queue.where((item) => !_isCompleted(item)).toList(growable: false);
    final completed = queue.where(_isCompleted).toList(growable: false);
    final keepCompleted = completed.length > 20
        ? completed.sublist(completed.length - 20)
        : completed;
    final compacted = [...pending, ...keepCompleted];
    await _writeQueue(businessId, compacted);
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
    final storage = await _storage;
    final current = await _readOrderMap(businessId);
    current[localOrderId] = remoteOrderId;
    await storage.writeJson(_orderMapKey(businessId), current);
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
    final storage = await _storage;
    final current = await _readCashSessionMap(businessId);
    current[localSessionId] = remoteSessionId;
    await storage.writeJson(_cashSessionMapKey(businessId), current);
  }

  Future<void> _saveItemMapping({
    required String businessId,
    required String localItemId,
    required String remoteItemId,
  }) async {
    final storage = await _storage;
    final current = await _readItemMap(businessId);
    current[localItemId] = remoteItemId;
    await storage.writeJson(_itemMapKey(businessId), current);
  }

  Map<String, dynamic> _encodeState(CurrentOrderState state) {
    return {
      'loading': state.loading,
      'error': state.error,
      'takeout': state.takeout,
      'origin': state.origin,
      'selected_check_id': state.selectedCheckId,
      'customer_id': state.customerId,
      'customer_name': state.customerName,
      'session_note': state.sessionNote,
      'order': state.order == null ? null : _encodeOrder(state.order!),
      'items': state.items.map(_encodeOrderItem).toList(growable: false),
      'checks': state.checks.map(_encodeOrderCheck).toList(growable: false),
    };
  }

  CurrentOrderState _decodeState(Map<String, dynamic> map) {
    return CurrentOrderState(
      loading: map['loading'] == true,
      error: map['error']?.toString(),
      takeout: map['takeout'] == true,
      origin: map['origin']?.toString(),
      selectedCheckId: map['selected_check_id']?.toString(),
      customerId: map['customer_id']?.toString(),
      customerName: map['customer_name']?.toString(),
      sessionNote: map['session_note']?.toString(),
      order: map['order'] is Map
          ? Order.fromMap(Map<String, dynamic>.from(map['order'] as Map))
          : null,
      items: ((map['items'] as List?) ?? const [])
          .map((e) => OrderItem.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false),
      checks: ((map['checks'] as List?) ?? const [])
          .map((e) => OrderCheck.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> _encodeOrder(Order order) => order.toMap();

  Map<String, dynamic> _encodeOrderItem(OrderItem item) => {
    'id': item.id,
    'order_id': item.orderId,
    'product_id': item.productId,
    'product_name': item.productName,
    'sku': item.sku,
    'qty': item.quantity,
    'quantity': item.quantity,
    'unit_price': item.unitPrice,
    'subtotal': item.subtotal,
    'discounts': item.discounts,
    'tax': item.tax,
    'total': item.total,
    'check_id': item.checkId,
    'is_takeout': item.isTakeout,
    'status': item.status,
    'notes': item.notes,
    'created_at': item.createdAt.toIso8601String(),
  };

  Map<String, dynamic> _encodeOrderCheck(OrderCheck check) => {
    'id': check.id,
    'order_id': check.orderId,
    'label': check.label,
    'position': check.position,
    'is_closed': check.isClosed,
    'subtotal': check.subtotal,
    'discounts': check.discounts,
    'tax': check.tax,
    'total': check.total,
  };
}
