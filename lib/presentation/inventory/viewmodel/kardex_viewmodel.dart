// Sprint 3 Inventario — ViewModel del Kardex.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/inventory_warehouse_scope.dart';
import '../state/kardex_state.dart';
import 'inventory_viewmodel.dart';

final kardexViewModelProvider = ChangeNotifierProvider<KardexViewModel>((ref) {
  return KardexViewModel(ref.read(inventoryRepositoryProvider), ref);
});

class KardexViewModel extends ChangeNotifier {
  final InventoryRepository _repository;

  /// Para heredar el contexto de bodega del módulo.
  final Ref _ref;

  KardexState _state = const KardexState();

  KardexViewModel(this._repository, this._ref);

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

      // El contexto de bodega del módulo viaja hasta acá: entrar al kardex
      // EN FRÍO (desde el hub, sin filtros) lo abre en la bodega elegida en
      // Insumos. Si se entró desde una celda o una card de distribución, los
      // filtros ya traen insumo —y a veces bodega— y se respetan tal cual:
      // por eso el guard es `isEmpty` y no `warehouseId == null`.
      if (_state.filters.isEmpty) {
        final warehouses = _ref
            .read(inventoryViewModelProvider)
            .state
            .warehouses;
        final scoped = _ref
            .read(inventoryWarehouseScopeProvider.notifier)
            .effectiveId(warehouses.map((w) => w.id), null);
        if (scoped != null) {
          _state = _state.copyWith(
            filters: KardexFilters(warehouseId: scoped),
          );
        }
      }

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

  /// Trae TODOS los movimientos que matchean los filtros actuales, paginando
  /// server-side hasta [maxRows]. Para exportación (PDF/Excel): la lista en
  /// pantalla solo tiene las páginas ya scrolleadas y exportar eso a medias
  /// confunde. No toca el state de la vista.
  ///
  /// `truncated` = true si había más filas que [maxRows]; el caller debe
  /// avisarlo en el documento para que nadie asuma que el reporte es completo.
  Future<({List<KardexMovement> movements, bool truncated})>
      fetchAllForExport({int maxRows = 3000}) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      return (movements: const <KardexMovement>[], truncated: false);
    }
    final all = <KardexMovement>[];
    var offset = 0;
    while (all.length < maxRows) {
      final rows = await _repository.getKardexMovements(
        businessId: businessId,
        itemId: _state.filters.itemId,
        warehouseId: _state.filters.warehouseId,
        movementType: _state.filters.movementType,
        createdBy: _state.filters.createdBy,
        from: _state.filters.from,
        to: _state.filters.to,
        limit: KardexState.pageSize,
        offset: offset,
      );
      final page = rows.map(KardexMovement.fromMap).toList(growable: false);
      all.addAll(page);
      if (page.length < KardexState.pageSize) {
        return (movements: all, truncated: false);
      }
      offset += page.length;
    }
    return (
      movements: all.take(maxRows).toList(growable: false),
      truncated: true,
    );
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
