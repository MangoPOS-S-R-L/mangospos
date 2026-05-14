// Sprint 4 Inventario — ViewModel de alertas de stock bajo.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/low_stock_state.dart';
import 'inventory_viewmodel.dart';

final lowStockViewModelProvider =
    ChangeNotifierProvider<LowStockViewModel>((ref) {
      return LowStockViewModel(ref.read(inventoryRepositoryProvider));
    });

class LowStockViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  LowStockState _state = const LowStockState();

  LowStockViewModel(this._repository);

  LowStockState get state => _state;

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
        error: 'Error cargando alertas: $e',
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

  Future<void> applyLevelFilter(String? level) async {
    _state = _state.copyWith(
      alertLevelFilter: level,
      clearFilter: level == null,
      loading: true,
      clearError: true,
    );
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error filtrando alertas: $e',
      );
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      _state = _state.copyWith(loading: false, alerts: const []);
      notifyListeners();
      return;
    }
    final rows = await _repository.getLowStockAlerts(
      businessId: businessId,
      alertLevel: _state.alertLevelFilter,
    );
    _state = _state.copyWith(
      loading: false,
      alerts: rows.map(LowStockAlert.fromMap).toList(growable: false),
      clearError: true,
    );
    notifyListeners();
  }

  /// Carga el desglose por bodega para un insumo específico.
  Future<List<StockByWarehouse>> loadWarehousesForItem(String itemId) async {
    final businessId = _state.businessId;
    if (businessId == null) return const [];
    final rows = await _repository.getStockByWarehouseForItem(
      businessId: businessId,
      itemId: itemId,
    );
    return rows.map(StockByWarehouse.fromMap).toList(growable: false);
  }
}
