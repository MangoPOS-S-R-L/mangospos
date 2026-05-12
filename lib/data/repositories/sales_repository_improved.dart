// lib/data/repositories/sales_repository_improved.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/sales_queries.dart';
import '../models/sales_models.dart';
import '../utils/business_id_resolver.dart';
import '../../core/network/database_operation_wrapper.dart';

/// 🥭 MangoPOS - Sales Repository (Mejorado)
/// Repositorio con manejo robusto de errores, timeouts y reintentos
class SalesRepositoryImproved {
  final SupabaseClient _client;
  SalesRepositoryImproved(this._client);

  Future<void> _assertOrderInBusinessScope(
    String orderId, {
    String? businessId,
  }) async {
    final scopedBusinessId = businessId?.trim();
    if (scopedBusinessId == null || scopedBusinessId.isEmpty) return;

    final row = await _client
        .from('orders')
        .select('id, table_sessions!inner(business_id)')
        .eq('id', orderId)
        .eq('table_sessions.business_id', scopedBusinessId)
        .maybeSingle();

    if (row == null) {
      throw Exception('ORDER_OUT_OF_SCOPE');
    }
  }

  // ============================================================
  // 📊 SESIONES DE MESA
  // ============================================================

  /// Abrir sesión de mesa (venta por mesa) con reintentos automáticos
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
  }) async {
    return DatabaseOperationWrapper.rpc(
      operationName: 'Abrir Mesa #$tableId',
      operation: () async {
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
      },
    );
  }

  /// Abrir venta manual o rápida con reintentos
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin,
    String? customerName,
    int peopleCount = 1,
  }) async {
    return DatabaseOperationWrapper.rpc(
      operationName: 'Abrir Venta $origin',
      operation: () async {
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
      },
    );
  }

  /// Obtener sesiones activas con timeout optimizado
  Future<List<TableSession>> getActiveSessions(String businessId) async {
    return DatabaseOperationWrapper.read(
      operationName: 'Obtener Sesiones Activas',
      operation: () async {
        final data = await _client
            .from('table_sessions')
            .select()
            .eq('business_id', businessId)
            .isFilter('closed_at', null)
            .order('opened_at', ascending: false);

        return data.map((json) => TableSession.fromMap(json)).toList();
      },
    );
  }

  // ============================================================
  // 🍔 ITEMS DE ORDEN
  // ============================================================

  /// Agregar producto del menú a la orden con reintentos
  Future<String> addItemFromMenu({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
  }) async {
    return DatabaseOperationWrapper.rpc(
      operationName: 'Agregar Item a Orden',
      operation: () async {
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
      },
    );
  }

  /// Actualizar cantidad de item con reintentos
  Future<void> updateItemQuantity({
    required String itemId,
    required double quantity,
  }) async {
    return DatabaseOperationWrapper.rpc(
      operationName: 'Actualizar Cantidad',
      operation: () async {
        await _client.rpc(
          SalesQueries.rpcUpdateItemQty,
          params: {'p_item_id': itemId, 'p_qty': quantity},
        );
      },
    );
  }

  /// Eliminar item con reintentos
  Future<void> deleteItem({required String itemId}) async {
    return DatabaseOperationWrapper.rpc(
      operationName: 'Eliminar Item',
      operation: () async {
        await _client.rpc(
          SalesQueries.rpcDeleteItem,
          params: {'p_item_id': itemId},
        );
      },
    );
  }

  // ============================================================
  // 🧾 DETALLE DE ORDEN
  // ============================================================

  /// Obtener orden completa con items
  Future<Order?> getOrder(String orderId, {String? businessId}) async {
    return DatabaseOperationWrapper.read(
      operationName: 'Obtener Orden',
      operation: () async {
        await _assertOrderInBusinessScope(orderId, businessId: businessId);

        final data = await _client
            .from('orders')
            .select()
            .eq('id', orderId)
            .maybeSingle();

        if (data == null) return null;

        return Order.fromMap(data);
      },
    );
  }

  /// Obtener items de una orden con timeout optimizado
  Future<List<OrderItem>> getOrderItems(
    String orderId, {
    bool includeModifiers = true,
    bool onlyOpen = false,
    String? businessId,
  }) async {
    return DatabaseOperationWrapper.read(
      operationName: 'Obtener Items de Orden',
      operation: () async {
        await _assertOrderInBusinessScope(orderId, businessId: businessId);

        if (onlyOpen) {
          final data = await _client
              .from('order_items')
              .select(includeModifiers ? '*, order_item_modifiers(*)' : '*')
              .eq('order_id', orderId)
              .not('status', 'in', '(paid,void)')
              .order('created_at', ascending: true);

          return _mapItems(data, includeModifiers);
        } else {
          final data = await _client
              .from('order_items')
              .select(includeModifiers ? '*, order_item_modifiers(*)' : '*')
              .eq('order_id', orderId)
              .order('created_at', ascending: true);

          return _mapItems(data, includeModifiers);
        }
      },
    );
  }

  List<OrderItem> _mapItems(List<dynamic> data, bool includeModifiers) {
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
  }

  /// Elimina todos los items de un check y recalcula totales en DB
  Future<void> clearCheck(String checkId) async {
    throw UnsupportedError(
      'clearCheck() fue deshabilitado porque podia marcar items como pagados '
      'sin registrar un pago. Usa processPayment() para cobrar o deleteCheck() '
      'para eliminar la subcuenta despues de mover sus items.',
    );
  }

  Future<void> _recomputeOrderTotals(String orderId) async {
    final rows = await _client
        .from('order_items')
        .select('subtotal, discounts, tax, total')
        .eq('order_id', orderId)
        .neq('status', 'void');

    double subtotal = 0, discounts = 0, tax = 0, total = 0;
    for (final r in rows) {
      subtotal += (r['subtotal'] ?? 0).toDouble();
      discounts += (r['discounts'] ?? 0).toDouble();
      tax += (r['tax'] ?? 0).toDouble();
      total += (r['total'] ?? 0).toDouble();
    }

    await _client
        .from('orders')
        .update({
          'subtotal': subtotal,
          'discounts': discounts,
          'tax': tax,
          'total': total,
        })
        .eq('id', orderId);
  }

  /// Eliminar un check y sus items
  Future<void> deleteCheck(String checkId) async {
    final check = await _client
        .from('order_checks')
        .select('order_id')
        .eq('id', checkId)
        .maybeSingle();
    if (check == null || check['order_id'] == null) return;
    final orderId = check['order_id'] as String;

    await _client.from('order_items').delete().eq('check_id', checkId);
    await _client.from('order_checks').delete().eq('id', checkId);
    await _recomputeOrderTotals(orderId);
  }

  // ============================================================
  // 💰 PAGOS
  // ============================================================

  /// Procesar pago con manejo especial de errores
  ///
  /// `splitSequence` distingue múltiples pagos del mismo método sobre la
  /// misma orden/check. Ver doc en `SalesRepository.processPayment`.
  Future<Payment> processPayment({
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    int splitSequence = 0,
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
          'p_change_amount': changeAmount,
          'p_customer_id': customerId,
          'p_customer_rnc': customerRnc,
          'p_requested_ncf_type': fiscalType,
          'p_cashier_session_id': cashierSessionId,
          'p_close_order': closeOrder,
          'p_split_sequence': splitSequence,
        },
      );

      debugPrint('Rpc Response Type: ${response.runtimeType}');
      if (response is! Map) {
        debugPrint('⚠️ Rpc Response is not a Map: $response');
      }

      return Payment.fromMap(Map<String, dynamic>.from(response as Map));
    } catch (e, s) {
      debugPrint('⚠️ Error en RPC processPayment: $e\nStack: $s');
      final msg = e.toString();
      if (msg.contains('CASH_SESSION_REQUIRED') ||
          msg.contains('CASH_SESSION_NOT_OPEN')) {
        rethrow;
      }
      if (msg.contains('Demasiadas colisiones de NCF')) {
        final recovered = await _recoverCompletedPaymentAfterNcfCollision(
          orderId: orderId,
          checkId: checkId,
          amount: amount,
          changeAmount: changeAmount,
          cashierSessionId: cashierSessionId,
        );
        if (recovered != null) {
          return recovered;
        }
      }
      throw Exception(
        'No se pudo procesar el pago de forma atomica. La operacion fue cancelada: $e',
      );
    }
  }

  Future<Payment?> _recoverCompletedPaymentAfterNcfCollision({
    required String orderId,
    String? checkId,
    required double amount,
    required double changeAmount,
    String? cashierSessionId,
  }) async {
    try {
      dynamic query = _client
          .from('payments')
          .select()
          .eq('order_id', orderId)
          .eq('status', 'completed');

      query = checkId == null
          ? query.isFilter('check_id', null)
          : query.eq('check_id', checkId);

      if (cashierSessionId != null && cashierSessionId.isNotEmpty) {
        query = query.eq('session_id', cashierSessionId);
      }

      final rows = await query.order('created_at', ascending: false).limit(5);
      final now = DateTime.now().toUtc();

      for (final row in rows) {
        final payment = Payment.fromMap(Map<String, dynamic>.from(row as Map));
        final secondsDiff = now
            .difference(payment.createdAt.toUtc())
            .inSeconds
            .abs();
        final amountMatches = (payment.amount - amount).abs() <= 0.01;
        final changeMatches =
            (payment.changeAmount - changeAmount).abs() <= 0.01;

        if (secondsDiff <= 120 && amountMatches && changeMatches) {
          return payment;
        }
      }
    } catch (_) {}

    return null;
  }

  /// Cerrar orden y sesión con reintentos
  Future<void> closeOrder({
    required String orderId,
    required String status,
  }) async {
    return DatabaseOperationWrapper.rpc(
      operationName: 'Cerrar Orden',
      operation: () async {
        await _client.rpc(
          SalesQueries.rpcCloseOrderAndTable,
          params: {'p_order_id': orderId, 'p_status': status},
        );
      },
    );
  }

  // ============================================================
  // 🔧 UTILIDADES (sin cambios)
  // ============================================================

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
}
