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
  final Map<String, CurrentOrderState> _tableCache = {};

  @override
  CurrentOrderState build() {
    ref.onDispose(() {
      _realtimeChannel?.unsubscribe();
    });
    return const CurrentOrderState();
  }

  Future<void> openTable(String tableId) async {
    // Mostrar inmediatamente la última versión conocida si existe
    final cached = _tableCache[tableId];
    if (cached != null) {
      state = cached.copyWith(loading: true, error: null);
    } else {
      state = const CurrentOrderState(loading: true, origin: 'table');
    }
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;

      // 1) Abrir mesa en backend
      final result = await ref
          .read(salesRepositoryProvider)
          .openTable(
            tableId: tableId,
            userId: userId, // si es null, el RPC tiene fallback
            peopleCount: 1,
          );
      final orderId = result['order_id'] as String;

      // 2) Traer snapshot compacto vía RPC (si existe)
      try {
        final payload = await ref
            .read(salesRepositoryProvider)
            .getTableLive(tableId);
        if (payload != null) {
          _applyTableLivePayload(payload, tableId: tableId);
        }
      } catch (_) {
        // Si falla RPC, continuamos con load detallado
      }

      // 3) Refresco completo (asegura consistencia)
      await _loadOrderDetail(orderId, origin: 'table', tableId: tableId);
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
    String? productName,
    double? productPrice,
  }) async {
    final orderId = state.order?.id;
    if (orderId == null) {
      state = state.copyWith(error: 'Orden no disponible. Reintenta.');
      return;
    }

    // Si hay un check seleccionado, usar su posición (salvo que checkPos sea explícito > 1)
    int effectiveCheckPos = checkPos;
    if (checkPos == 1 && state.selectedCheckId != null) {
      try {
        final check = state.checks.firstWhere(
          (c) => c.id == state.selectedCheckId,
        );
        effectiveCheckPos = check.position;
      } catch (_) {
        // Si no se encuentra, default a 1
      }
    }

    state = state.copyWith(error: null);
    final previousItems = state.items;
    final previousOrder = state.order;

    // Optimistic: solo si tenemos datos del producto y un order cargado
    OrderItem? optimisticItem;
    if (productName != null &&
        productPrice != null &&
        previousOrder != null &&
        qty > 0) {
      final tempId = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
      final base = productPrice * qty;
      final taxRate = previousOrder.subtotal > 0
          ? previousOrder.tax / previousOrder.subtotal
          : 0;
      final serviceRate = previousOrder.subtotal > 0
          ? previousOrder.serviceFee / previousOrder.subtotal
          : 0;
      final addTax = base * taxRate;
      final addService = base * serviceRate;
      final addTotal = base + addTax + addService;

      optimisticItem = OrderItem(
        id: tempId,
        orderId: orderId,
        productId: menuItemId,
        productName: productName,
        sku: null,
        quantity: qty,
        unitPrice: productPrice,
        subtotal: base,
        discounts: 0,
        tax: addTax,
        total: addTotal,
        checkId: null,
        isTakeout: takeout,
        status: 'draft',
        notes: notes,
        createdAt: DateTime.now(),
        modifiers: const [],
      );

      final updatedOrder = previousOrder.copyWith(
        subtotal: previousOrder.subtotal + base,
        tax: previousOrder.tax + addTax,
        serviceFee: previousOrder.serviceFee + addService,
        total: previousOrder.total + addTotal,
      );

      state = state.copyWith(
        items: [...state.items, optimisticItem],
        order: updatedOrder,
      );
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .addItemFromMenu(
            orderId: orderId,
            menuItemId: menuItemId,
            quantity: qty,
            checkPosition: effectiveCheckPos,
            isTakeout: takeout,
            notes: notes,
          );
      unawaited(_loadOrderDetail(orderId));
    } catch (e) {
      // Revertir si hicimos optimismo
      if (optimisticItem != null) {
        state = state.copyWith(
          items: previousItems,
          order: previousOrder,
          error: 'Error al agregar: $e',
        );
      } else {
        state = state.copyWith(error: 'Error al agregar producto: $e');
      }
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

    // 1. Snapshot for rollback
    final previousItems = state.items;
    final previousOrder = state.order;

    // 2. Optimistic Local Update
    final updatedItems = state.items.where((i) => i.id != itemId).toList();

    // Calculate simple totals for immediate feedback
    final newTotal = updatedItems.fold(0.0, (sum, i) => sum + i.total);
    final newSubtotal = updatedItems.fold(0.0, (sum, i) => sum + i.subtotal);
    final newTax = updatedItems.fold(0.0, (sum, i) => sum + i.tax);

    final updatedOrder = state.order?.copyWith(
      total: newTotal,
      subtotal: newSubtotal,
      tax: newTax,
    );

    state = state.copyWith(items: updatedItems, order: updatedOrder);

    try {
      // 3. Perform Backend Operation
      await ref.read(salesRepositoryProvider).deleteItem(itemId: itemId);

      // 4. Sync State (to ensure server calculations/triggers are reflected)
      await _loadOrderDetail(orderId);
    } catch (e) {
      // 5. Revert on Error
      state = state.copyWith(
        items: previousItems,
        order: previousOrder,
        error: 'Error al eliminar: $e',
      );
    }
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

  /// Remueve localmente un check (subcuenta) y sus items, ajustando totales.
  void removeCheckLocally(String checkId) {
    final currentOrder = state.order;
    if (currentOrder == null) return;

    final removedItems = state.items
        .where((i) => i.checkId == checkId)
        .toList();
    if (removedItems.isEmpty) return;

    final remainingItems = state.items
        .where((i) => i.checkId != checkId)
        .toList();

    final remSubtotal = remainingItems.fold<double>(
      0,
      (s, i) => s + i.subtotal,
    );
    final remDiscounts = remainingItems.fold<double>(
      0,
      (s, i) => s + i.discounts,
    );
    final remTax = remainingItems.fold<double>(0, (s, i) => s + i.tax);
    final remTotal = remainingItems.fold<double>(0, (s, i) => s + i.total);

    final newOrder = currentOrder.copyWith(
      subtotal: remSubtotal,
      discounts: remDiscounts,
      tax: remTax,
      total: remTotal,
    );

    final remainingChecks = state.checks.where((c) => c.id != checkId).toList();

    state = state.copyWith(
      items: remainingItems,
      order: newOrder,
      checks: remainingChecks,
      clearSelectedCheck: state.selectedCheckId == checkId,
    );

    // actualiza cache si mesa activa
    if (state.origin == 'table') {
      final activeTableEntry = _tableCache.entries.firstWhere(
        (e) => e.value.order?.id == currentOrder.id,
        orElse: () =>
            MapEntry<String, CurrentOrderState>('', const CurrentOrderState()),
      );
      if (activeTableEntry.key.isNotEmpty) {
        _tableCache[activeTableEntry.key] = state;
      }
    }
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

  void selectCheck(String? checkId) {
    state = state.copyWith(
      selectedCheckId: checkId,
      clearSelectedCheck: checkId == null,
    );
  }

  Future<void> _loadOrderDetail(
    String orderId, {
    String? origin,
    String? tableId,
  }) async {
    final repo = ref.read(salesRepositoryProvider);
    Order? order;
    List<OrderItem> items = const [];
    List<OrderCheck> checks = const [];
    String? loadError;
    final orderFuture = repo.getOrder(orderId);
    final itemsFuture = repo.getOrderItems(
      orderId,
      includeModifiers: false,
      limit: 500,
      onlyOpen: true,
    );
    final checksFuture = repo.getOrderChecks(orderId);

    try {
      order = await orderFuture;
      checks = await checksFuture;
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

    // Verificar si el check seleccionado todavía existe
    String? newSelectedCheckId = state.selectedCheckId;
    if (newSelectedCheckId != null) {
      final exists = checks.any(
        (c) => c.id == newSelectedCheckId && !c.isClosed,
      );
      if (!exists) {
        newSelectedCheckId = null;
      }
    }

    state = state.copyWith(
      loading: false,
      order: order ?? state.order,
      items: items,
      checks: checks,
      origin: origin ?? state.origin,
      error: items.isEmpty ? (loadError ?? state.error) : null,
      selectedCheckId: newSelectedCheckId,
      clearSelectedCheck:
          newSelectedCheckId == null && state.selectedCheckId != null,
    );

    // Cachear última versión por mesa para apertura optimista
    if (origin == 'table' && tableId != null) {
      _tableCache[tableId] = state;
    }

    _subscribeToOrderUpdates(orderId);
  }

  RealtimeChannel? _realtimeChannel;

  void _subscribeToOrderUpdates(String orderId) {
    if (_realtimeChannel != null) {
      // If already subscribed to this order, do nothing
      // We could check if channel topic matches, but simple unsubscribe/resubscribe is safer
      _realtimeChannel!.unsubscribe();
    }

    final client = Supabase.instance.client;
    _realtimeChannel = client.channel('order_view_$orderId');

    _realtimeChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_items',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: orderId,
          ),
          callback: (payload) {
            // Refresh order on any item change
            refreshOrder();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_checks',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: orderId,
          ),
          callback: (payload) {
            // Refresh on check changes (splits, payments, closing)
            refreshOrder();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: orderId,
          ),
          callback: (payload) {
            // Refresh on order status change (e.g. paid/closed)
            // Check if order is closed/paid to clear state or navigate back could be logic here
            refreshOrder(clearIfPaid: true);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'payments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: orderId,
          ),
          callback: (payload) {
            refreshOrder();
          },
        )
        .subscribe();
  }

  void _applyTableLivePayload(
    Map<String, dynamic> payload, {
    required String tableId,
  }) {
    try {
      final orderMap = Map<String, dynamic>.from(payload['order'] as Map);
      final order = Order.fromMap(orderMap);

      final checks = ((payload['checks'] as List?) ?? []).map((c) {
        final m = Map<String, dynamic>.from(c as Map);
        return OrderCheck(
          id: m['id'] ?? '',
          orderId: order.id,
          label: m['label'] ?? 'C1',
          position: (m['position'] ?? 1) as int,
          isClosed: false,
          subtotal: (m['subtotal'] ?? 0).toDouble(),
          discounts: (m['discounts'] ?? 0).toDouble(),
          tax: (m['tax'] ?? 0).toDouble(),
          total: (m['total'] ?? 0).toDouble(),
          items: const [],
        );
      }).toList();

      final items = ((payload['items'] as List?) ?? []).map((i) {
        final m = Map<String, dynamic>.from(i as Map);
        return OrderItem(
          id: m['id'] ?? '',
          orderId: order.id,
          productId: m['product_id'],
          productName: m['product_name'] ?? '',
          sku: m['sku'],
          quantity: (m['quantity'] ?? m['qty'] ?? 1).toDouble(),
          unitPrice: (m['unit_price'] ?? 0).toDouble(),
          subtotal: (m['subtotal'] ?? 0).toDouble(),
          discounts: (m['discounts'] ?? 0).toDouble(),
          tax: (m['tax'] ?? 0).toDouble(),
          total: (m['total'] ?? 0).toDouble(),
          checkId: m['check_id'],
          isTakeout: m['is_takeout'] ?? false,
          status: m['status'] ?? 'draft',
          notes: m['notes'],
          createdAt: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
          modifiers: const [],
        );
      }).toList();

      final newState = state.copyWith(
        loading: false,
        origin: 'table',
        order: order,
        items: items,
        checks: checks,
        error: null,
      );

      state = newState;
      _tableCache[tableId] = newState;
    } catch (e) {
      // Si el payload viene incompleto, ignoramos y dejamos al load completo
    }
  }
}
