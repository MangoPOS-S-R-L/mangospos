// Comparador de precios (Compras F4). Lee `fn_purchase_price_comparison`
// (20260915_0008): por insumo × suplidor, el costo real recibido y el precio de
// lista.
//
// Degrada: sin la función devuelve `null` y quien llama sigue sin precios.
// Los insumos van en tandas (una lista de uuids muy larga engorda la llamada) y
// cada tanda se pagina de 1,000 en 1,000 (PostgREST corta ahí).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/inventory/price_comparison.dart';

class PriceComparisonRepository {
  PriceComparisonRepository(this._client);
  final SupabaseClient _client;

  /// Tri-estado estático: la función existe o no en el servidor.
  static bool? _supported;

  static const int _itemsPerCall = 300;
  static const int _pageSize = 1000;

  /// Precios por suplidor de [itemIds] (null = todos los insumos). `null` si
  /// la base no tiene la función.
  Future<List<SupplierPrice>?> getComparison({
    required String businessId,
    List<String>? itemIds,
    int daysBack = 90,
  }) async {
    if (_supported == false) return null;
    if (itemIds != null && itemIds.isEmpty) return const [];

    final chunks = <List<String>?>[
      if (itemIds == null) null,
      if (itemIds != null)
        for (var i = 0; i < itemIds.length; i += _itemsPerCall)
          itemIds.sublist(
            i,
            i + _itemsPerCall > itemIds.length ? itemIds.length : i + _itemsPerCall,
          ),
    ];

    final result = <SupplierPrice>[];
    try {
      for (final chunk in chunks) {
        for (var from = 0;; from += _pageSize) {
          final rows = await _client
              .rpc(
                'fn_purchase_price_comparison',
                params: {
                  'p_business_id': businessId,
                  'p_item_ids': chunk,
                  'p_days_back': daysBack,
                },
              )
              .range(from, from + _pageSize - 1);
          _supported = true;
          final page = (rows as List).whereType<Map>().toList(growable: false);
          result.addAll(
            page.map((row) => SupplierPrice.fromMap(Map<String, dynamic>.from(row))),
          );
          if (page.length < _pageSize) break;
        }
      }
      return result;
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || e.code == '42883') {
        _supported = false;
        return null;
      }
      rethrow;
    }
  }
}

final priceComparisonRepositoryProvider = Provider<PriceComparisonRepository>(
  (ref) => PriceComparisonRepository(Supabase.instance.client),
);
