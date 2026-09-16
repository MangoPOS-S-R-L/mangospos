// Presentaciones de dos niveles (Compras F5a): lee `inventory_item_presentations`
// y guarda el juego completo con `fn_inventory_item_presentations_save`
// (20260915_0009), que valida y aplana la de compra en purchase_unit/pack_size.
//
// Degrada: sin la migración, `getForItem` devuelve null y el formulario del
// insumo esconde la sección.

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/inventory/item_presentations.dart';

/// La base no tiene la tabla o la función (20260915_0009 sin aplicar).
class ItemPresentationsUnsupported implements Exception {
  const ItemPresentationsUnsupported();

  @override
  String toString() =>
      'Las presentaciones necesitan la migración 20260915_0009 aplicada.';
}

class ItemPresentationsRepository {
  ItemPresentationsRepository(this._client);
  final SupabaseClient _client;

  /// Tri-estado estático: la tabla existe o no en el servidor.
  static bool? _supported;

  static bool _isMissing(PostgrestException e) =>
      e.code == '42P01' ||
      e.code == 'PGRST205' ||
      e.code == 'PGRST202' ||
      e.code == '42883';

  /// Las presentaciones del insumo, en su orden. `null` si la base no las
  /// soporta.
  Future<List<PresentationDraft>?> getForItem(String itemId) async {
    if (_supported == false) return null;
    try {
      final rows = await _client
          .from('inventory_item_presentations')
          .select('unit, contains_qty, contains_unit, is_purchase_default, sort_order')
          .eq('item_id', itemId)
          .order('sort_order');
      _supported = true;
      return [
        for (final row in (rows as List).whereType<Map>())
          PresentationDraft.fromMap(Map<String, dynamic>.from(row)),
      ];
    } on PostgrestException catch (e) {
      if (_isMissing(e)) {
        _supported = false;
        return null;
      }
      rethrow;
    }
  }

  /// Reemplaza el juego completo. Devuelve lo que quedó guardado.
  Future<List<PresentationDraft>> save(
    String itemId,
    List<PresentationDraft> presentations,
  ) async {
    try {
      final result = await _client.rpc(
        'fn_inventory_item_presentations_save',
        params: {
          'p_item_id': itemId,
          'p_presentations': [for (final p in presentations) p.toJson()],
        },
      );
      _supported = true;
      return [
        for (final row in (result as List? ?? const []).whereType<Map>())
          PresentationDraft.fromMap(Map<String, dynamic>.from(row)),
      ];
    } on PostgrestException catch (e) {
      if (_isMissing(e)) {
        _supported = false;
        throw const ItemPresentationsUnsupported();
      }
      rethrow;
    }
  }

  /// El motivo legible de un error de la función («PRESENTATIONS_DUPLICATE:
  /// «Caja» está repetida» → ««Caja» está repetida»).
  static String reason(Object error) {
    final message = error is PostgrestException ? error.message : error.toString();
    final match = RegExp(r'PRESENTATIONS_[A-Z_]+:\s*(.+)').firstMatch(message);
    return match?.group(1)?.trim() ?? message;
  }
}
