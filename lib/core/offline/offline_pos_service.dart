import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:mangopos/core/offline/storage/offline_queue_dao.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';

class OfflineQueueSyncResult {
  const OfflineQueueSyncResult({
    this.processed = 0,
    this.completed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.pending = 0,
    this.lastMappedOrderId,
    this.lastError,
    this.conflicts = const <OfflineSyncConflict>[],
  });

  final int processed;
  final int completed;
  final int failed;
  final int skipped;
  final int pending;
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

class OfflinePosService {
  OfflinePosService._();

  static final OfflinePosService _instance = OfflinePosService._();
  static const Uuid _uuid = Uuid();
  static const String _statusPending = 'pending';
  static const String _statusProcessing = 'processing';
  static const String _statusCompleted = 'completed';
  static const String _statusFailed = 'failed';

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
        msg.contains('handshake');
  }

  Future<StorageService> get _storage async => StorageService.getInstance();

  /// DAO de drift/sqlite para cola + completed_ops + fingerprints.
  /// El resto del cache (snapshots, mappings, catalog, inventory) sigue
  /// en SharedPreferences vía [_storage] — es alcance de Fase 6 solo
  /// migrar lo que tiene problema real de volumen.
  late final OfflineQueueDao _queueDao =
      OfflineQueueDao(OfflineQueueDb.getInstance());

  /// Guard one-time POR BUSINESS: la primera vez que se toca la cola
  /// tras actualizar la app, importamos lo que haya en SharedPreferences
  /// a sqlite y borramos las SP keys legacy. Necesita ser per-business
  /// porque un owner de varias sucursales tendría las cola legacy
  /// distintas en cada SP key — si lo memoizáramos global, la segunda
  /// sucursal saltaría la migración al cambiar de business y perdería
  /// su cola pendiente.
  final Set<String> _migratedBusinesses = <String>{};
  Future<void> _ensureMigratedFromSp(String businessId) async {
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
        await _queueDao.writeQueue(businessId, queueMaps);
      }
      for (final id in legacyOps.map((e) => e.toString())) {
        if (id.isEmpty) continue;
        await _queueDao.markOpCompleted(businessId: businessId, opId: id);
      }
      for (final fp in legacyFps.map((e) => e.toString())) {
        if (fp.isEmpty) continue;
        await _queueDao.markFingerprintCompleted(
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
    await storage.write(_snapshotKey(businessId, slotId), jsonEncode(payload));
  }

  Future<CurrentOrderState?> loadSnapshot({
    required String businessId,
    required String slotId,
  }) async {
    final storage = await _storage;
    final key = _snapshotKey(businessId, slotId);
    final raw = await storage.read(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final stateMap = Map<String, dynamic>.from(payload['state'] as Map);
      final reconciledState = await _reconcileEncodedState(
        businessId: businessId,
        state: stateMap,
      );
      payload['state'] = reconciledState;
      await storage.write(key, jsonEncode(payload));
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
      final raw = await storage.read(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final state = Map<String, dynamic>.from(payload['state'] as Map? ?? {});
        final order = Map<String, dynamic>.from(state['order'] as Map? ?? {});
        if (order['id'] != localOrderId) continue;
        order['id'] = remoteOrderId;
        state['order'] = order;
        payload['state'] = state;
        payload['local_only'] = false;
        await storage.write(key, jsonEncode(payload));
      } catch (e) {
        debugPrint('OfflinePosService.remapSnapshotOrderId error: $e');
      }
    }
  }

  Future<CurrentOrderState> createLocalDraft({
    required String businessId,
    required String origin,
    String? tableId,
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
      slotId: tableId ?? origin,
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
    final current = await _readQueue(businessId);
    // Anotamos device_id de origen (audit LWW). Best-effort: si falla
    // la lectura del id no bloqueamos el enqueue.
    final deviceId = await _resolveDeviceId(businessId);
    final enriched = Map<String, dynamic>.from(action);
    if (deviceId != null && enriched['device_id'] == null) {
      enriched['device_id'] = deviceId;
    }
    current.add(_normalizeAction(enriched));
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
    return queue.where((item) => !_isCompleted(item)).length;
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
    return _queueDao.deleteAllPending(businessId);
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
      return const OfflineQueueSyncResult();
    }

    var processed = 0;
    var completed = 0;
    var failed = 0;
    var skipped = 0;
    String? lastMappedOrderId;
    String? lastError;
    final conflicts = <OfflineSyncConflict>[];

    final completedOps = await _queueDao.readCompletedOps(businessId);
    final completedFingerprints =
        await _queueDao.readCompletedFingerprints(businessId);

    for (var i = 0; i < queue.length; i++) {
      final action = queue[i];
      final actionId = action['id']?.toString();
      final fingerprint = action['fingerprint']?.toString();
      if (_isCompleted(action)) continue;
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
      await _queueDao.upsertAction(businessId, processing);

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
          await _queueDao.markOpCompleted(
            businessId: businessId,
            opId: actionId,
          );
        }
        final fingerprint = processing['fingerprint']?.toString();
        if (fingerprint != null && fingerprint.isNotEmpty) {
          await _queueDao.markFingerprintCompleted(
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
          await _queueDao.markOpCompleted(
            businessId: businessId,
            opId: actionId,
          );
        }
        final fingerprint = processing['fingerprint']?.toString();
        if (fingerprint != null && fingerprint.isNotEmpty) {
          await _queueDao.markFingerprintCompleted(
            businessId: businessId,
            fingerprint: fingerprint,
          );
        }
      } catch (e) {
        final attempts = ((processing['attempts'] as num?)?.toInt() ?? 0) + 1;
        final waitSeconds = _retryDelaySeconds(attempts);
        lastError = e.toString();
        final failedAction = Map<String, dynamic>.from(processing)
          ..['status'] = _statusFailed
          ..['attempts'] = attempts
          ..['last_error'] = lastError
          ..['failed_at'] = DateTime.now().toIso8601String()
          ..['next_retry_at'] = DateTime.now()
              .add(Duration(seconds: waitSeconds))
              .toIso8601String();
        queue[i] = failedAction;
        failed++;
        // Solo cortar si fue por conectividad — todas las siguientes
        // van a fallar por lo mismo. Errores logicos (constraint, RPC
        // reject, item ya borrado por otro terminal) los saltamos para
        // no bloquear la cola; la accion fallida ya tiene su backoff
        // individual y reintenta sola en el siguiente trigger.
        breakLoop = _isConnectivityError(e);
      }

      // UPSERT puntual del action final (completed o failed). Idem
      // optimización anterior: evita reescribir la cola entera.
      await _queueDao.upsertAction(businessId, queue[i]);
      if (breakLoop) break;
    }

    await _pruneQueue(businessId, queue);
    final pending = queue.where((item) => !_isCompleted(item)).length;
    return OfflineQueueSyncResult(
      processed: processed,
      completed: completed,
      failed: failed,
      skipped: skipped,
      pending: pending,
      lastMappedOrderId: lastMappedOrderId,
      lastError: lastError,
      conflicts: List<OfflineSyncConflict>.unmodifiable(conflicts),
    );
  }

