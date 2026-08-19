import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/storage/storage_service.dart';

/// Contexto de bodega del módulo Inventario.
///
/// Una sola bodega "activa" para TODO el módulo: los ajustes, las salidas y
/// el kardex heredan la que se eligió en Insumos, y la elección sobrevive al
/// salir y volver (se persiste por negocio).
///
/// `null` = "Todas · comparar": la vista de Insumos muestra una columna por
/// bodega y no hay bodega implícita. Las pantallas que SÍ necesitan una
/// bodega concreta (cuadre, salidas) caen a la principal — ver
/// [InventoryWarehouseScope.effectiveId].
final inventoryWarehouseScopeProvider =
    StateNotifierProvider<InventoryWarehouseScope, String?>(
  (ref) => InventoryWarehouseScope(),
);

class InventoryWarehouseScope extends StateNotifier<String?> {
  InventoryWarehouseScope() : super(null);

  String? _businessId;
  bool _restored = false;

  static String _key(String businessId) =>
      'inventory_warehouse_scope_$businessId';

  /// Restaura el contexto persistido para [businessId]. Idempotente: la
  /// segunda llamada devuelve el valor ya en memoria sin tocar disco.
  ///
  /// [validIds] son las bodegas que existen hoy; si la persistida fue
  /// borrada o desactivada, el contexto vuelve a "Todas" en vez de quedar
  /// apuntando a un id fantasma.
  Future<String?> ensureRestored(
    String businessId, {
    Iterable<String>? validIds,
  }) async {
    if (_restored && _businessId == businessId) {
      return _pruned(validIds);
    }
    _businessId = businessId;
    _restored = true;
    try {
      final storage = await StorageService.getInstance();
      final raw = await storage.read(_key(businessId));
      state = (raw == null || raw.isEmpty) ? null : raw;
    } catch (e) {
      debugPrint('InventoryWarehouseScope.ensureRestored error: $e');
      state = null;
    }
    return _pruned(validIds);
  }

  String? _pruned(Iterable<String>? validIds) {
    final current = state;
    if (current == null || validIds == null) return current;
    if (validIds.contains(current)) return current;
    state = null;
    return null;
  }

  /// Fija el contexto. `null` = "Todas · comparar".
  Future<void> select(String? warehouseId) async {
    if (state == warehouseId) return;
    state = warehouseId;
    final businessId = _businessId;
    if (businessId == null) return;
    try {
      final storage = await StorageService.getInstance();
      if (warehouseId == null) {
        await storage.delete(_key(businessId));
      } else {
        await storage.write(_key(businessId), warehouseId);
      }
    } catch (e) {
      debugPrint('InventoryWarehouseScope.select error: $e');
    }
  }

  /// Bodega concreta para las pantallas que no saben trabajar en "Todas".
  /// Devuelve la del contexto si sigue siendo válida; si no, [fallback].
  String? effectiveId(Iterable<String> validIds, String? fallback) {
    final current = state;
    if (current != null && validIds.contains(current)) return current;
    return fallback;
  }
}
