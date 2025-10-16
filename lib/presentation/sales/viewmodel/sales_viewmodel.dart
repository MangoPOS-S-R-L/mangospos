import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/order.dart';
import 'package:mangopos/data/models/order_item.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../state/sales_state.dart';

final salesRepositoryProvider = Provider<SalesRepository>(
  (ref) => SalesRepository(Supabase.instance.client),
);

final currentOrderProvider = NotifierProvider<SalesViewModel, CurrentOrderState>(
  SalesViewModel.new,
);

class SalesViewModel extends Notifier<CurrentOrderState> {
  @override
  CurrentOrderState build() => const CurrentOrderState();

  Future<void> openTable(String tableId) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      final result = await ref.read(salesRepositoryProvider).openTable(
        tableId: tableId,
        userId: userId, // si es null, el RPC tiene fallback
        peopleCount: 1,
      );
      final orderId = result['order_id'] as String;

      // Cargamos detalle
      await _loadOrderDetail(orderId);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> openManual() async => _openManualOrQuick('manual');
  Future<void> openQuick() async => _openManualOrQuick('quick');

  Future<void> _openManualOrQuick(String origin) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      final res = await ref
          .read(
            salesRepositoryProvider,
          )
          .openManualOrQuick(origin: origin, userId: userId ?? '', peopleCount: 1);
      await _loadOrderDetail(res['order_id'] as String);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> addItem({
    required String menuItemId,
    double qty = 1,
    int checkPos = 1,
    bool takeout = false,
    String? notes,
  }) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref.read(salesRepositoryProvider).addItemFromMenu(
      orderId: orderId,
      menuItemId: menuItemId,
      qty: qty,
      checkPosition: checkPos,
      isTakeout: takeout,
      notes: notes,
    );
    await _loadOrderDetail(orderId);
  }

  Future<void> toggleTakeout(bool value) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref.read(
      salesRepositoryProvider,
    ).markOrderTakeout(orderId: orderId, takeout: value);
    state = state.copyWith(takeout: value);
    await _loadOrderDetail(orderId);
  }

  Future<void> moveItemToCheck(String itemId, int pos) async {
    await ref.read(
      salesRepositoryProvider,
    ).moveItemToCheck(itemId: itemId, checkPosition: pos);
    final orderId = state.order?.id;
    if (orderId != null) await _loadOrderDetail(orderId);
  }

  Future<void> closeOrderPaid() async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref.read(
      salesRepositoryProvider,
    ).closeOrder(orderId: orderId, status: 'paid');
    // limpia el estado
    state = const CurrentOrderState();
  }

  Future<void> _loadOrderDetail(String orderId) async {
    final repo = ref.read(salesRepositoryProvider);
    final rows = await repo.getOrderDetail(orderId);
    // Map a Order + Items
    if (rows.isEmpty) {
      state = state.copyWith(loading: false);
      return;
    }
    // La fila tiene totales de orden repetidos – tomamos la primera
    final o = Order.fromMap({
      'id': orderId,
      'session_id': null,
      'status_ext': rows.first['status_ext'],
      'subtotal': rows.first['order_subtotal'],
      'discounts': rows.first['order_discounts'],
      'tax': rows.first['order_tax'],
      'total': rows.first['order_total'],
      'created_at': DateTime.now().toIso8601String(),
    });
    final items = rows
        .where((m) => m['item_id'] != null)
        .map(
          (m) => OrderItem.fromMap({
            'id': m['item_id'],
            'order_id': orderId,
            'check_id': m['check_id'],
            'product_id': m['product_id'],
            'product_name': m['product_name'],
            'qty': m['qty'],
            'unit_price': m['unit_price'],
            'is_takeout': m['is_takeout'],
            'status': m['status'],
            'notes': m['notes'],
            'subtotal': m['subtotal'],
            'discounts': m['discounts'],
            'tax': m['tax'],
            'total': m['total'],
          }),
        )
        .toList();

    state = state.copyWith(loading: false, order: o, items: items);
  }
}
