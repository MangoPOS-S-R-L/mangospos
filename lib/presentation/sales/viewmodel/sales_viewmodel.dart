import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../state/sales_state.dart';
import '../../../data/models/sales_models.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart';
import '../../../services/fiscal/fiscal_service.dart';
import '../../../data/models/fiscal_models.dart';

final salesRepositoryProvider = Provider<SalesRepository>(
  (ref) => SalesRepository(Supabase.instance.client),
);

final printingServiceProvider = Provider<PrintingService>(
  (ref) => PrintingService(Supabase.instance.client),
);

final currentOrderProvider =
    NotifierProvider<SalesViewModel, CurrentOrderState>(SalesViewModel.new);

class SalesViewModel extends Notifier<CurrentOrderState> {
  static const _courtesyPrefix = '[CORTESIA:';
  static const _defaultTaxRatePct = 18.0;
  static const _defaultServiceFeeRatePct = 10.0;
  final Map<String, CurrentOrderState> _tableCache = {};
  final OfflinePosService _offlinePos = OfflinePosService();
  final ConnectivityService _connectivity = ConnectivityService();
  Timer? _refreshOrderDebounceTimer;
  StreamSubscription<bool>? _connectivitySubscription;
  String? _queuedRefreshOrderId;
  bool _queuedClearIfPaid = false;
  bool _refreshOrderInFlight = false;
  bool _syncInFlight = false;
  String? _taxSettingsBusinessId;
  double _cachedTaxRatePct = _defaultTaxRatePct;
  double _cachedServiceFeeRatePct = _defaultServiceFeeRatePct;
  bool _cachedServiceFeeEnabled = false;

  double _roundMoney(double value) => double.parse(value.toStringAsFixed(2));

  Future<void> refreshOfflineMonitor() => _refreshOfflineMonitor();

  Future<void> _refreshOfflineMonitor({
    String? syncStatus,
    bool? syncInFlight,
  }) async {
    final businessId = _activeBusinessId;
    final pending = businessId == null || businessId.isEmpty
        ? 0
        : await _offlinePos.pendingActionsCount(businessId);
    state = state.copyWith(
      isOfflineMode: !_connectivity.isConnected,
      syncInFlight: syncInFlight ?? _syncInFlight,
      pendingOfflineActions: pending,
      syncStatus: syncStatus ?? state.syncStatus,
    );
  }

  static const _refreshOrderDebounce = Duration(milliseconds: 250);

  static const _cashierClosedMessage =
      'Debes abrir la caja antes de iniciar una venta.';

  @override
  CurrentOrderState build() {
    unawaited(_connectivity.initialize());
    unawaited(_refreshOfflineMonitor());
    _connectivitySubscription ??= _connectivity.connectionStream.listen((
      isConnected,
    ) {
      unawaited(
        _refreshOfflineMonitor(
          syncStatus: isConnected
              ? 'Conexión restaurada. Revisando sincronización...'
              : 'Sin conexión. Trabajando en modo offline.',
        ),
      );
      if (isConnected) {
        unawaited(syncPendingOfflineActions());
      }
    });

    ref.onDispose(() {
      _realtimeChannel?.unsubscribe();
      _realtimeChannel = null;
      _subscribedOrderId = null;
      _refreshOrderDebounceTimer?.cancel();
      _refreshOrderDebounceTimer = null;
      _connectivitySubscription?.cancel();
      _connectivitySubscription = null;
    });
    return const CurrentOrderState();
  }

  String? get _activeBusinessId => ref.read(sessionProvider).activeBusinessId;

  Future<void> _ensureBusinessTaxSettingsLoaded() async {
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      _taxSettingsBusinessId = null;
      _cachedTaxRatePct = _defaultTaxRatePct;
      _cachedServiceFeeRatePct = _defaultServiceFeeRatePct;
      _cachedServiceFeeEnabled = false;
      return;
    }

    if (_taxSettingsBusinessId == businessId) return;

