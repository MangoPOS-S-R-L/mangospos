import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/purchases_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/purchases_state.dart';

final purchasesRepositoryProvider = Provider<PurchasesRepository>((ref) {
  return PurchasesRepository(Supabase.instance.client);
});

final purchasesViewModelProvider = ChangeNotifierProvider<PurchasesViewModel>((
  ref,
) {
  return PurchasesViewModel(ref.read(purchasesRepositoryProvider));
});

class PurchasesViewModel extends ChangeNotifier {
  final PurchasesRepository _repository;

  PurchasesState _state = const PurchasesState();

  PurchasesViewModel(this._repository);

  PurchasesState get state => _state;

  Future<void> init({bool force = false}) async {
    if (_state.loading && !force) return;

    _state = _state.copyWith(loading: true, clearError: true);
    notifyListeners();

    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );
      if (businessId == null) {
        throw Exception('No se pudo resolver el negocio actual');
      }

      _state = _state.copyWith(businessId: businessId);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error cargando compras: $e',
      );
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    _state = _state.copyWith(loading: true, clearError: true);
    notifyListeners();

    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error refrescando compras: $e',
      );
      notifyListeners();
    }
  }

  Future<void> selectStatus(String? status) async {
    _state = _state.copyWith(
      selectedStatus: status == 'all' ? null : status,
      loading: true,
      clearError: true,
    );
    notifyListeners();

    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error filtrando compras: $e',
      );
      notifyListeners();
    }
  }

  Future<String> generateNextOrderNumber() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    return _repository.generateNextOrderNumber(businessId);
  }

  Future<void> createSupplier({
    required String name,
    String? contactName,
    String? phone,
    String? email,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.createSupplier(
        businessId: businessId,
        name: name,
        contactName: contactName,
        phone: phone,
        email: email,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error creando proveedor: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> createPurchaseOrder({
    required String supplierId,
    required String warehouseId,
    required String orderNumber,
    required String status,
    required DateTime expectedDate,
    String? notes,
    required List<PurchaseDraftItem> items,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.createPurchaseOrder(
        businessId: businessId,
        supplierId: supplierId,
        warehouseId: warehouseId,
        orderNumber: orderNumber,
        status: status,
        expectedDate: expectedDate,
        notes: notes,
        items: items,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error registrando compra: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> receiveOrder(String orderId, {String? notes}) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.receivePurchaseOrder(orderId, notes: notes);
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error recibiendo compra: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  /// Sprint 3 — Recepción parcial.
  /// Devuelve las líneas de la OC para mostrar el dialog (con qty pedida vs
  /// recibida). No persiste estado: el dialog lo maneja localmente.
  Future<List<PurchaseOrderLine>> loadOrderLines(String orderId) {
    return _repository.getOrderLines(orderId);
  }

  /// Sprint 3 — Recepción parcial.
  /// [lineItems] es una lista de mapas `[{poi_id, quantity}]`. Tras la
  /// recepción la OC puede quedar en status 'partial' (si todavía hay líneas
  /// pendientes) o 'received' (si todas se completaron).
  Future<Map<String, dynamic>> receiveOrderPartial({
    required String orderId,
    required List<Map<String, dynamic>> lineItems,
    String? notes,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      final result = await _repository.receivePurchaseOrderPartial(
        orderId: orderId,
        lineItems: lineItems,
        notes: notes,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
      return result;
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error en recepción parcial: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo.');
    }

    final suppliers = await _repository.getSuppliers(businessId);
    final warehouses = await _repository.getWarehouses(businessId);
    final inventoryItems = await _repository.getInventoryItems(businessId);
    final orders = await _repository.getOrders(
      businessId: businessId,
      status: _state.selectedStatus,
      limit: PurchasesState.ordersPageSize,
      offset: 0,
    );
    final totals = await _repository.getOrderTotalsByStatus(businessId);

    _state = _state.copyWith(
      loading: false,
      suppliers: suppliers,
      warehouses: warehouses,
      inventoryItems: inventoryItems,
      orders: orders,
      ordersHasMore: orders.length == PurchasesState.ordersPageSize,
      totalsByStatus: totals,
      clearError: true,
    );
    notifyListeners();
  }

  /// Carga la siguiente página de órdenes y la concatena a la lista actual.
  /// No hace nada si ya está cargando, no hay más resultados o no hay negocio.
  Future<void> loadMoreOrders() async {
    final businessId = _state.businessId;
    if (businessId == null) return;
    if (_state.ordersLoadingMore || _state.loading) return;
    if (!_state.ordersHasMore) return;
    _state = _state.copyWith(ordersLoadingMore: true, clearError: true);
    notifyListeners();
    try {
      final page = await _repository.getOrders(
        businessId: businessId,
        status: _state.selectedStatus,
        limit: PurchasesState.ordersPageSize,
        offset: _state.orders.length,
      );
      _state = _state.copyWith(
        ordersLoadingMore: false,
        orders: [..._state.orders, ...page],
        ordersHasMore: page.length == PurchasesState.ordersPageSize,
      );
      notifyListeners();
    } catch (e) {
      _state = _state.copyWith(
        ordersLoadingMore: false,
        error: 'Error cargando más órdenes: $e',
      );
      notifyListeners();
    }
  }
}
