// Rendimiento por insumo: compra vs producción/ventas vs merma.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/friendly_error.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/yield_state.dart';
import 'inventory_viewmodel.dart';

final yieldViewModelProvider = ChangeNotifierProvider<YieldViewModel>((ref) {
  return YieldViewModel(ref.read(inventoryRepositoryProvider));
});

class YieldViewModel extends ChangeNotifier {
  YieldViewModel(
    this._repository, {
    Future<String?> Function()? resolveBusiness,
  }) : _resolveBusiness = resolveBusiness;

  final InventoryRepository _repository;
  final Future<String?> Function()? _resolveBusiness;
  YieldState _state = const YieldState();

  /// Generación de la carga: cambiar de período o bodega rápido no deja que
  /// una respuesta vieja pise la nueva.
  int _generation = 0;

  YieldState get state => _state;

  void _set(YieldState next) {
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
      var warehouses = const <YieldWarehouseOption>[];
      try {
        warehouses = (await _repository.getWarehouses(businessId))
            .where((w) => w.name != '__IN_TRANSIT__')
            .map((w) => YieldWarehouseOption(w.id, w.name))
            .toList(growable: false);
      } catch (_) {
        // Sin la lista, el reporte igual sale para todas las bodegas.
      }
      _state = _state.copyWith(businessId: businessId, warehouses: warehouses);
      await _reload();
    } catch (e) {
      _set(
        _state.copyWith(
          loading: false,
          error: FriendlyError.humanize('No se pudo cargar el rendimiento: $e'),
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

  void setReason(String? reason) {
    _set(
      reason == null || reason == _state.reasonFilter
          ? _state.copyWith(clearReason: true)
          : _state.copyWith(reasonFilter: reason),
    );
  }

  void setSearch(String query) => _set(_state.copyWith(search: query));

  void setSort(YieldSort sort) => _set(_state.copyWith(sort: sort));

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) return;
    final generation = ++_generation;
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final raw = await _repository.getYieldAnalysis(
        businessId: businessId,
        daysBack: _state.daysBack,
        warehouseId: _state.warehouseId,
      );
      if (generation != _generation) return;
      _set(
        _state.copyWith(
          loading: false,
          missingFunction: false,
          report: YieldReport.fromMap(raw),
        ),
      );
    } catch (e) {
      if (generation != _generation) return;
      final missing =
          e is PostgrestException &&
          (e.code == 'PGRST202' || e.code == '42883');
      _set(
        _state.copyWith(
          loading: false,
          missingFunction: missing,
          error: missing
              ? null
              : FriendlyError.humanize('No se pudo cargar el rendimiento: $e'),
        ),
      );
    }
  }
}
