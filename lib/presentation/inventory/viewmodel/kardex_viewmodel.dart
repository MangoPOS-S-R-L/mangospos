// Sprint 3 Inventario — ViewModel del Kardex.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/kardex_state.dart';
import 'inventory_viewmodel.dart';

final kardexViewModelProvider = ChangeNotifierProvider<KardexViewModel>((ref) {
  return KardexViewModel(ref.read(inventoryRepositoryProvider));
});

class KardexViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  KardexState _state = const KardexState();

  KardexViewModel(this._repository);

  KardexState get state => _state;

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
        error: 'Error cargando kardex: $e',
      );
      notifyListeners();
    }
  }

  Future<void> applyFilters(KardexFilters filters) async {
    _state = _state.copyWith(filters: filters, loading: true, clearError: true);
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error filtrando kardex: $e',
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
        error: 'Error refrescando: $e',
      );
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      _state = _state.copyWith(
        loading: false,
        movements: const [],
        hasMore: false,
      );
      notifyListeners();
      return;
    }
    final rows = await _repository.getKardexMovements(
      businessId: businessId,
      itemId: _state.filters.itemId,
      warehouseId: _state.filters.warehouseId,
      movementType: _state.filters.movementType,
      createdBy: _state.filters.createdBy,
      from: _state.filters.from,
      to: _state.filters.to,
      limit: KardexState.pageSize,
      offset: 0,
    );
    final movements = rows.map(KardexMovement.fromMap).toList(growable: false);
    _state = _state.copyWith(
      loading: false,
      movements: movements,
      hasMore: movements.length == KardexState.pageSize,
      clearError: true,
    );
    notifyListeners();
  }

  /// Carga la siguiente página y la concatena.
  Future<void> loadMore() async {
    final businessId = _state.businessId;
    if (businessId == null) return;
    if (_state.loadingMore || _state.loading) return;
    if (!_state.hasMore) return;
    _state = _state.copyWith(loadingMore: true, clearError: true);
    notifyListeners();
    try {
      final rows = await _repository.getKardexMovements(
        businessId: businessId,
        itemId: _state.filters.itemId,
        warehouseId: _state.filters.warehouseId,
        movementType: _state.filters.movementType,
        createdBy: _state.filters.createdBy,
        from: _state.filters.from,
        to: _state.filters.to,
        limit: KardexState.pageSize,
        offset: _state.movements.length,
      );
      final more = rows.map(KardexMovement.fromMap).toList(growable: false);
      _state = _state.copyWith(
        loadingMore: false,
        movements: [..._state.movements, ...more],
        hasMore: more.length == KardexState.pageSize,
      );
      notifyListeners();
    } catch (e) {
      _state = _state.copyWith(
        loadingMore: false,
        error: 'Error cargando más movimientos: $e',
      );
      notifyListeners();
    }
  }
}
