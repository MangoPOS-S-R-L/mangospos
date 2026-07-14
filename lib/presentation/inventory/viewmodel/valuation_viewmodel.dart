// Sprint 5 Inventario (Fase A) — ViewModel de valoración.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/valuation_state.dart';
import 'inventory_viewmodel.dart';

final valuationViewModelProvider =
    ChangeNotifierProvider<ValuationViewModel>((ref) {
      return ValuationViewModel(ref.read(inventoryRepositoryProvider));
    });

class ValuationViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  ValuationState _state = const ValuationState();

  ValuationViewModel(this._repository);

  ValuationState get state => _state;

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
        error: 'Error cargando valoración: $e',
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

  Future<void> setViewMode(ValuationViewMode mode) async {
    if (mode == _state.viewMode) return;
    _state = _state.copyWith(
      viewMode: mode,
      loading: true,
      clearError: true,
    );
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(loading: false, error: 'Error: $e');
      notifyListeners();
    }
  }

  Future<void> applyFilters(ValuationFilters filters) async {
    _state = _state.copyWith(
      filters: filters,
      loading: true,
      clearError: true,
    );
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(loading: false, error: 'Error: $e');
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      _state = _state.copyWith(
        loading: false,
        summary: const [],
        details: const [],
      );
      notifyListeners();
      return;
    }
    if (_state.viewMode == ValuationViewMode.byItem) {
      final rows = await _repository.getInventoryValuationSummary(
        businessId: businessId,
        abcClass: _state.filters.abcClass,
      );
      _state = _state.copyWith(
        loading: false,
        summary: rows.map(ValuationSummaryRow.fromMap).toList(growable: false),
        details: const [],
        clearError: true,
      );
    } else {
      final rows = await _repository.getInventoryValuation(
        businessId: businessId,
        warehouseId: _state.filters.warehouseId,
      );
      _state = _state.copyWith(
        loading: false,
        details: rows.map(ValuationRow.fromMap).toList(growable: false),
        summary: const [],
        clearError: true,
      );
    }
    notifyListeners();
  }
}
