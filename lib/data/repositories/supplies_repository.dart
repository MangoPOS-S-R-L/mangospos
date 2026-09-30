// Gastables y menaje (20260930_0051): el panel de control y la clasificación
// en lote.
//
// Repositorio APARTE del de inventario a propósito: `InventoryRepository` ya
// pasa las 2000 líneas y esto son tres consultas que solo usa esta pantalla.
// Las salidas (consumo interno, rotura) siguen yendo por
// `InventoryRepository.recordOutflow`, que es el camino con llave y cola
// offline.

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/inventory/item_classification.dart';
import 'inventory_repository.dart' show InventoryWriteDeniedException;

/// La base todavía no conoce las clases nuevas (20260930_0051 sin aplicar):
/// el CHECK de `item_classification` rechaza 'supply' / 'smallware'.
class SuppliesMigrationMissing implements Exception {
  const SuppliesMigrationMissing();

  @override
  String toString() =>
      'Falta aplicar la migración 20260930_0051_supplies_and_smallware.sql.';
}

/// Un insumo, con su clase, para elegir cuáles son gastables o menaje.
class ClassifiableItem {
  const ClassifiableItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.unit,
    required this.classification,
  });

  final String id;
  final String name;
  final String sku;
  final String unit;
  final String classification;

  factory ClassifiableItem.fromMap(Map<String, dynamic> map) =>
      ClassifiableItem(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        sku: map['sku']?.toString() ?? '',
        unit: map['unit']?.toString() ?? '',
        classification:
            map['item_classification']?.toString() ?? ItemClassification.simple,
      );
}

class SuppliesRepository {
  SuppliesRepository(this._client);
  final SupabaseClient _client;

  static const rpcOverview = 'fn_inventory_supplies_overview';

  /// PostgREST corta cada lectura en 1000 filas.
  static const _pageSize = 1000;

  /// Ids por UPDATE: una lista larga en la URL da 414.
  static const _batchSize = 100;

  /// El servidor no tiene la función del panel (migración sin aplicar).
  static bool isMissingFunction(Object e) =>
      e is PostgrestException && (e.code == 'PGRST202' || e.code == '42883');

  /// Panel del período: ver `fn_inventory_supplies_overview`.
  Future<Map<String, dynamic>> getOverview({
    required String businessId,
    int daysBack = 30,
    String? warehouseId,
  }) async {
    final response = await _client.rpc(
      rpcOverview,
      params: {
        'p_business_id': businessId,
        'p_days_back': daysBack,
        'p_warehouse_id': warehouseId,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  /// Insumos activos del negocio con su clase, por nombre.
  Future<List<ClassifiableItem>> getClassifiableItems(String businessId) async {
    final items = <ClassifiableItem>[];
    for (var from = 0; ; from += _pageSize) {
      final rows = await _client
          .from('inventory_items')
          .select('id, name, sku, unit, item_classification')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('name')
          .order('id')
          .range(from, from + _pageSize - 1);
      final page = List<Map<String, dynamic>>.from(rows);
      items.addAll(page.map(ClassifiableItem.fromMap));
      if (page.length < _pageSize) break;
    }
    return items;
  }

  /// Cambia la clase de [itemIds]. Devuelve cuántos cambió.
  ///
  /// Un UPDATE que la RLS no deja pasar no lanza: cambia 0 filas. Por eso se
  /// piden las filas cambiadas y, si faltan, se avisa en vez de reportar un
  /// éxito falso.
  Future<int> setClassification({
    required String businessId,
    required List<String> itemIds,
    required String classification,
  }) async {
    if (!ItemClassification.isKnown(classification)) {
      throw ArgumentError.value(classification, 'classification');
    }
    var changed = 0;
    for (var i = 0; i < itemIds.length; i += _batchSize) {
      final batch = itemIds.sublist(
        i,
        i + _batchSize > itemIds.length ? itemIds.length : i + _batchSize,
      );
      try {
        final rows = await _client
            .from('inventory_items')
            .update({'item_classification': classification})
            .eq('business_id', businessId)
            .inFilter('id', batch)
            .select('id');
        changed += (rows as List).length;
      } on PostgrestException catch (e) {
        // 23514 = check_violation: la base aún no acepta la clase nueva.
        if (e.code == '23514') throw const SuppliesMigrationMissing();
        rethrow;
      }
    }
    if (changed == 0 && itemIds.isNotEmpty) {
      throw const InventoryWriteDeniedException();
    }
    return changed;
  }
}
