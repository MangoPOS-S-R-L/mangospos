// Mínimos en lote (Compras F3). Lee los mínimos y máximos generales de los
// insumos y los propios de un almacén, y guarda muchos de una vez con
// `fn_inventory_set_min_stock_bulk` (20260915_0007): una transacción, con el
// mismo permiso que editar insumos.
//
// Todo paginado de 1,000 en 1,000: PostgREST corta ahí y un negocio como La
// Penda tiene 2,308 insumos (y tras «aplicar sugerido» un almacén puede tener
// más de 1,000 mínimos propios).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// La base no tiene `fn_inventory_set_min_stock_bulk` (20260915_0007 sin
/// aplicar).
class MinStockBulkUnsupported implements Exception {
  const MinStockBulkUnsupported();

  @override
  String toString() =>
      'Guardar mínimos en lote necesita la migración 20260915_0007 aplicada.';
}

class MinStockBulkRepository {
  MinStockBulkRepository(this._client);
  final SupabaseClient _client;

  static const int _pageSize = 1000;

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  /// itemId → (mínimo general, máximo) de los insumos del negocio.
  Future<Map<String, ({double min, double? max})>> getItemLimits(
    String businessId,
  ) async {
    final result = <String, ({double min, double? max})>{};
    for (var from = 0;; from += _pageSize) {
      final rows = await _client
          .from('inventory_items')
          .select('id, min_stock, max_stock')
          .eq('business_id', businessId)
          .order('id')
          .range(from, from + _pageSize - 1);
      final page = List<Map<String, dynamic>>.from(rows as List);
      for (final row in page) {
        result[row['id'].toString()] = (
          min: _toDouble(row['min_stock']) ?? 0,
          max: _toDouble(row['max_stock']),
        );
      }
      if (page.length < _pageSize) break;
    }
    return result;
  }

  /// itemId → mínimo propio del almacén (solo los que tienen uno).
  Future<Map<String, double>> getWarehouseMins(String warehouseId) async {
    final result = <String, double>{};
    for (var from = 0;; from += _pageSize) {
      final rows = await _client
          .from('inventory_stock')
          .select('item_id, min_stock')
          .eq('warehouse_id', warehouseId)
          .not('min_stock', 'is', null)
          .order('item_id')
          .range(from, from + _pageSize - 1);
      final page = List<Map<String, dynamic>>.from(rows as List);
      for (final row in page) {
        final value = _toDouble(row['min_stock']);
        if (value != null) result[row['item_id'].toString()] = value;
      }
      if (page.length < _pageSize) break;
    }
    return result;
  }

  /// Guarda [changes] (itemId → mínimo; null = quitar) en una transacción.
  /// Sin almacén cambia el mínimo general; con almacén, el propio de ese
  /// almacén. Lanza [MinStockBulkUnsupported] si la base no tiene la función.
  Future<({int updated, int unchanged})> setMinStockBulk({
    required String businessId,
    required String? warehouseId,
    required Map<String, double?> changes,
  }) async {
    if (changes.isEmpty) return (updated: 0, unchanged: 0);
    try {
      final result = await _client.rpc(
        'fn_inventory_set_min_stock_bulk',
        params: {
          'p_business_id': businessId,
          'p_warehouse_id': warehouseId,
          'p_changes': [
            for (final e in changes.entries)
              {'item_id': e.key, 'min_stock': e.value},
          ],
        },
      );
      final map = Map<String, dynamic>.from(result as Map);
      return (
        updated: (map['updated'] as num?)?.toInt() ?? 0,
        unchanged: (map['unchanged'] as num?)?.toInt() ?? 0,
      );
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || e.code == '42883') {
        throw const MinStockBulkUnsupported();
      }
      rethrow;
    }
  }
}

final minStockBulkRepositoryProvider = Provider<MinStockBulkRepository>(
  (ref) => MinStockBulkRepository(Supabase.instance.client),
);
