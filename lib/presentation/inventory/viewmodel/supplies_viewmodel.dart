// Gastables y menaje: panel del período y clasificación en lote.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/friendly_error.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/supplies_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/supplies_state.dart';
import 'inventory_viewmodel.dart';

final suppliesRepositoryProvider = Provider<SuppliesRepository>((ref) {
  return SuppliesRepository(Supabase.instance.client);
});

final suppliesViewModelProvider = ChangeNotifierProvider<SuppliesViewModel>((
  ref,
) {
  return SuppliesViewModel(
    ref.read(suppliesRepositoryProvider),
    ref.read(inventoryRepositoryProvider),
  );
});

class SuppliesViewModel extends ChangeNotifier {
  SuppliesViewModel(
    this._repository,
    this._inventory, {
    Future<String?> Function()? resolveBusiness,
  }) : _resolveBusiness = resolveBusiness;

  final SuppliesRepository _repository;
  final InventoryRepository _inventory;
  final Future<String?> Function()? _resolveBusiness;
  SuppliesState _state = const SuppliesState();

  /// Generación de la carga: cambiar de período o bodega rápido no deja que
  /// una respuesta vieja pise la nueva.
  int _generation = 0;

  SuppliesState get state => _state;

  void _set(SuppliesState next) {
    _state = next;
    notifyListeners();
  }

  Future<void> init() async {
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final businessId =
          await (_resolveBusiness?.call() ??
              resolveBusinessIdOrNull(Supabase.instance.client, 'auto'));
      if (businessId == null) {
        throw Exception('No se pudo resolver el negocio actual');
      }
      var warehouses = const <SuppliesWarehouseOption>[];
      try {
        warehouses = (await _inventory.getWarehouses(businessId))
            .where((w) => w.name != '__IN_TRANSIT__')
            .map((w) => SuppliesWarehouseOption(w.id, w.name))
            .toList(growable: false);
      } catch (_) {
        // Sin la lista, el panel igual sale para todas las bodegas.
      }
      _state = _state.copyWith(businessId: businessId, warehouses: warehouses);
      await _reload();
    } catch (e) {
      _set(
        _state.copyWith(
          loading: false,
          error: FriendlyError.humanize(
            'No se pudieron cargar los gastables: $e',
          ),
        ),
      );
    }
  }

  Future<void> refresh() => _reload();

  Future<void> setDaysBack(int days) async {
    if (days == _state.daysBack) return;
    _state = _state.copyWith(daysBack: days);
    await _reload();
  }

  Future<void> setWarehouse(String? warehouseId) async {
    _state = warehouseId == null
        ? _state.copyWith(clearWarehouse: true)
        : _state.copyWith(warehouseId: warehouseId);
    await _reload();
  }

  void setTab(SuppliesTab tab) => _set(_state.copyWith(tab: tab));

  void setSearch(String query) => _set(_state.copyWith(search: query));

  void toggleAttention() =>
      _set(_state.copyWith(onlyAttention: !_state.onlyAttention));

  /// Insumos para el diálogo de clasificar.
  Future<List<ClassifiableItem>> loadClassifiableItems() async {
    final businessId = _state.businessId;
    if (businessId == null) return const [];
    return _repository.getClassifiableItems(businessId);
  }

  /// Marca [itemIds] con [classification] y recarga el panel.
  Future<int> classify(List<String> itemIds, String classification) async {
    final businessId = _state.businessId;
    if (businessId == null || itemIds.isEmpty) return 0;
    final changed = await _repository.setClassification(
      businessId: businessId,
      itemIds: itemIds,
      classification: classification,
    );
    await _reload();
    return changed;
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) return;
    final generation = ++_generation;
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final raw = await _repository.getOverview(
        businessId: businessId,
        daysBack: _state.daysBack,
        warehouseId: _state.warehouseId,
      );
      if (generation != _generation) return;
      _set(
        _state.copyWith(
          loading: false,
          missingFunction: false,
          report: SuppliesReport.fromMap(raw),
        ),
      );
    } catch (e) {
      if (generation != _generation) return;
      final missing = SuppliesRepository.isMissingFunction(e);
      _set(
        _state.copyWith(
          loading: false,
          missingFunction: missing,
          error: missing
              ? null
              : FriendlyError.humanize(
                  'No se pudieron cargar los gastables: $e',
                ),
        ),
      );
    }
  }
}
