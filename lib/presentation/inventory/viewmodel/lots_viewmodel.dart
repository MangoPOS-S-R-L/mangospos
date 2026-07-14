// Sprint 4 Inventario — ViewModel de lotes y vencimientos (fase 1).

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/lots_state.dart';
import 'inventory_viewmodel.dart';

final lotsViewModelProvider = ChangeNotifierProvider<LotsViewModel>((ref) {
  return LotsViewModel(ref.read(inventoryRepositoryProvider));
});

class LotsViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  LotsState _state = const LotsState();

  LotsViewModel(this._repository);

  LotsState get state => _state;

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
        error: 'Error cargando lotes: $e',
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
      _state = _state.copyWith(loading: false, error: 'Error refrescando: $e');
      notifyListeners();
    }
  }

  Future<void> applyFilters(LotsFilters filters) async {
    _state = _state.copyWith(
      filters: filters,
      loading: true,
      clearError: true,
    );
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error filtrando lotes: $e',
      );
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      _state = _state.copyWith(loading: false, lots: const [], hasMore: false);
      notifyListeners();
      return;
    }
    final rows = await _repository.listLots(
      businessId: businessId,
      expiryStatus: _state.filters.expiryStatus,
      itemId: _state.filters.itemId,
      warehouseId: _state.filters.warehouseId,
      limit: LotsState.pageSize,
      offset: 0,
    );
    final lots = rows.map(InventoryLot.fromMap).toList(growable: false);
    _state = _state.copyWith(
      loading: false,
      lots: lots,
      hasMore: lots.length == LotsState.pageSize,
      clearError: true,
    );
    notifyListeners();
  }

  Future<void> loadMore() async {
    final businessId = _state.businessId;
    if (businessId == null) return;
    if (_state.loadingMore || _state.loading) return;
    if (!_state.hasMore) return;
    _state = _state.copyWith(loadingMore: true, clearError: true);
    notifyListeners();
    try {
      final rows = await _repository.listLots(
        businessId: businessId,
        expiryStatus: _state.filters.expiryStatus,
        itemId: _state.filters.itemId,
        warehouseId: _state.filters.warehouseId,
        limit: LotsState.pageSize,
        offset: _state.lots.length,
      );
      final more = rows.map(InventoryLot.fromMap).toList(growable: false);
      _state = _state.copyWith(
        loadingMore: false,
        lots: [..._state.lots, ...more],
        hasMore: more.length == LotsState.pageSize,
      );
      notifyListeners();
    } catch (e) {
      _state = _state.copyWith(
        loadingMore: false,
        error: 'Error cargando más lotes: $e',
      );
      notifyListeners();
    }
  }

  Future<void> disposeLot({required String lotId, String? reason}) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      await _repository.disposeLot(lotId: lotId, reason: reason);
      _state = _state.copyWith(saving: false);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error disponiendo lote: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> registerLotManually({
    required String itemId,
    required String warehouseId,
    required double quantity,
    String? lotNumber,
    DateTime? expiryDate,
    double? costPerUnit,
    String? notes,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio activo');
    }
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      await _repository.registerLot(
        businessId: businessId,
        itemId: itemId,
        warehouseId: warehouseId,
        quantity: quantity,
        lotNumber: lotNumber,
        expiryDate: expiryDate,
        costPerUnit: costPerUnit,
        notes: notes,
      );
      _state = _state.copyWith(saving: false);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error registrando lote: $e',
      );
      notifyListeners();
      rethrow;
    }
  }
}
