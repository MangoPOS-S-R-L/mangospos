import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';

class OfflinePosService {
  OfflinePosService._();

  static final OfflinePosService _instance = OfflinePosService._();
  static const Uuid _uuid = Uuid();

  factory OfflinePosService() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _snapshotKey(String businessId, String slotId) =>
      'offline_snapshot_${businessId}_$slotId';
  String _queueKey(String businessId) => 'offline_queue_$businessId';
  String _printQueueKey(String businessId) => 'offline_print_queue_$businessId';

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
    final raw = await storage.read(_snapshotKey(businessId, slotId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final payload = jsonDecode(raw) as Map<String, dynamic>;
      return _decodeState(Map<String, dynamic>.from(payload['state'] as Map));
    } catch (e) {
      debugPrint('OfflinePosService.loadSnapshot error: $e');
      return null;
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
    final storage = await _storage;
    final current =
        await storage.readList(_queueKey(businessId)) ?? <dynamic>[];
    current.add({...action, 'queued_at': DateTime.now().toIso8601String()});
    await storage.writeList(_queueKey(businessId), current);
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
    final storage = await _storage;
    return (await storage.readList(_queueKey(businessId)) ?? const []).length;
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
