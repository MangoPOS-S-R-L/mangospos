import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/consolidated_inventory_state.dart';
import 'inventory_viewmodel.dart';

final consolidatedInventoryViewModelProvider =
    ChangeNotifierProvider<ConsolidatedInventoryViewModel>((ref) {
      return ConsolidatedInventoryViewModel(
        ref.read(inventoryRepositoryProvider),
      );
    });

/// ViewModel del panel "Inventario multisucursal": stock consolidado de todas
/// las sucursales del mismo dueño (almacén principal / totales).
class ConsolidatedInventoryViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  ConsolidatedInventoryState _state = const ConsolidatedInventoryState();

  ConsolidatedInventoryViewModel(this._repository);

  ConsolidatedInventoryState get state => _state;

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
      final data = await _repository.getConsolidatedInventory(
        businessId: businessId,
      );

      final branches = (data['branches'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => ConsolidatedBranch.fromMap(Map<String, dynamic>.from(e)))
          .toList(growable: false);
      final products = (data['products'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => ConsolidatedProduct.fromMap(Map<String, dynamic>.from(e)))
          .toList(growable: false);

      _state = _state.copyWith(
        loading: false,
        businessId: businessId,
        branches: branches,
        products: products,
      );
      notifyListeners();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error cargando inventario multisucursal: $e',
      );
      notifyListeners();
    }
  }

  Future<void> refresh() => init(force: true);
}