  Future<List<Map<String, dynamic>>> _readQueue(String businessId) async {
    await _ensureMigratedFromSp(businessId);
    return _queueDao.readQueue(businessId);
  }

  Future<void> _writeQueue(
    String businessId,
    List<Map<String, dynamic>> queue,
  ) async {
    await _queueDao.writeQueue(businessId, queue);
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
      if (_isCompleted(action) || action['status'] == _statusProcessing) {
        result.add(action);
        continue;
      }

      final type = action['type']?.toString();
      final itemId = action['item_id']?.toString();
      final orderId = action['order_id']?.toString();

      if (itemId != null && itemId.startsWith('tmp_')) {
        final addIndex = result.lastIndexWhere(
          (entry) =>
              !_isCompleted(entry) &&
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
              !_isCompleted(entry) &&
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
              !_isCompleted(entry) &&
              entry['type'] == type &&
              entry['item_id']?.toString() == itemId,
        );
      } else if ({'send_to_kitchen', 'confirm_local_order'}.contains(type) && orderId != null && orderId.isNotEmpty) {
        existingIndex = result.lastIndexWhere(
          (entry) =>
              !_isCompleted(entry) &&
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
        // (List<{name, qty, price}>). Antes esto se perdía: la orden offline
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
      case 'send_to_kitchen':
      case 'confirm_local_order':
        final resolvedOrderId = await _resolveOrderIdForAction(
          businessId: businessId,
          action: action,
          salesRepository: salesRepository,
        );
        await printingService.sendOrderToKitchen(
          orderId: resolvedOrderId,
          businessId: businessId,
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
        await salesRepository.processPayment(
          orderId: resolvedOrderId,
          checkId: action['check_id']?.toString(),
          paymentMethodId: action['payment_method_id']?.toString() ?? '',
          amount: ((action['amount'] ?? 0) as num).toDouble(),
          reference: action['reference']?.toString(),
          customerId: action['customer_id']?.toString(),
          customerRnc: action['customer_rnc']?.toString(),
          cashierSessionId: cashierSessionId,
          changeAmount: ((action['change_amount'] ?? 0) as num).toDouble(),
          paidAt: paidAt,
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
      created = await salesRepository.openManualOrQuick(
        origin: origin,
        customerName: null,
        peopleCount: 1,
      );
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
      final raw = await storage.read(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
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
      final raw = await storage.read(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
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
        await storage.write(key, jsonEncode(payload));
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
    await _queueDao.pruneCompletedOlderThan(const Duration(days: 30));
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
