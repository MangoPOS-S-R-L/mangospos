import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

class SalesRepository {
  final SupabaseClient _client;
  SalesRepository(this._client);

  // 🔸 Abrir mesa y crear orden base
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
  }) async {
    final response = await _client.rpc(
      'fn_open_table',
      params: {
        'p_table_id': tableId,
        'p_user_id': userId,
        'p_people_count': peopleCount,
      },
    );
    if (response == null) {
      throw Exception('No se pudo abrir la mesa');
    }
    return Map<String, dynamic>.from(response as Map);
  }

  // 🔸 Venta Manual / Rápida
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin, // 'manual' o 'quick'
    required String userId,
    int peopleCount = 1,
  }) async {
    final response = await _client.rpc(
      'fn_open_manual_or_quick',
      params: {
        'p_origin': origin,
        'p_user_id': userId,
        'p_people_count': peopleCount,
      },
    );
    if (response == null) {
      throw Exception('No se pudo abrir la venta $origin');
    }
    return Map<String, dynamic>.from(response as Map);
  }

  // 🔸 Agregar producto del menú a una orden
  Future<String> addItemFromMenu({
    required String orderId,
    required String menuItemId,
    double qty = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
  }) async {
    final response = await _client.rpc(
      'fn_add_item_from_menu',
      params: {
        'p_order_id': orderId,
        'p_menu_item_id': menuItemId,
        'p_qty': qty,
        'p_check_position': checkPosition,
        'p_is_takeout': isTakeout,
        'p_notes': notes,
      },
    );
    return response as String;
  }

  // 🔸 Marcar toda la orden “para llevar”
  Future<void> markOrderTakeout({
    required String orderId,
    required bool takeout,
  }) async {
    await _client.rpc('fn_mark_order_takeout', params: {
      'p_order_id': orderId,
      'p_takeout': takeout,
    });
  }

  // 🔸 Mover ítem entre subcuentas
  Future<void> moveItemToCheck({
    required String itemId,
    required int checkPosition,
  }) async {
    await _client.rpc('fn_move_item_to_check', params: {
      'p_item_id': itemId,
      'p_check_position': checkPosition,
    });
  }

  // 🔸 Cambiar estado “para llevar” por ítem
  Future<void> toggleItemTakeout({
    required String itemId,
    required bool takeout,
  }) async {
    await _client.rpc('fn_toggle_item_takeout', params: {
      'p_item_id': itemId,
      'p_takeout': takeout,
    });
  }

  // 🔸 Cerrar orden y mesa
  Future<void> closeOrder({
    required String orderId,
    required String status, // 'paid' o 'void'
  }) async {
    await _client.rpc('fn_close_order_and_table', params: {
      'p_order_id': orderId,
      'p_status': status,
    });
  }

  // 🔸 Obtener detalle completo de la orden (v_order_detail)
  Future<List<Map<String, dynamic>>> getOrderDetail(String orderId) async {
    final data = await _client
        .from('v_order_detail')
        .select()
        .eq('order_id', orderId)
        .order('check_pos', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }
}
