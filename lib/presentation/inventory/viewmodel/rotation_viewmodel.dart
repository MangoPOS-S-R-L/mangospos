// Sprint 5 Inventario (Fase B) — ViewModel de análisis de rotación.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/rotation_state.dart';
import 'inventory_viewmodel.dart';

final rotationViewModelProvider = ChangeNotifierProvider<RotationViewModel>((
  ref,
) {
  return RotationViewModel(ref.read(inventoryRepositoryProvider));
});

class RotationViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  RotationState _state = const RotationState();

  RotationViewModel(this._repository);

  RotationState get state => _state;

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
        error: 'Error cargando rotación: $e',
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

  Future<void> setDaysBack(int days) async {
    if (days == _state.daysBack) return;
    _state = _state.copyWith(daysBack: days, loading: true, clearError: true);
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(loading: false, error: 'Error: $e');
      notifyListeners();
    }
  }

  void setClassFilter(RotationClass? cls) {
    _state = _state.copyWith(
      classFilter: cls,
      clearClassFilter: cls == null,
    );
    notifyListeners();
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      _state = _state.copyWith(loading: false, rows: const []);
      notifyListeners();
      return;
    }
    final raw = await _repository.getInventoryRotation(
      businessId: businessId,
      daysBack: _state.daysBack,
    );
    _state = _state.copyWith(
      loading: false,
      rows: raw.map(RotationRow.fromMap).toList(growable: false),
      clearError: true,
    );
    notifyListeners();
  }
}