    try {
      final row = await Supabase.instance.client
          .from('business_settings')
          .select('default_tax_rate,service_fee_enabled,service_fee_rate')
          .eq('business_id', businessId)
          .maybeSingle();

      _cachedTaxRatePct =
          (row?['default_tax_rate'] as num?)?.toDouble() ?? _defaultTaxRatePct;
      _cachedServiceFeeEnabled = row?['service_fee_enabled'] == true;
      _cachedServiceFeeRatePct =
          (row?['service_fee_rate'] as num?)?.toDouble() ??
          _defaultServiceFeeRatePct;
      _taxSettingsBusinessId = businessId;
    } catch (_) {
      _cachedTaxRatePct = _defaultTaxRatePct;
      _cachedServiceFeeRatePct = _defaultServiceFeeRatePct;
      _cachedServiceFeeEnabled = false;
      _taxSettingsBusinessId = businessId;
    }
  }

  double _sanitizeProductTaxRatePct({
    required double? rawTaxRatePct,
    required String taxMode,
    required bool takeout,
  }) {
    final resolvedRawTaxRate = (rawTaxRatePct ?? _cachedTaxRatePct)
        .clamp(0, 100)
        .toDouble();

    if (taxMode != 'inclusive' || takeout || !_cachedServiceFeeEnabled) {
      return resolvedRawTaxRate;
    }

    final combinedRate = _cachedTaxRatePct + _cachedServiceFeeRatePct;
    if ((resolvedRawTaxRate - combinedRate).abs() <= 0.01) {
      return _cachedTaxRatePct;
    }

    return resolvedRawTaxRate;
  }

  Order _pricingOrderContext(Order order, List<OrderItem> items) {
    if (!_cachedServiceFeeEnabled) {
      return order.copyWith(serviceFee: 0);
    }

    final serviceableSubtotal = items
        .where((item) => item.status != 'void' && !item.isTakeout)
        .fold<double>(0, (sum, item) => sum + item.subtotal);
    final normalizedServiceableSubtotal = _roundMoney(serviceableSubtotal);

    if (normalizedServiceableSubtotal <= 0) {
      return order.copyWith(serviceFee: 0);
    }

    final serviceFee = _roundMoney(
      normalizedServiceableSubtotal * (_cachedServiceFeeRatePct / 100.0),
    );

    return order.copyWith(
      subtotal: normalizedServiceableSubtotal,
      serviceFee: serviceFee,
    );
  }

  CurrentOrderState _normalizeHydratedState(CurrentOrderState source) {
    final order = source.order;
    if (order == null || source.items.isEmpty) {
      return source;
    }

    final activeItems = source.items
        .where((item) => item.status != 'void')
        .toList(growable: false);
    if (activeItems.isEmpty) {
      return source.copyWith(
        order: order.copyWith(
          subtotal: 0,
          discounts: 0,
          serviceFee: 0,
          tax: 0,
          total: 0,
        ),
      );
    }

    final pricingOrder = _pricingOrderContext(order, activeItems);
    final orderSummary = summarizeOrderPricing(pricingOrder, activeItems);
    final normalizedOrder = order.copyWith(
      subtotal: orderSummary.subtotal,
      discounts: orderSummary.discounts,
      serviceFee: orderSummary.serviceFee,
      tax: orderSummary.tax,
      total: orderSummary.total,
    );

    final normalizedChecks = source.checks
        .map((check) {
          final checkItems = activeItems
              .where((item) => item.checkId == check.id)
              .toList(growable: false);
          if (checkItems.isEmpty) {
            return check;
          }

          final checkSummary = summarizeOrderPricing(
            _pricingOrderContext(
              check.toOrder(createdAt: order.createdAt),
              checkItems,
            ),
            checkItems,
          );

          return check.copyWith(
            subtotal: checkSummary.subtotal,
            discounts: checkSummary.discounts,
            serviceFee: checkSummary.serviceFee,
            tax: checkSummary.tax,
            total: checkSummary.total,
          );
        })
        .toList(growable: false);

    return source.copyWith(order: normalizedOrder, checks: normalizedChecks);
  }

  Future<void> _persistCurrentState({
    String? tableId,
    bool localOnly = false,
  }) async {
    final businessId = _activeBusinessId;
    final origin = state.origin;
    if (businessId == null ||
        businessId.isEmpty ||
        origin == null ||
        state.order == null) {
      return;
    }

    await _offlinePos.saveSnapshot(
      businessId: businessId,
      slotId:
          tableId ??
          (origin == 'table' ? (state.order?.sessionId ?? origin) : origin),
      origin: origin,
      tableId: tableId,
      state: state,
      localOnly: localOnly,
    );
  }

  Future<bool> ensureCashSessionOpen() async {
    final cashierVm = ref.read(cashierViewModelProvider);
    try {
      final isOpen = await cashierVm.ensureCashOpenFast();
      if (!isOpen) {
        state = state.copyWith(loading: false, error: _cashierClosedMessage);
        return false;
      }
      return true;
    } catch (_) {
      state = state.copyWith(loading: false, error: _cashierClosedMessage);
      return false;
    }
  }

  Future<void> openTable(String tableId, {int peopleCount = 1}) async {
    // Solo los roles con permisos de caja (cajero/admin/manager) necesitan
    // una sesión de caja abierta. Los meseros pueden abrir mesas directamente.
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final hasCashierAccess = sessionCtrl.hasAnyPermission([
      'caja.apertura',
      'caja.cierre',
      'caja.movimientos_ver',
    ]);
    if (hasCashierAccess) {
      if (!await ensureCashSessionOpen()) return;
    }
    await _ensureBusinessTaxSettingsLoaded();

    // Mostrar inmediatamente la última versión conocida si existe
    final cached = _tableCache[tableId];
    if (cached != null) {
      // Evita pestañeo de subcuentas cerradas por cache obsoleto.
      // Los checks autoritativos llegan en _loadOrderDetail().
      state = _normalizeHydratedState(
        cached.copyWith(
          loading: true,
          error: null,
          checks: const [],
          clearSelectedCheck: true,
        ),
      );
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
            peopleCount: peopleCount,
          );
      final orderId = result['order_id'] as String;

      // 2) Traer snapshot compacto vía RPC (si existe)
      try {
        final payload = await ref
            .read(salesRepositoryProvider)
            .getTableLive(tableId, businessId: _activeBusinessId);
        if (payload != null) {
          _applyTableLivePayload(payload, tableId: tableId);
        }
      } catch (_) {
        // Si falla RPC, continuamos con load detallado
      }

      // 3) Refresco completo (asegura consistencia)
      await _loadOrderDetail(orderId, origin: 'table', tableId: tableId);
    } catch (e) {
      final businessId = _activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        final offlineState = await _offlinePos.loadSnapshot(
          businessId: businessId,
          slotId: tableId,
        );
        if (offlineState != null) {
          state = _normalizeHydratedState(
            offlineState.copyWith(
              loading: false,
              error: 'Modo offline: usando copia local de la mesa.',
              origin: 'table',
            ),
          );
          _tableCache[tableId] = state;
          return;
        }
      }
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

  Future<void> ensureQuickOrder() async {
    if (state.origin == 'quick' && state.order != null) return;
    await openQuick(forceRestart: true);
  }

  Future<void> assignManualOrderToTable({
    required String orderId,
    required String tableId,
  }) async {
    if (!await ensureCashSessionOpen()) return;

    state = state.copyWith(loading: true, error: null);
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      await ref
          .read(salesRepositoryProvider)
          .assignManualOrderToTable(
            orderId: orderId,
            tableId: tableId,
            userId: userId,
          );
      await openTable(tableId);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> assignCustomerToCurrentOrder({
    required String customerId,
    required String customerName,
    String? customerLegalName,
    String? customerTaxId,
  }) async {
    final order = state.order;
    if (order == null) return;

    try {
      await ref
          .read(salesRepositoryProvider)
          .assignCustomerToSession(
            sessionId: order.sessionId,
            customerId: customerId,
            customerName: customerName,
            businessId: _activeBusinessId,
          );
      state = state.copyWith(
        customerId: customerId,
        customerName: customerName,
        customerLegalName: customerLegalName,
        customerTaxId: customerTaxId,
      );
      await _loadOrderDetail(order.id, origin: state.origin);
    } catch (e) {
      state = state.copyWith(error: 'Error al asignar cliente: $e');
    }
  }

  void updateFiscalType(String type) {
    state = state.copyWith(fiscalType: type);
  }

  Future<void> updateCurrentSessionNote(String? note) async {
    final order = state.order;
    if (order == null) return;

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateSessionNote(
            sessionId: order.sessionId,
            note: note,
            businessId: _activeBusinessId,
          );
      state = state.copyWith(
        sessionNote: note?.trim(),
        clearSessionNote: note == null,
      );
    } catch (e) {
      state = state.copyWith(error: 'Error al actualizar nota de sesión: $e');
      rethrow;
    }
  }

  Future<void> appendVoidAuditNote({required String reason}) async {
    final order = state.order;
    if (order == null) return;

    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) return;

    final userName = ref.read(sessionProvider).userName?.trim() ?? '';
    final stamp = DateTime.now().toLocal().toIso8601String();
    final auditLine =
        '[ANULACION][$stamp] ${userName.isEmpty ? 'Usuario' : userName}: $trimmedReason';

    final current = state.sessionNote?.trim();
    final nextNote = (current == null || current.isEmpty)
        ? auditLine
        : '$current\n$auditLine';

    await updateCurrentSessionNote(nextNote);
  }

  Future<void> _openManualOrQuick(
    String origin, {
    bool forceReset = false,
  }) async {
    await _ensureBusinessTaxSettingsLoaded();
    if (!await ensureCashSessionOpen()) return;

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
      final businessId = _activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        final cached = await _offlinePos.loadSnapshot(
          businessId: businessId,
          slotId: origin,
        );
        if (cached != null) {
          state = _normalizeHydratedState(
            cached.copyWith(
              loading: false,
              error: 'Modo offline: usando venta local persistida.',
              origin: origin,
            ),
          );
          return;
        }

        final localDraft = await _offlinePos.createLocalDraft(
          businessId: businessId,
          origin: origin,
        );
        state = localDraft.copyWith(
          error: 'Modo offline: venta local creada. Se sincroniza luego.',
        );
        return;
      }
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
    String productTaxMode = 'exclusive',
    double? productTaxRate,
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
      await _ensureBusinessTaxSettingsLoaded();
      final tempId = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
      final grossAmount = productPrice * qty;
      // Si productTaxRate es null (desconocido), intentamos inferirlo de la orden.
      // Si es 0 explícitamente, el producto NO tiene impuesto -> respetamos el 0.
      final effectiveTaxRatePct = _sanitizeProductTaxRatePct(
        rawTaxRatePct: productTaxRate,
        taxMode: productTaxMode,
        takeout: takeout,
      );
      // El estimador recibe la tasa como fracción decimal (0.18 = 18%)
      final taxRateDecimal = effectiveTaxRatePct / 100.0;
      final optimisticServiceRate = takeout || !_cachedServiceFeeEnabled
          ? 0.0
          : (_cachedServiceFeeRatePct / 100.0);
      final optimisticAmounts = _estimateOptimisticItemAmounts(
        grossAmount: grossAmount,
        taxMode: productTaxMode,
        taxRate: taxRateDecimal,
        serviceRate: optimisticServiceRate,
        includeServiceInInclusivePrice: !takeout,
      );
      final addService = optimisticServiceRate > 0
          ? (optimisticAmounts.subtotal * optimisticServiceRate)
          : 0.0;

      optimisticItem = OrderItem(
        id: tempId,
        orderId: orderId,
        productId: menuItemId,
        productName: productName,
        sku: null,
        quantity: qty,
        unitPrice: productPrice,
        subtotal: optimisticAmounts.subtotal,
        discounts: 0,
        tax: optimisticAmounts.tax,
        total: optimisticAmounts.total,
        checkId: null,
        isTakeout: takeout,
        status: 'draft',
        notes: notes,
        taxMode: productTaxMode,
        taxRate: effectiveTaxRatePct,
        createdAt: DateTime.now(),
        modifiers: const [],
      );

      final optimisticItems = [...state.items, optimisticItem];
      final updatedSummary = summarizeOrderPricing(
        previousOrder,
        optimisticItems,
      );
      final resolvedServiceFee = updatedSummary.serviceFee > 0
          ? updatedSummary.serviceFee
          : addService;
      final resolvedTotal = updatedSummary.serviceFee > 0
          ? updatedSummary.total
          : updatedSummary.total +
                (productTaxMode == 'inclusive' ? 0 : addService);
      final updatedOrder = previousOrder.copyWith(
        subtotal: updatedSummary.subtotal,
        tax: updatedSummary.tax,
        serviceFee: resolvedServiceFee,
        total: resolvedTotal,
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
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');

      if (isOffline &&
          optimisticItem != null &&
          businessId != null &&
          businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'add_item',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': optimisticItem.id,
            'menu_item_id': menuItemId,
            'qty': qty,
            'check_pos': effectiveCheckPos,
            'takeout': takeout,
            'notes': notes,
            'product_name': productName,
            'product_price': productPrice,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Producto agregado en local. Pendiente de sincronizar.',
        );
        return;
      }

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

  ({double subtotal, double tax, double total}) _estimateOptimisticItemAmounts({
    required double grossAmount,
    required String taxMode,
    required double taxRate,
    required double serviceRate,
    bool includeServiceInInclusivePrice = false,
  }) {
    final normalizedTaxRate = taxRate.clamp(0, 1).toDouble();
    final normalizedServiceRate = serviceRate.clamp(0, 1).toDouble();
    if (taxMode == 'inclusive' && normalizedTaxRate > 0) {
      final divisor =
          1 +
          normalizedTaxRate +
          (includeServiceInInclusivePrice ? normalizedServiceRate : 0);
      final subtotal = grossAmount / divisor;
      final tax =
          grossAmount -
          subtotal -
          (includeServiceInInclusivePrice
              ? (subtotal * normalizedServiceRate)
              : 0);
      return (
        subtotal: double.parse(subtotal.toStringAsFixed(2)),
        tax: double.parse(tax.toStringAsFixed(2)),
        total: double.parse(grossAmount.toStringAsFixed(2)),
      );
    }

    final tax = grossAmount * normalizedTaxRate;
    final total = grossAmount + tax;
    return (
      subtotal: double.parse(grossAmount.toStringAsFixed(2)),
      tax: double.parse(tax.toStringAsFixed(2)),
      total: double.parse(total.toStringAsFixed(2)),
    );
  }

  Future<void> toggleTakeout(bool value) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    final previousTakeout = state.takeout;
    state = state.copyWith(takeout: value, error: null);

    try {
      await ref
          .read(salesRepositoryProvider)
          .markOrderTakeout(orderId: orderId, takeout: value);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'mark_order_takeout',
            'origin': state.origin,
            'order_id': orderId,
            'takeout': value,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          takeout: value,
          error: 'Takeout actualizado en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(
        takeout: previousTakeout,
        error: 'Error al actualizar takeout: $e',
      );
    }
  }

  Future<void> deleteItem(String itemId, {String? reason}) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    // 1. Snapshot for rollback
    final previousItems = state.items;
    final previousOrder = state.order;

    // 2. Optimistic Local Update
    final updatedItems = state.items.where((i) => i.id != itemId).toList();

    final updatedSummary = summarizeOrderPricing(state.order, updatedItems);

    final updatedOrder = state.order?.copyWith(
      total: updatedSummary.total,
      subtotal: updatedSummary.subtotal,
      tax: updatedSummary.tax,
      serviceFee: updatedSummary.serviceFee,
    );

    state = state.copyWith(
      items: updatedItems,
      order: updatedOrder,
      error: null,
    );

    try {
      await ref.read(salesRepositoryProvider).deleteItem(itemId: itemId);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'delete_item',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Producto eliminado en local. Pendiente de sincronizar.',
        );
        return;
      }

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

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateItemQuantity(itemId: itemId, quantity: quantity);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        final updatedItems = state.items
            .map((item) {
              if (item.id != itemId) return item;
              final taxRate = item.subtotal > 0
                  ? (item.tax / item.subtotal)
                  : 0.0;
              final serviceRate = item.isTakeout ? 0.0 : 0.10;
              final optimisticAmounts = _estimateOptimisticItemAmounts(
                grossAmount: item.unitPrice * quantity,
                taxMode: item.taxMode,
                taxRate: taxRate,
                serviceRate: serviceRate,
                includeServiceInInclusivePrice: !item.isTakeout,
              );
              return item.copyWith(
                quantity: quantity,
                subtotal: optimisticAmounts.subtotal,
                tax: optimisticAmounts.tax,
                total: optimisticAmounts.total,
              );
            })
            .toList(growable: false);

        final updatedSummary = summarizeOrderPricing(state.order, updatedItems);

        state = state.copyWith(
          items: updatedItems,
          order: state.order?.copyWith(
            subtotal: updatedSummary.subtotal,
            tax: updatedSummary.tax,
            serviceFee: updatedSummary.serviceFee,
            total: updatedSummary.total,
          ),
        );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'update_item_quantity',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'quantity': quantity,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Cantidad actualizada en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(error: 'Error al actualizar cantidad: $e');
    }
  }

  Future<void> updateItemNotes(String itemId, String notes) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateItemNotes(itemId: itemId, notes: notes);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        state = state.copyWith(
          items: state.items
              .map((item) {
                return item.id == itemId ? item.copyWith(notes: notes) : item;
              })
              .toList(growable: false),
        );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'update_item_notes',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'notes': notes,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Notas actualizadas en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(error: 'Error al actualizar notas: $e');
    }
  }

  Future<void> toggleItemTakeout(String itemId, bool isTakeout) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .toggleItemTakeout(itemId: itemId, isTakeout: isTakeout);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        state = state.copyWith(
          items: state.items
              .map((item) {
                return item.id == itemId
                    ? item.copyWith(isTakeout: isTakeout)
                    : item;
              })
              .toList(growable: false),
        );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'toggle_item_takeout',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'is_takeout': isTakeout,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error:
              'Takeout del item actualizado en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(error: 'Error al cambiar takeout del item: $e');
    }
  }

  Future<void> updateItem(String itemId, OrderItem updatedItem) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateItemDetails(
            itemId: itemId,
            productName: updatedItem.productName,
            quantity: updatedItem.quantity,
            isTakeout: updatedItem.isTakeout,
            discounts: updatedItem.discounts,
            notes: updatedItem.notes?.trim().isEmpty ?? true
                ? null
                : updatedItem.notes?.trim(),
          );
      refreshOrder();
    } catch (e) {
      state = state.copyWith(error: 'Error al actualizar item: $e');
      rethrow;
    }
  }

  Future<void> applyDiscountPercentToItems({
    required List<String> itemIds,
    required double percent,
  }) async {
    final orderId = state.order?.id;
    if (orderId == null || itemIds.isEmpty) return;

    final clampedPercent = percent.clamp(0, 100).toDouble();
    final targetItems = state.items
        .where(
          (i) =>
              itemIds.contains(i.id) &&
              i.status != 'paid' &&
              i.status != 'void',
        )
        .toList(growable: false);
    if (targetItems.isEmpty) return;

    state = state.copyWith(loading: true, error: null);
    try {
      await Future.wait(
        targetItems.map((item) {
          final base = (item.subtotal + item.tax)
              .clamp(0, double.infinity)
              .toDouble();
          final discount = (base * (clampedPercent / 100))
              .clamp(0, base)
              .toDouble();
          final notesWithoutCourtesy = _stripCourtesyFromNotes(item.notes);
          return ref
              .read(salesRepositoryProvider)
              .updateItemDiscountAndNotes(
                itemId: item.id,
                discounts: discount,
                notes: notesWithoutCourtesy.isEmpty
                    ? null
                    : notesWithoutCourtesy,
              );
        }),
      );
      refreshOrder();
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error aplicando descuento: $e',
      );
      rethrow;
    }
  }

  Future<void> applyCourtesyToItems({
    required List<String> itemIds,
    required String reason,
  }) async {
    final orderId = state.order?.id;
    if (orderId == null || itemIds.isEmpty) return;

    final selectedItems = state.items
        .where(
          (i) =>
              itemIds.contains(i.id) &&
              i.status != 'paid' &&
              i.status != 'void',
        )
        .toList(growable: false);
    if (selectedItems.isEmpty) return;

    // Si un producto se marca como cortesía en principal/subcuenta,
    // aplicamos la cortesía a todas sus líneas en la orden.
    final selectedProductKeys = selectedItems
        .map(_courtesyProductKey)
        .whereType<String>()
        .toSet();

    final freshOpenItems = await ref
        .read(salesRepositoryProvider)
        .getOrderItems(
          orderId,
          includeModifiers: true,
          onlyOpen: true,
          businessId: _activeBusinessId,
        );

    final targetItems = freshOpenItems
        .where(
          (item) => selectedProductKeys.contains(_courtesyProductKey(item)),
        )
        .toList(growable: false);
    if (targetItems.isEmpty) return;

    final cleanedReason = reason.trim();
    state = state.copyWith(loading: true, error: null);
    try {
      await Future.wait(
        targetItems.map((item) {
          final base = _courtesyLineAmount(item);
          final notes = _buildCourtesyNotes(
            originalNotes: item.notes,
            reason: cleanedReason,
          );
          return ref
              .read(salesRepositoryProvider)
              .updateItemDiscountAndNotes(
                itemId: item.id,
                discounts: base,
                notes: notes,
              );
        }),
      );
      refreshOrder();
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error aplicando cortesía: $e',
      );
      rethrow;
    }
  }

  Future<void> moveItemToCheck(String itemId, int pos) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .moveItemToCheck(itemId: itemId, checkPosition: pos);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'move_item_to_check',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'check_pos': pos,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error:
              'Movimiento a subcuenta guardado en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(error: 'Error moviendo item a subcuenta: $e');
    }
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
      // Cashier refresh is not critical for the sales flow.
      debugPrint('Note: Could not refresh cashier: $e');
    }

    state = const CurrentOrderState();
  }

  Future<void> cancelCurrentOrder({String? reason}) async {
    final orderId = state.order?.id;
    if (orderId == null) {
      state = const CurrentOrderState();
      return;
    }
    final trimmedReason = reason?.trim();
    if (trimmedReason != null && trimmedReason.isNotEmpty) {
      await appendVoidAuditNote(reason: trimmedReason);
    }
    await ref
        .read(salesRepositoryProvider)
        .closeOrder(orderId: orderId, status: 'void');
    state = const CurrentOrderState();
  }

  // Method to confirm order (send to kitchen)
  Future<void> confirmOrder({String? tableName, String? waiterName}) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    state = state.copyWith(loading: true);
    try {
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        throw Exception(
          'No se pudo resolver el negocio activo para imprimir la comanda.',
        );
      }

      if (!_connectivity.isConnected || orderId.startsWith('local-order-')) {
        await ref
            .read(printingServiceProvider)
            .sendLocalOrderToKitchen(
              businessId: businessId,
              localState: state,
              tableName:
                  tableName ?? (state.origin == 'table' ? 'MESA' : 'LOCAL'),
              waiterName: waiterName ?? session.userName,
              businessName: session.activeBusinessName,
            );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'send_to_kitchen',
            'origin': state.origin,
            'order_id': orderId,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          loading: false,
          error: 'Comanda impresa/localmente. Pendiente de sincronizar.',
        );
        return;
      }

      await ref
          .read(printingServiceProvider)
          .sendOrderToKitchen(
            orderId: orderId,
            businessId: businessId,
            fallbackTableName: tableName,
            fallbackWaiterName: waiterName ?? session.userName,
          );
      refreshOrder();
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      rethrow;
    }
  }

  Future<void> reprintKitchenTicket({
    required String orderId,
    List<OrderItem>? items,
  }) async {
    final businessId = _activeBusinessId;
    if (businessId == null) return;

    try {
      if (items != null && items.isNotEmpty) {
        await ref
            .read(printingServiceProvider)
            .reprintItems(
              orderId: orderId,
              businessId: businessId,
              items: items,
            );
      }
    } catch (e) {
      state = state.copyWith(error: 'Error al reimprimir: $e');
    }
  }

  Future<void> refreshOrder({bool clearIfPaid = false}) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    _scheduleOrderRefresh(orderId, clearIfPaid: clearIfPaid);
  }

  Future<void> syncPendingOfflineActions({bool force = false}) async {
    if (_syncInFlight) return;
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    if (!_connectivity.isConnected) {
      await _refreshOfflineMonitor(
        syncStatus: 'Sin conexión. Sync pausada.',
        syncInFlight: false,
      );
      return;
    }

    _syncInFlight = true;
    await _refreshOfflineMonitor(
      syncStatus: 'Sincronizando operaciones offline...',
      syncInFlight: true,
    );
    try {
      final result = await _offlinePos.syncPendingActions(
        businessId: businessId,
        salesRepository: ref.read(salesRepositoryProvider),
        printingService: ref.read(printingServiceProvider),
        force: force,
      );

      if (result.completed > 0 &&
          state.order != null &&
          state.order!.id.startsWith('local-order-') &&
          result.lastMappedOrderId != null) {
        await _loadOrderDetail(result.lastMappedOrderId!, origin: state.origin);
      } else if (state.order != null &&
          !state.order!.id.startsWith('local-order-')) {
        await _loadOrderDetail(state.order!.id, origin: state.origin);
      }

      final syncMessage = !result.didWork
          ? (result.pending > 0
                ? 'Sync pendiente. Operaciones en espera.'
                : 'Todo sincronizado.')
          : result.hasFailures
          ? 'Sync offline parcial: ${result.completed} ok, ${result.failed} con error.'
          : result.pending > 0
          ? 'Sync offline en progreso. Pendientes: ${result.pending}.'
          : 'Sync offline completada (${result.completed}).';

      state = state.copyWith(
        error: result.hasFailures ? syncMessage : state.error,
      );
      await _refreshOfflineMonitor(
        syncStatus: syncMessage,
        syncInFlight: false,
      );
      if (!result.hasFailures && result.pending == 0) {
        state = state.copyWith(lastSyncAt: DateTime.now());
      }
    } catch (e) {
      state = state.copyWith(error: 'Error sincronizando offline: $e');
      await _refreshOfflineMonitor(
        syncStatus: 'Error sincronizando offline.',
        syncInFlight: false,
      );
    } finally {
      _syncInFlight = false;
      await _refreshOfflineMonitor(syncInFlight: false);
    }
  }

  void _scheduleOrderRefresh(String orderId, {bool clearIfPaid = false}) {
    _queuedRefreshOrderId = orderId;
    _queuedClearIfPaid = _queuedClearIfPaid || clearIfPaid;

    _refreshOrderDebounceTimer?.cancel();
    _refreshOrderDebounceTimer = Timer(_refreshOrderDebounce, () {
      unawaited(_flushQueuedOrderRefresh());
    });
  }

  Future<void> _flushQueuedOrderRefresh() async {
    if (_refreshOrderInFlight) return;
    if (_queuedRefreshOrderId == null) return;
    _refreshOrderInFlight = true;

    try {
      while (_queuedRefreshOrderId != null) {
        final orderId = _queuedRefreshOrderId!;
        final clearIfPaid = _queuedClearIfPaid;

        _queuedRefreshOrderId = null;
        _queuedClearIfPaid = false;

        await _loadOrderDetail(orderId);
        if (clearIfPaid && (state.order?.isPaid ?? false)) {
          state = const CurrentOrderState();
        }
      }
    } finally {
      _refreshOrderInFlight = false;
      if (_queuedRefreshOrderId != null) {
        unawaited(_flushQueuedOrderRefresh());
      }
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
    _refreshOrderDebounceTimer?.cancel();
    await _ensureBusinessTaxSettingsLoaded();
    final repo = ref.read(salesRepositoryProvider);
    Order? order;
    List<OrderItem> items = const [];
    List<OrderCheck> checks = const [];
    String? loadError;
    String? customerId;
    String? customerName;
    String? sessionNote;

    var loadedByBundle = false;
    try {
      final bundle = await repo.getOrderBundle(
        orderId,
        businessId: _activeBusinessId,
      );
      order = bundle.order;
      items = bundle.items;
      checks = bundle.checks;
      customerId = bundle.customerId;
      customerName = bundle.customerName;
      if (order != null) {
        try {
          final session = await repo.getSessionCustomer(
            order.sessionId,
            businessId: _activeBusinessId,
          );
          customerId = session.customerId ?? customerId;
          customerName = session.customerName ?? customerName;
          sessionNote = session.note;
        } catch (_) {}
      }
      loadedByBundle = order != null;
    } catch (e) {
      loadError = e.toString();
    }

    if (!loadedByBundle) {
      final orderFuture = repo.getOrder(orderId, businessId: _activeBusinessId);
      final itemsFuture = repo.getOrderItems(
        orderId,
        includeModifiers: false,
        limit: 500,
        onlyOpen: true,
        businessId: _activeBusinessId,
      );
      final checksFuture = repo.getOrderChecks(
        orderId,
        businessId: _activeBusinessId,
      );
      Future<({String? customerId, String? customerName, String? note})>?
      customerFuture;

      try {
        order = await orderFuture;
        if (order != null) {
          customerFuture = repo.getSessionCustomer(
            order.sessionId,
            businessId: _activeBusinessId,
          );
        }
        checks = await checksFuture;
      } catch (e) {
        loadError ??= e.toString();
      }

      try {
        items = await itemsFuture;
      } catch (e) {
        loadError ??= e.toString();
      }

      if (customerFuture != null) {
        try {
          final customer = await customerFuture;
          customerId = customer.customerId;
          customerName = customer.customerName;
          sessionNote = customer.note;
        } catch (_) {}
      }
    }

    if (order == null && items.isEmpty) {
      // DUMP ERROR EN MODO DEBUG
      print("===== _loadOrderDetail ERROR =====");
      print("orderId: $orderId");
      print("loadedByBundle: $loadedByBundle");
      print("loadError: $loadError");
      print("==================================");

      state = state.copyWith(
        loading: false,
        error:
            loadError ??
            'Orden no encontrada (Probable error RLS o de permisos)',
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

    // Fetch fiscal sequences if not loaded for this business
    List<FiscalNcfSequence> fiscalSequences = state.fiscalSequences;
    if (fiscalSequences.isEmpty && _activeBusinessId != null) {
      try {
        fiscalSequences = await ref
            .read(fiscalServiceProvider)
            .getSequences(_activeBusinessId!);
      } catch (e) {
        debugPrint('Error loading fiscal sequences: $e');
      }
    }

    state = _normalizeHydratedState(
      state.copyWith(
        loading: false,
        order: order ?? state.order,
        items: items,
        checks: checks,
        origin: origin ?? state.origin,
        error: items.isEmpty ? (loadError ?? state.error) : null,
        selectedCheckId: newSelectedCheckId,
        clearSelectedCheck:
            newSelectedCheckId == null && state.selectedCheckId != null,
        customerId: customerId,
        customerName: customerName,
        clearCustomer: customerId == null && customerName == null,
        sessionNote: sessionNote,
        clearSessionNote: sessionNote == null,
        fiscalSequences: fiscalSequences,
      ),
    );

    // Cachear última versión por mesa para apertura optimista
    if (origin == 'table' && tableId != null) {
      _tableCache[tableId] = state;
    }

    await _persistCurrentState(tableId: tableId);
    _subscribeToOrderUpdates(orderId);
  }

  RealtimeChannel? _realtimeChannel;
  String? _subscribedOrderId;

  void _subscribeToOrderUpdates(String orderId) {
    if (_subscribedOrderId == orderId && _realtimeChannel != null) {
      return;
    }

    if (_realtimeChannel != null) {
      _realtimeChannel!.unsubscribe();
    }

    final client = Supabase.instance.client;
    _realtimeChannel = client.channel('order_view_$orderId');
    _subscribedOrderId = orderId;

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

      final checksRaw = (payload['checks'] as List?) ?? const [];
      final hasCheckClosureMetadata = checksRaw.any((c) {
        final m = Map<String, dynamic>.from(c as Map);
        return m.containsKey('is_closed') ||
            m.containsKey('isClosed') ||
            m.containsKey('closed') ||
            m.containsKey('closed_at');
      });

      final checks = hasCheckClosureMetadata
          ? checksRaw.map((c) {
              final m = Map<String, dynamic>.from(c as Map);
              final rawIsClosed =
                  m['is_closed'] ?? m['isClosed'] ?? m['closed'];
              final isClosed = rawIsClosed != null
                  ? _parseBool(rawIsClosed)
                  : m['closed_at'] != null;
              return OrderCheck(
                id: m['id'] ?? '',
                orderId: order.id,
                label: m['label'] ?? 'C1',
                position: (m['position'] ?? 1) as int,
                isClosed: isClosed,
                subtotal: (m['subtotal'] ?? 0).toDouble(),
                discounts: (m['discounts'] ?? 0).toDouble(),
                serviceFee: (m['service_fee'] ?? 0).toDouble(),
                tax: (m['tax'] ?? 0).toDouble(),
                total: (m['total'] ?? 0).toDouble(),
                items: const [],
              );
            }).toList()
          : const <OrderCheck>[];

      final items = ((payload['items'] as List?) ?? []).map((i) {
        final m = Map<String, dynamic>.from(i as Map);
        return OrderItem.fromMap(m);
      }).toList();

      String? nextSelectedCheckId = state.selectedCheckId;
      if (nextSelectedCheckId != null) {
        final exists = checks.any(
          (c) => c.id == nextSelectedCheckId && !c.isClosed,
        );
        if (!exists) {
          nextSelectedCheckId = null;
        }
      }

      final newState = _normalizeHydratedState(
        state.copyWith(
          loading: false,
          origin: 'table',
          order: order,
          items: items,
          checks: checks,
          error: null,
          selectedCheckId: nextSelectedCheckId,
          clearSelectedCheck:
              nextSelectedCheckId == null && state.selectedCheckId != null,
        ),
      );

      state = newState;
      _tableCache[tableId] = newState;
    } catch (e) {
      // Si el payload viene incompleto, ignoramos y dejamos al load completo
    }
  }

  bool _parseBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == 'true' ||
          normalized == 't' ||
          normalized == '1' ||
          normalized == 'yes' ||
          normalized == 'y';
    }
    return false;
  }

  String? _courtesyProductKey(OrderItem item) {
    final productId = item.productId?.trim();
    if (productId != null && productId.isNotEmpty) return 'id:$productId';

    final name = item.productName.trim().toLowerCase();
    if (name.isEmpty) return null;
    final sku = (item.sku ?? '').trim().toLowerCase();
    final price = item.unitPrice.toStringAsFixed(2);
    return 'name:$name|sku:$sku|price:$price';
  }

  double _courtesyLineAmount(OrderItem item) {
    final modifiersTotal = item.modifiers.fold<double>(
      0,
      (sum, modifier) => sum + (modifier.price * modifier.qty),
    );
    final estimatedSubtotal = (item.unitPrice * item.quantity) + modifiersTotal;

    final taxRate = item.subtotal > 0
        ? (item.tax / item.subtotal)
        : (item.tax > 0 ? 0.18 : 0.0);
    final estimatedTax = estimatedSubtotal * taxRate;

    final total = (estimatedSubtotal + estimatedTax)
        .clamp(0, double.infinity)
        .toDouble();
    return double.parse(total.toStringAsFixed(2));
  }

  String _stripCourtesyFromNotes(String? rawNotes) {
    if (rawNotes == null || rawNotes.trim().isEmpty) return '';

    final lines = rawNotes
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where(
          (line) => !(line.startsWith(_courtesyPrefix) && line.endsWith(']')),
        )
        .toList(growable: false);

    return lines.join('\n');
  }

  String? _buildCourtesyNotes({
    required String? originalNotes,
    required String reason,
  }) {
    final baseNotes = _stripCourtesyFromNotes(originalNotes);
    final parts = <String>[];
    if (baseNotes.isNotEmpty) {
      parts.add(baseNotes);
    }
    if (reason.isNotEmpty) {
      parts.add('$_courtesyPrefix$reason]');
    }
    if (parts.isEmpty) return null;
    return parts.join('\n');
  }
}
