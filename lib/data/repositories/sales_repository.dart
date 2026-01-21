import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/sales_queries.dart';
import '../models/sales_models.dart';
import '../utils/business_id_resolver.dart';

/// 🥭 MangoPOS - Sales Repository
/// Repositorio completo para el módulo de ventas
class SalesRepository {
  final SupabaseClient _client;
  SalesRepository(this._client);

  // ============================================================
  // 📊 SESIONES DE MESA
  // ============================================================

  /// Abrir sesión de mesa (venta por mesa)
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcOpenTable,
        params: {
          'p_people_count': peopleCount,
          'p_table_id': tableId,
          'p_user_id': userId,
        },
      );

      if (response == null) {
        throw Exception('No se pudo abrir la mesa');
      }

      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al abrir mesa: $e');
    }
  }

  /// Abrir venta manual o rápida
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin, // 'manual' o 'quick_sale'
    String? customerName,
    int peopleCount = 1,
  }) async {
    try {
      await _ensureVirtualTableForOrigin(origin);

      final response = await _client.rpc(
        SalesQueries.rpcOpenManualOrQuick,
        params: {
          'p_origin': origin,
          'p_people_count': peopleCount,
          'p_user_id': _client.auth.currentUser?.id,
        },
      );

      if (response == null) {
        throw Exception('No se pudo abrir la venta $origin');
      }

      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al abrir venta $origin: $e');
    }
  }

  /// Obtener sesiones activas
  Future<List<TableSession>> getActiveSessions(String businessId) async {
    try {
      final data = await _client
          .from('table_sessions')
          .select()
          .eq('business_id', businessId)
          .isFilter('closed_at', null)
          .order('opened_at', ascending: false);

      return data.map((json) => TableSession.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener sesiones activas: $e');
    }
  }

  // ============================================================
  // 🍔 ITEMS DE ORDEN
  // ============================================================

  /// Agregar producto del menú a la orden
  Future<String> addItemFromMenu({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcAddItemFromMenu,
        params: {
          'p_order_id': orderId,
          'p_menu_item_id': menuItemId,
          'p_qty': quantity,
          'p_check_position': checkPosition,
          'p_is_takeout': isTakeout,
          'p_notes': notes,
        },
      );

      return response as String;
    } catch (e) {
      throw Exception('Error al agregar item: $e');
    }
  }

  /// Actualizar cantidad de item
  Future<void> updateItemQuantity({
    required String itemId,
    required double quantity,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcUpdateItemQty,
        params: {'p_item_id': itemId, 'p_qty': quantity},
      );
    } catch (e) {
      throw Exception('Error al actualizar cantidad: $e');
    }
  }

  /// Actualizar notas de item
  Future<void> updateItemNotes({
    required String itemId,
    required String notes,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcUpdateItemNotes,
        params: {'p_item_id': itemId, 'p_notes': notes},
      );
    } catch (e) {
      throw Exception('Error al actualizar notas: $e');
    }
  }

  /// Eliminar item
  Future<void> deleteItem({required String itemId}) async {
    try {
      await _client.rpc(
        SalesQueries.rpcDeleteItem,
        params: {'p_item_id': itemId},
      );
    } catch (e) {
      throw Exception('Error al eliminar item: $e');
    }
  }

  /// Toggle takeout de item
  Future<void> toggleItemTakeout({
    required String itemId,
    required bool isTakeout,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcToggleItemTakeout,
        params: {'p_item_id': itemId, 'p_takeout': isTakeout},
      );
    } catch (e) {
      throw Exception('Error al cambiar takeout: $e');
    }
  }

  // ============================================================
  // 🧾 DETALLE DE ORDEN
  // ============================================================

  /// Obtener orden completa con items
  Future<Order?> getOrder(String orderId) async {
    try {
      final data = await _client
          .from('orders')
          .select()
          .eq('id', orderId)
          .maybeSingle();

      if (data == null) return null;

      return Order.fromMap(data);
    } catch (e) {
      throw Exception('Error al obtener orden: $e');
    }
  }

  /// Obtener items de una orden
  Future<List<OrderItem>> getOrderItems(
    String orderId, {
    bool includeModifiers = true,
  }) async {
    try {
      final query = _client
          .from('order_items')
          .select(includeModifiers ? '*, order_item_modifiers(*)' : '*')
          .eq('order_id', orderId)
          .order('created_at', ascending: true);

      final data = await query;

      return data.map((json) {
        final item = OrderItem.fromMap(json);
        final modifiers = includeModifiers
            ? (json['order_item_modifiers'] as List?)
                      ?.map((m) => OrderItemModifier.fromMap(m))
                      .toList() ??
                  []
            : const <OrderItemModifier>[];

        return item.copyWith(modifiers: modifiers);
      }).toList();
    } catch (e) {
      throw Exception('Error al obtener items: $e');
    }
  }

  // ============================================================
  // 🍳 ENVIAR A COCINA
  // ============================================================

  /// Confirmar pedido y enviar a cocina
  Future<void> sendToKitchen(String orderId) async {
    try {
      await _client.rpc(
        SalesQueries.rpcConfirmOrderToKitchen,
        params: {'p_order_id': orderId},
      );
    } catch (e) {
      throw Exception('Error al enviar a cocina: $e');
    }
  }

  // ============================================================
  // 📄 DIVISIÓN DE CUENTA (SPLIT BILL)
  // ============================================================

  /// Crear división de cuenta
  Future<List<OrderCheck>> createSplitBill({
    required String orderId,
    required int numberOfChecks,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcCreateSplitBill,
        params: {'p_order_id': orderId, 'p_number_of_checks': numberOfChecks},
      );

      final checksData = response as List;
      return checksData.map((json) => OrderCheck.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al crear división de cuenta: $e');
    }
  }

  /// Mover item a otro check
  Future<void> moveItemToCheck({
    required String itemId,
    required int checkPosition,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcMoveItemToCheck,
        params: {'p_item_id': itemId, 'p_check_position': checkPosition},
      );
    } catch (e) {
      throw Exception('Error al mover item a check: $e');
    }
  }

  /// Obtener checks de una orden
  Future<List<OrderCheck>> getOrderChecks(String orderId) async {
    try {
      final data = await _client
          .from('order_checks')
          .select()
          .eq('order_id', orderId)
          .order('position', ascending: true);

      return data.map((json) => OrderCheck.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener checks: $e');
    }
  }

  // ============================================================
  // 💰 PAGOS
  // ============================================================

  /// Procesar pago
  Future<Payment> processPayment({
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? cashierSessionId,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcProcessPayment,
        params: {
          'p_order_id': orderId,
          'p_check_id': checkId,
          'p_payment_method_id': paymentMethodId,
          'p_amount': amount,
          'p_reference': reference,
          'p_customer_id': customerId,
          'p_customer_rnc': customerRnc,
          'p_cashier_session_id': cashierSessionId,
        },
      );

      return Payment.fromMap(response);
    } catch (e) {
      // No envolver la excepción para permitir manejo específico (ej: PostgrestException)
      rethrow;
    }
  }

  /// Obtener pagos de una orden
  Future<List<Payment>> getOrderPayments(String orderId) async {
    try {
      final data = await _client
          .from('payments')
          .select()
          .eq('order_id', orderId)
          .order('created_at', ascending: false);

      return data.map((json) => Payment.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener pagos: $e');
    }
  }

  // ============================================================
  // 🧾 FACTURACIÓN FISCAL
  // ============================================================

  /// Crear documento fiscal
  Future<FiscalDocument> createFiscalDocument({
    required String orderId,
    required String paymentId,
    String? customerId,
    String? customerRnc,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcCreateFiscalDocument,
        params: {
          'p_order_id': orderId,
          'p_payment_id': paymentId,
          'p_customer_id': customerId,
          'p_customer_rnc': customerRnc,
        },
      );

      return FiscalDocument.fromMap(response);
    } catch (e) {
      throw Exception('Error al crear documento fiscal: $e');
    }
  }

  /// Obtener documento fiscal de una orden
  Future<FiscalDocument?> getOrderFiscalDocument(String orderId) async {
    try {
      final data = await _client
          .from('fiscal_documents')
          .select()
          .eq('order_id', orderId)
          .maybeSingle();

      if (data == null) return null;

      return FiscalDocument.fromMap(data);
    } catch (e) {
      throw Exception('Error al obtener documento fiscal: $e');
    }
  }

  // ============================================================
  // 🔐 CERRAR ORDEN
  // ============================================================

  /// Cerrar orden y sesión
  Future<void> closeOrder({
    required String orderId,
    required String status, // 'paid', 'cancelled', 'void'
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcCloseOrderAndTable,
        params: {'p_order_id': orderId, 'p_status': status},
      );
    } catch (e) {
      throw Exception('Error al cerrar orden: $e');
    }
  }

  // ============================================================
  // 🔧 UTILIDADES
  // ============================================================

  /// Crear mesas virtuales para venta manual/rápida
  Future<void> _ensureVirtualTableForOrigin(String origin) async {
    final normalized = origin == 'quick_sale' ? 'quick' : 'manual';
    final businessId = await resolveBusinessIdOrNull(_client, 'auto');

    if (businessId == null || businessId.isEmpty) {
      throw Exception(
        'No se pudo identificar el negocio para crear una venta $normalized.',
      );
    }

    final zoneName = normalized == 'manual'
        ? 'Ventas manuales'
        : 'Ventas rápidas';
    final tableCode = normalized;
    final tableLabel = normalized == 'manual'
        ? 'Venta manual Auto'
        : 'Venta rápida Auto';
    final zoneSortIndex = normalized == 'manual' ? 900 : 901;

    // Asegurar que existe la zona
    Future<String> ensureZone() async {
      final existing = await _client
          .from('zones')
          .select('id')
          .eq('business_id', businessId)
          .eq('name', zoneName)
          .limit(1)
          .maybeSingle();

      if (existing != null && existing['id'] != null) {
        return existing['id'] as String;
      }

      try {
        final inserted = await _client
            .from('zones')
            .insert({
              'business_id': businessId,
              'name': zoneName,
              'sort_index': zoneSortIndex,
            })
            .select('id')
            .single();
        return inserted['id'] as String;
      } on PostgrestException catch (e) {
        if (e.code == '23505') {
          final retry = await _client
              .from('zones')
              .select('id')
              .eq('business_id', businessId)
              .eq('name', zoneName)
              .limit(1)
              .maybeSingle();
          if (retry != null && retry['id'] != null) {
            return retry['id'] as String;
          }
        }
        rethrow;
      }
    }

    final zoneId = await ensureZone();

    // Verificar si ya existe la mesa virtual
    final existingTable = await _client
        .from('dining_tables')
        .select('id')
        .eq('zone_id', zoneId)
        .eq('code', tableCode)
        .limit(1)
        .maybeSingle();

    if (existingTable != null && existingTable['id'] != null) {
      return;
    }

    // Crear mesa virtual
    try {
      await _client
          .from('dining_tables')
          .insert({
            'zone_id': zoneId,
            'code': tableCode,
            'label': tableLabel,
            'shape': 'square',
            'state': 'available',
            'capacity': 2,
            'pos_x': 0,
            'pos_y': 0,
            'width': 1,
            'height': 1,
            'rotation': 0,
          })
          .select('id')
          .single();
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // Ya existe, ignorar
        return;
      }
      rethrow;
    }
  }

  // ============================================================
  //  🔄 MÉTODOS DE COMPATIBILIDAD (LEGACY)
  // ============================================================

  /// Obtener detalle completo de la orden (LEGACY - usar getOrder + getOrderItems)
  Future<List<Map<String, dynamic>>> getOrderDetail(String orderId) async {
    final data = await _client
        .from('v_order_detail')
        .select()
        .eq('order_id', orderId)
        .order('check_pos', ascending: true);
    return List<Map<String, dynamic>>.from(data);
  }

  /// Contar mesas abiertas (LEGACY - usar getActiveSessions)
  Future<int> getOpenTablesCount(String businessId) async {
    final count = await _client
        .from('orders')
        .count(CountOption.exact)
        .eq('business_id', businessId)
        .eq('status', 'open');
    return count;
  }

  /// Confirmar pedido (LEGACY - usar sendToKitchen)
  Future<void> confirmOrderToKitchen(String orderId) async {
    await sendToKitchen(orderId);
  }

  /// Marcar orden como takeout (LEGACY)
  Future<void> markOrderTakeout({
    required String orderId,
    required bool takeout,
  }) async {
    await _client.rpc(
      'fn_mark_order_takeout',
      params: {'p_order_id': orderId, 'p_takeout': takeout},
    );
  }
}
