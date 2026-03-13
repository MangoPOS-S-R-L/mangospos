import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/sales_queries.dart';
import '../models/sales_models.dart';
import '../utils/business_id_resolver.dart';

/// 🥭 MangoPOS - Sales Repository
/// Repositorio completo para el módulo de ventas
class SalesRepository {
  final SupabaseClient _client;
  SalesRepository(this._client);

  static const _itemFields =
      'id,order_id,product_id,product_name,sku,quantity,qty,unit_price,subtotal,discounts,tax,total,check_id,is_takeout,status,notes,created_at';

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

  /// Asignar una orden manual a una mesa real
  Future<Map<String, dynamic>> assignManualOrderToTable({
    required String orderId,
    required String tableId,
    String? userId,
  }) async {
    try {
      final response = await _client.rpc(
        'fn_assign_manual_order_to_table',
        params: {
          'p_order_id': orderId,
          'p_table_id': tableId,
          'p_user_id': userId,
        },
      );

      if (response == null) {
        throw Exception('No se pudo asignar la venta manual a mesa');
      }

      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al asignar venta manual a mesa: $e');
    }
  }

  /// Obtener sesiones activas
  Future<List<TableSession>> getActiveSessions(String businessId) async {
    try {
      final data = await _client
          .from('table_sessions')
          .select('*, dining_tables(code, zones(name))')
          .eq('business_id', businessId)
          .isFilter('closed_at', null)
          .order('opened_at', ascending: false);

      return data.map((json) => TableSession.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener sesiones activas: $e');
    }
  }

  Future<({String? customerId, String? customerName, String? note})> getSessionCustomer(
    String sessionId,
  ) async {
    try {
      final data = await _client
          .from('table_sessions')
          .select('customer_id, customer_name, note')
          .eq('id', sessionId)
          .maybeSingle();

      return (
        customerId: data?['customer_id'] as String?,
        customerName: data?['customer_name'] as String?,
        note: data?['note'] as String?,
      );
    } catch (e) {
      throw Exception('Error al obtener cliente de la sesión: $e');
    }
  }

  Future<void> assignCustomerToSession({
    required String sessionId,
    required String customerId,
    required String customerName,
  }) async {
    try {
      await _client.rpc(
        'fn_assign_customer_to_session',
        params: {
          'p_session_id': sessionId,
          'p_customer_id': customerId,
          'p_customer_name': customerName.trim().isEmpty
              ? null
              : customerName.trim(),
        },
      );
    } catch (e) {
      throw Exception('Error al asignar cliente: $e');
    }
  }

  Future<void> updateSessionNote({
    required String sessionId,
    String? note,
  }) async {
    try {
      await _client
          .from('table_sessions')
          .update({'note': note?.trim().isEmpty == true ? null : note?.trim()})
          .eq('id', sessionId);
    } catch (e) {
      throw Exception('Error al actualizar nota de la sesión: $e');
    }
  }

  Future<void> setMenuItemAvailability({
    required String menuItemId,
    required bool isActive,
  }) async {
    try {
      await _client
          .from('menu_items')
          .update({'is_active': isActive})
          .eq('id', menuItemId);
    } catch (e) {
      throw Exception('Error al actualizar disponibilidad del producto: $e');
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

  /// Actualizar detalle completo del item
  Future<void> updateItemDetails({
    required String itemId,
    required String productName,
    required double quantity,
    required bool isTakeout,
    required double discounts,
    String? notes,
  }) async {
    try {
      final normalizedQty = quantity <= 0 ? 1.0 : quantity;
      try {
        await _client.rpc(
          SalesQueries.rpcUpdateItemDetails,
          params: {
            'p_item_id': itemId,
            'p_product_name': productName,
            'p_qty': normalizedQty,
            'p_is_takeout': isTakeout,
            'p_discounts': discounts,
            'p_notes': notes,
          },
        );
      } catch (rpcError) {
        // Fallback temporal si el RPC aún no está migrado.
        final updated = await _client
            .from('order_items')
            .update({
              'product_name': productName,
              'quantity': normalizedQty.round(),
              'qty': normalizedQty,
              'is_takeout': isTakeout,
            })
            .eq('id', itemId)
            .select('id')
            .maybeSingle();
        if (updated == null) {
          throw Exception('ITEM_NOT_UPDATED');
        }
        await updateItemDiscountAndNotes(
          itemId: itemId,
          discounts: discounts,
          notes: notes,
        );
      }
    } catch (e) {
      throw Exception('Error al actualizar item: $e');
    }
  }

  /// Actualiza solo el descuento del item (sin tocar qty/quantity).
  Future<void> updateItemDiscount({
    required String itemId,
    required double discounts,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcUpdateItemDiscount,
        params: {'p_item_id': itemId, 'p_discounts': discounts},
      );
    } catch (e) {
      // Fallback temporal si el RPC aún no está migrado.
      try {
        await _client
            .from('order_items')
            .update({'discounts': discounts})
            .eq('id', itemId);
      } catch (_) {
        throw Exception('Error al actualizar descuento del item: $e');
      }
    }
  }

  /// Actualiza descuento y notas del item en una sola escritura.
  Future<void> updateItemDiscountAndNotes({
    required String itemId,
    required double discounts,
    String? notes,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcUpdateItemDiscountAndNotes,
        params: {
          'p_item_id': itemId,
          'p_discounts': discounts,
          'p_notes': notes,
        },
      );
    } catch (e) {
      // Fallback temporal si el RPC aún no está migrado.
      try {
        await _client
            .from('order_items')
            .update({'discounts': discounts, 'notes': notes})
            .eq('id', itemId);
      } catch (_) {
        throw Exception('Error al actualizar descuento/notas del item: $e');
      }
    }
  }

  /// Eliminar item (Directo para evitar timeout en RPC)
  Future<void> deleteItem({required String itemId}) async {
    try {
      // Intentar directo primero para rapidez y evitar timeout de funcion compleja
      await _client.from('order_items').delete().eq('id', itemId);
    } catch (e) {
      // Fallback a RPC si falla por permisos o triggers complejos (aunque delete directo suele ser mejor)
      try {
        await _client.rpc(
          SalesQueries.rpcDeleteItem,
          params: {'p_item_id': itemId},
        );
      } catch (_) {
        throw Exception('Error al eliminar item: $e');
      }
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

  /// Obtener bundle de orden en una sola llamada RPC:
  /// order + items + checks + customer(session)
  Future<
    ({
      Order? order,
      List<OrderItem> items,
      List<OrderCheck> checks,
      String? customerId,
      String? customerName,
    })
  >
  getOrderBundle(String orderId) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcGetOrderBundle,
        params: {'p_order_id': orderId},
      );

      if (response == null) {
        return (
          order: null,
          items: const <OrderItem>[],
          checks: const <OrderCheck>[],
          customerId: null,
          customerName: null,
        );
      }

      final payload = Map<String, dynamic>.from(response as Map);

      final orderMap = payload['order'];
      final order = orderMap is Map<String, dynamic>
          ? Order.fromMap(orderMap)
          : (orderMap is Map
                ? Order.fromMap(Map<String, dynamic>.from(orderMap))
                : null);

      final itemsRaw = (payload['items'] as List?) ?? const [];
      final items = itemsRaw
          .map(
            (row) => OrderItem.fromMap(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);

      final checksRaw = (payload['checks'] as List?) ?? const [];
      final checks = checksRaw
          .map(
            (row) => OrderCheck.fromMap(Map<String, dynamic>.from(row as Map)),
          )
          .toList(growable: false);

      return (
        order: order,
        items: items,
        checks: checks,
        customerId: payload['customer_id']?.toString(),
        customerName: payload['customer_name']?.toString(),
      );
    } catch (e) {
      throw Exception('Error al obtener bundle de orden: $e');
    }
  }

  /// Obtener items de una orden
  Future<List<OrderItem>> getOrderItems(
    String orderId, {
    bool includeModifiers = true,
    int limit = 500,
    bool onlyOpen = false,
  }) async {
    try {
      final baseSelect = includeModifiers
          ? '$_itemFields,order_item_modifiers(*)'
          : _itemFields;

      var query = _client
          .from('order_items')
          .select(baseSelect)
          .eq('order_id', orderId);

      if (onlyOpen) {
        query = query.not('status', 'in', '(paid,void)');
      }

      final data = await query
          .order('created_at', ascending: true)
          .limit(limit);

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
        .neq('status', 'void'); // Excluir items anulados

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

  /// Obtener payload compacto de una mesa (usa RPC get_table_live)
  Future<Map<String, dynamic>?> getTableLive(String tableId) async {
    try {
      final res = await _client.rpc(
        'get_table_live',
        params: {'p_table_id': tableId},
      );
      if (res == null) return null;
      return Map<String, dynamic>.from(res as Map);
    } catch (e) {
      throw Exception('Error al obtener tabla (get_table_live): $e');
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

  /// Dividir cada item de la orden en partes iguales entre subcuentas.
  Future<List<OrderCheck>> splitItemsEqually({
    required String orderId,
    required int people,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcSplitItemsEqually,
        params: {'p_order_id': orderId, 'p_people': people},
      );

      final checksData = response as List;
      return checksData.map((json) => OrderCheck.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al dividir items en partes iguales: $e');
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

  /// Mover múltiples items a un mismo check (batch).
  Future<int> moveItemsToCheckBatch({
    required List<String> itemIds,
    required int checkPosition,
  }) async {
    if (itemIds.isEmpty) return 0;
    try {
      final response = await _client.rpc(
        SalesQueries.rpcMoveItemsToCheckBatch,
        params: {'p_item_ids': itemIds, 'p_check_position': checkPosition},
      );
      if (response == null) return 0;
      return (response as num).toInt();
    } catch (e) {
      throw Exception('Error al mover items en lote: $e');
    }
  }

  /// Consolida líneas duplicadas dentro de una subcuenta.
  /// Útil después de unir cuentas para no terminar con items duplicados.
  Future<void> consolidateCheckItems({required String checkId}) async {
    try {
      final rawItems = await _client
          .from('order_items')
          .select(
            'id,product_id,product_name,sku,unit_price,is_takeout,status,notes,qty,quantity,discounts,created_at',
          )
          .eq('check_id', checkId)
          .not('status', 'in', '(paid,void)')
          .order('created_at', ascending: true);

      final items = List<Map<String, dynamic>>.from(rawItems as List);
      if (items.length < 2) return;

      final itemIds = items
          .map((i) => i['id']?.toString())
          .whereType<String>()
          .toList(growable: false);
      if (itemIds.length < 2) return;

      final rawMods = await _client
          .from('order_item_modifiers')
          .select('item_id')
          .inFilter('item_id', itemIds);
      final itemIdsWithMods = (rawMods as List)
          .map((m) => (m as Map)['item_id']?.toString())
          .whereType<String>()
          .toSet();

      final groups = <String, List<Map<String, dynamic>>>{};
      for (final item in items) {
        final id = item['id']?.toString();
        if (id == null || id.isEmpty) continue;

        // Si tiene modificadores, no consolidamos para evitar mezclar recetas distintas.
        if (itemIdsWithMods.contains(id)) {
          groups['id:$id'] = [item];
          continue;
        }

        final key =
            '${item['product_id'] ?? ''}|${item['product_name'] ?? ''}|${item['sku'] ?? ''}|'
            '${item['unit_price'] ?? 0}|${item['is_takeout'] ?? false}|${item['status'] ?? ''}|'
            '${item['notes'] ?? ''}';
        groups.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(item);
      }

      for (final grouped in groups.values) {
        if (grouped.length < 2) continue;

        final keeper = grouped.first;
        final keeperId = keeper['id']?.toString();
        if (keeperId == null || keeperId.isEmpty) continue;

        double sumQty = 0;
        double sumDiscounts = 0;
        final removeIds = <String>[];

        for (var idx = 0; idx < grouped.length; idx++) {
          final row = grouped[idx];
          final qtyRaw = row['qty'];
          final quantityRaw = row['quantity'];
          final qty = (qtyRaw is num)
              ? qtyRaw.toDouble()
              : (quantityRaw is num)
              ? quantityRaw.toDouble()
              : double.tryParse(qtyRaw?.toString() ?? '') ??
                    double.tryParse(quantityRaw?.toString() ?? '') ??
                    1.0;
          final discountsRaw = row['discounts'];
          final discounts = (discountsRaw is num)
              ? discountsRaw.toDouble()
              : double.tryParse(discountsRaw?.toString() ?? '') ?? 0.0;

          sumQty += qty;
          sumDiscounts += discounts;

          if (idx > 0) {
            final id = row['id']?.toString();
            if (id != null && id.isNotEmpty) removeIds.add(id);
          }
        }

        await _client
            .from('order_items')
            .update({
              'qty': sumQty,
              'quantity': sumQty.round(),
              'discounts': sumDiscounts,
            })
            .eq('id', keeperId);

        if (removeIds.isNotEmpty) {
          await _client.from('order_items').delete().inFilter('id', removeIds);
        }
      }
    } catch (e) {
      throw Exception('Error al consolidar items de subcuenta: $e');
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
    double changeAmount = 0,
    bool closeOrder = true,
  }) async {
    try {
      // Intentamos usar el RPC optimizado (v2) que tiene mayor timeout configurado
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
          'p_cashier_session_id': cashierSessionId,
        },
      );

      return Payment.fromMap(response as Map<String, dynamic>);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('CASH_SESSION_REQUIRED') ||
          msg.contains('CASH_SESSION_NOT_OPEN')) {
        rethrow;
      }
      throw Exception(
        'No se pudo procesar el pago de forma atomica. La operacion fue cancelada: $e',
      );
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
    final rows = await _client
        .from('orders')
        .select('session_id, table_sessions!inner(id)')
        .eq('table_sessions.business_id', businessId)
        .eq('table_sessions.origin', 'dine_in')
        .isFilter('table_sessions.closed_at', null)
        .isFilter('closed_at', null)
        .not('status_ext', 'in', '(paid,void)');

    final sessionIds = rows
        .map((row) => row['session_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();

    return sessionIds.length;
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
