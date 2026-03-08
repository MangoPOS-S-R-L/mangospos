import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/inventory_state.dart';

final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) {
  return InventoryRepository(Supabase.instance.client);
});

final inventoryViewModelProvider = ChangeNotifierProvider<InventoryViewModel>((
  ref,
) {
  return InventoryViewModel(ref.read(inventoryRepositoryProvider));
});

class InventoryViewModel extends ChangeNotifier {
  final InventoryRepository _repository;

  InventoryState _state = const InventoryState();

  InventoryViewModel(this._repository);

  InventoryState get state => _state;

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

      final warehouses = await _repository.getWarehouses(businessId);
      final selectedWarehouseId =
          _state.selectedWarehouseId ??
          (warehouses.isNotEmpty ? warehouses.first.id : null);

      _state = _state.copyWith(
        businessId: businessId,
        warehouses: warehouses,
        selectedWarehouseId: selectedWarehouseId,
      );

      await _reloadLists();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error cargando inventario: $e',
      );
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    _state = _state.copyWith(loading: true, clearError: true);
    notifyListeners();
    try {
      await _reloadLists();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error refrescando inventario: $e',
      );
      notifyListeners();
    }
  }

  Future<void> search(String query) async {
    _state = _state.copyWith(
      searchQuery: query.trim(),
      loading: true,
      clearError: true,
    );
    notifyListeners();

    try {
      await _reloadLists();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error buscando insumos: $e',
      );
      notifyListeners();
    }
  }

  Future<void> selectWarehouse(String? warehouseId) async {
    _state = _state.copyWith(
      selectedWarehouseId: warehouseId,
      loading: true,
      clearError: true,
    );
    notifyListeners();

    try {
      await _reloadLists();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error cargando almacen: $e',
      );
      notifyListeners();
    }
  }

  Future<void> createItem({
    required String name,
    String? sku,
    String? description,
    required String unit,
    required double cost,
    required double minStock,
    double? maxStock,
    double initialStock = 0,
  }) async {
    final businessId = _state.businessId;
    final warehouseId = _state.selectedWarehouseId;
    if (businessId == null || warehouseId == null) {
      throw Exception('No hay negocio o almacen seleccionado');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      final created = await _repository.createItem(
        businessId: businessId,
        name: name,
        sku: sku,
        description: description,
        unit: unit,
        cost: cost,
        minStock: minStock,
        maxStock: maxStock,
      );

      final itemId = created['id']?.toString();
      if (itemId != null && itemId.isNotEmpty && initialStock > 0) {
        await _repository.recordMovement(
          businessId: businessId,
          warehouseId: warehouseId,
          itemId: itemId,
          movementType: 'purchase',
          quantity: initialStock,
          costPerUnit: cost,
          notes: 'Stock inicial',
          referenceType: 'inventory_setup',
        );
      }

      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error creando insumo: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateItem({
    required String itemId,
    required String name,
    String? sku,
    String? description,
    required String unit,
    required double cost,
    required double minStock,
    double? maxStock,
    required bool isActive,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.updateItem(
        itemId: itemId,
        name: name,
        sku: sku,
        description: description,
        unit: unit,
        cost: cost,
        minStock: minStock,
        maxStock: maxStock,
        isActive: isActive,
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error actualizando insumo: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> registerOutflow({
    required String itemId,
    required double quantity,
    String? notes,
  }) async {
    final businessId = _state.businessId;
    final warehouseId = _state.selectedWarehouseId;
    if (businessId == null || warehouseId == null) {
      throw Exception('No hay negocio o almacen seleccionado');
    }

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.recordMovement(
        businessId: businessId,
        warehouseId: warehouseId,
        itemId: itemId,
        movementType: 'waste',
        quantity: quantity,
        notes: notes,
        referenceType: 'manual_outflow',
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error registrando salida: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> reconcileStock({
    required String itemId,
    required double countedStock,
    String? notes,
  }) async {
    final businessId = _state.businessId;
    final warehouseId = _state.selectedWarehouseId;
    if (businessId == null || warehouseId == null) {
      throw Exception('No hay negocio o almacen seleccionado');
    }

    InventoryItemSummary? item;
    for (final current in _state.items) {
      if (current.id == itemId) {
        item = current;
        break;
      }
    }
    if (item == null) {
      throw Exception('No se encontro el insumo para ajustar stock');
    }

    final delta = countedStock - item.stock;
    if (delta == 0) return;

    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();

    try {
      await _repository.recordMovement(
        businessId: businessId,
        warehouseId: warehouseId,
        itemId: itemId,
        movementType: 'adjustment',
        quantity: delta,
        costPerUnit: item.cost,
        notes: notes,
        referenceType: 'stock_reconciliation',
      );
      _state = _state.copyWith(saving: false);
      await refresh();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error conciliando stock: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _reloadLists() async {
    final businessId = _state.businessId;
    final warehouseId = _state.selectedWarehouseId;

    if (businessId == null || warehouseId == null) {
      _state = _state.copyWith(
        loading: false,
        items: const [],
        movements: const [],
      );
      notifyListeners();
      return;
    }

    final items = await _repository.getItems(
      businessId: businessId,
      warehouseId: warehouseId,
      query: _state.searchQuery,
    );
    final movements = await _repository.getMovements(
      businessId: businessId,
      warehouseId: warehouseId,
    );

    _state = _state.copyWith(
      loading: false,
      items: items,
      movements: movements,
      clearError: true,
    );
    notifyListeners();
  }
}
