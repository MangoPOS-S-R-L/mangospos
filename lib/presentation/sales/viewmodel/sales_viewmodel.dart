import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../state/sales_state.dart';
import '../../../data/models/sales_models.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';

final salesRepositoryProvider = Provider<SalesRepository>(
  (ref) => SalesRepository(Supabase.instance.client),
);

final currentOrderProvider =
    NotifierProvider<SalesViewModel, CurrentOrderState>(SalesViewModel.new);

class SalesViewModel extends Notifier<CurrentOrderState> {
  @override
  CurrentOrderState build() => const CurrentOrderState();

  Future<void> openTable(String tableId) async {
    // Reset state completely to avoid showing data from previous table
    state = const CurrentOrderState(loading: true);
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      final result = await ref
          .read(salesRepositoryProvider)
          .openTable(
            tableId: tableId,
            userId: userId, // si es null, el RPC tiene fallback
            peopleCount: 1,
          );
      final orderId = result['order_id'] as String;
      await _loadOrderDetail(orderId, origin: 'table');
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> openManual({bool forceRestart = false}) async =>
      _openManualOrQuick('manual', forceReset: forceRestart);
  Future<void> openQuick({bool forceRestart = false}) async =>
      _openManualOrQuick('quick', forceReset: forceRestart);

  Future<void> ensureManualOrder() async {
    if (state.origin == 'manual' && state.order != null) return;
    await openManual(forceRestart: true);
  }

  Future<void> _openManualOrQuick(
    String origin, {
    bool forceReset = false,
  }) async {
    state = forceReset
        ? const CurrentOrderState(loading: true)
        : state.copyWith(loading: true, error: null);
    try {
      final res = await ref
          .read(salesRepositoryProvider)
          .openManualOrQuick(
            origin: origin,
            customerName: null,
            peopleCount: 1,
          );
      await _loadOrderDetail(res['order_id'] as String, origin: origin);
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
    if (orderId == null) {
      state = state.copyWith(error: 'Orden no disponible. Reintenta.');
      return;
    }
    state = state.copyWith(error: null);
    try {
      await ref
          .read(salesRepositoryProvider)
          .addItemFromMenu(
            orderId: orderId,
            menuItemId: menuItemId,
            quantity: qty,
            checkPosition: checkPos,
            isTakeout: takeout,
            notes: notes,
          );
      unawaited(_loadOrderDetail(orderId));
    } catch (e) {
      state = state.copyWith(error: 'Error al agregar producto: $e');
    }
  }

  Future<void> toggleTakeout(bool value) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref
        .read(salesRepositoryProvider)
        .markOrderTakeout(orderId: orderId, takeout: value);
    state = state.copyWith(takeout: value);
    await _loadOrderDetail(orderId);
  }

  Future<void> deleteItem(String itemId) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref.read(salesRepositoryProvider).deleteItem(itemId: itemId);
    await _loadOrderDetail(orderId);
  }

  Future<void> updateItemQuantity(String itemId, double quantity) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref
        .read(salesRepositoryProvider)
        .updateItemQuantity(itemId: itemId, quantity: quantity);
    await _loadOrderDetail(orderId);
  }

  Future<void> updateItemNotes(String itemId, String notes) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref
        .read(salesRepositoryProvider)
        .updateItemNotes(itemId: itemId, notes: notes);
    await _loadOrderDetail(orderId);
  }

  Future<void> toggleItemTakeout(String itemId, bool isTakeout) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref
        .read(salesRepositoryProvider)
        .toggleItemTakeout(itemId: itemId, isTakeout: isTakeout);
    await _loadOrderDetail(orderId);
  }

  Future<void> moveItemToCheck(String itemId, int pos) async {
    await ref
        .read(salesRepositoryProvider)
        .moveItemToCheck(itemId: itemId, checkPosition: pos);
    final orderId = state.order?.id;
    if (orderId != null) await _loadOrderDetail(orderId);
  }

  Future<void> closeOrderPaid() async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref
        .read(salesRepositoryProvider)
        .closeOrder(orderId: orderId, status: 'paid');

    // Refresh cashier data in the background
    try {
      final cashierVM = ref.read(cashierViewModelProvider.notifier);
      unawaited(cashierVM.refreshSilently());
    } catch (e) {
      // Cashier refresh is not critical, just log
      print('Note: Could not refresh cashier: $e');
    }

    state = const CurrentOrderState();
  }

  Future<void> cancelCurrentOrder() async {
    final orderId = state.order?.id;
    if (orderId == null) {
      state = const CurrentOrderState();
      return;
    }
    await ref
        .read(salesRepositoryProvider)
        .closeOrder(orderId: orderId, status: 'void');
    state = const CurrentOrderState();
  }

  // Method to confirm order (send to kitchen)
  Future<void> confirmOrder() async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    state = state.copyWith(loading: true);
    try {
      await ref.read(salesRepositoryProvider).confirmOrderToKitchen(orderId);
      await _loadOrderDetail(orderId);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> refreshOrder({bool clearIfPaid = false}) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    await _loadOrderDetail(orderId);
    if (clearIfPaid && (state.order?.isPaid ?? false)) {
      state = const CurrentOrderState();
    }
  }

  Future<void> _loadOrderDetail(String orderId, {String? origin}) async {
    final repo = ref.read(salesRepositoryProvider);
    Order? order;
    List<OrderItem> items = const [];
    String? loadError;
    final orderFuture = repo.getOrder(orderId);
    final itemsFuture = repo.getOrderItems(orderId, includeModifiers: false);

    try {
      order = await orderFuture;
    } catch (e) {
      loadError = e.toString();
    }

    try {
      items = await itemsFuture;
    } catch (e) {
      loadError ??= e.toString();
    }

    if (order == null && items.isEmpty) {
      state = state.copyWith(
        loading: false,
        error: loadError ?? 'Orden no encontrada',
      );
      return;
    }

    state = state.copyWith(
      loading: false,
      order: order ?? state.order,
      items: items,
      origin: origin ?? state.origin,
      error: items.isEmpty ? (loadError ?? state.error) : null,
    );
  }
}
