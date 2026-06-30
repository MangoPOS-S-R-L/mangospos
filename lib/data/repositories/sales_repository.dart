import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/app_time.dart';
import '../datasources/queries/sales_queries.dart';
import '../models/order_item_tax_line.dart';
import '../models/sales_models.dart';
import '../utils/business_id_resolver.dart';
import '../utils/payment_amount_utils.dart';

/// Excepción tipada para señalizar que la orden consultada no pertenece
/// al `businessId` activo. Los métodos de lectura la atrapan y devuelven
/// resultados vacíos en lugar de propagar el error a la UI.
class OrderOutOfScopeException implements Exception {
  const OrderOutOfScopeException();
  @override
  String toString() => 'ORDER_OUT_OF_SCOPE';
}

/// 🥭 MangoPOS - Sales Repository
/// Repositorio completo para el módulo de ventas
class SalesRepository {
  final SupabaseClient _client;
  SalesRepository(this._client);

  // PRD multimesero: incluir `created_by_employee_id` + embed del nombre
  // del empleado para que la UI pueda mostrar "quién agregó" cada item
  // sin necesidad de un round-trip extra ni un provider de empleados en
  // memoria. Postgrest resuelve el JOIN vía la FK
  // `order_items_created_by_employee_fk`.
  static const _itemFields =
      'id,order_id,product_id,product_name,sku,quantity,qty,unit_price,subtotal,discounts,tax,total,check_id,is_takeout,status,notes,tax_mode,tax_rate,original_tax_rate,print_area_code,created_at,created_by_employee_id,employees(first_name,last_name)';

  /// Carga las `order_item_tax_lines` de una lista de items en una sola query
  /// y las devuelve agrupadas por `order_item_id`. Producto del PRD 2: la
  /// fuente del desglose de impuestos en pantalla pasa de heurística a
  /// snapshot inmutable persistido por el motor backend.
  Future<Map<String, List<OrderItemTaxLine>>> _loadTaxLinesByItem(
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return const {};

    // Chunking de inFilter para evitar HTTP 414 URI Too Long cuando una
    // mesa acumula cientos de items (ej. cuentas a credito que arrastran
    // dias). 100 UUIDs por lote deja la URL bajo los ~8KB que PostgREST
    // acepta por default.
    const inChunkSize = 100;
    final grouped = <String, List<OrderItemTaxLine>>{};

    for (var i = 0; i < itemIds.length; i += inChunkSize) {
      final end = (i + inChunkSize > itemIds.length)
          ? itemIds.length
          : i + inChunkSize;
      final chunk = itemIds.sublist(i, end);

      final raw = await _client
          .from('order_item_tax_lines')
          .select(
            'id, order_item_id, tax_id, tax_name, tax_rate, amount, created_at',
          )
          .inFilter('order_item_id', chunk)
          .order('created_at', ascending: true);

      for (final row in (raw as List)) {
        final line = OrderItemTaxLine.fromMap(
          Map<String, dynamic>.from(row as Map),
        );
        grouped
            .putIfAbsent(line.orderItemId, () => <OrderItemTaxLine>[])
            .add(line);
      }
    }
    return grouped;
  }

  /// Trae los modifiers de un conjunto de items en lotes (igual que
  /// _loadTaxLinesByItem). Se usa cuando el bundle NO los embebe.
  Future<Map<String, List<OrderItemModifier>>> _loadModifiersByItem(
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty) return const {};

    const inChunkSize = 100;
    final grouped = <String, List<OrderItemModifier>>{};

    for (var i = 0; i < itemIds.length; i += inChunkSize) {
      final end = (i + inChunkSize > itemIds.length)
          ? itemIds.length
          : i + inChunkSize;
      final chunk = itemIds.sublist(i, end);

      final rawModifiers = await _client
          .from('order_item_modifiers')
          .select('id, item_id, name, qty, price')
          .inFilter('item_id', chunk)
          .order('id', ascending: true);

      for (final row in (rawModifiers as List)) {
        final modifier = OrderItemModifier.fromMap(
          Map<String, dynamic>.from(row as Map),
        );
        grouped
            .putIfAbsent(modifier.itemId, () => <OrderItemModifier>[])
            .add(modifier);
      }
    }
    return grouped;
  }

  /// Parsea los modifiers embebidos por el RPC en cada item del bundle
  /// (clave 'modifiers'). Devuelve const [] si no hay o el formato no aplica.
  List<OrderItemModifier> _parseEmbeddedModifiers(dynamic raw) {
    if (raw is! List || raw.isEmpty) return const <OrderItemModifier>[];
    return raw
        .whereType<Map>()
        .map((m) => OrderItemModifier.fromMap(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  /// Parsea las tax_lines embebidas por el RPC en cada item del bundle
  /// (clave 'tax_lines'). Devuelve const [] si no hay o el formato no aplica.
  List<OrderItemTaxLine> _parseEmbeddedTaxLines(dynamic raw) {
    if (raw is! List || raw.isEmpty) return const <OrderItemTaxLine>[];
    return raw
        .whereType<Map>()
        .map((t) => OrderItemTaxLine.fromMap(Map<String, dynamic>.from(t)))
        .toList(growable: false);
  }

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
      throw const OrderOutOfScopeException();
    }
  }

  Future<void> _assertSessionInBusinessScope(
    String sessionId, {
    String? businessId,
  }) async {
    final scopedBusinessId = businessId?.trim();
    if (scopedBusinessId == null || scopedBusinessId.isEmpty) return;

    final row = await _client
        .from('table_sessions')
        .select('id')
        .eq('id', sessionId)
        .eq('business_id', scopedBusinessId)
        .maybeSingle();

    if (row == null) {
      throw Exception('SESSION_OUT_OF_SCOPE');
    }
  }

  Future<void> _assertTableInBusinessScope(
    String tableId, {
    String? businessId,
  }) async {
    final scopedBusinessId = businessId?.trim();
    if (scopedBusinessId == null || scopedBusinessId.isEmpty) return;

    final row = await _client
        .from('dining_tables')
        .select('id, zones!inner(business_id)')
        .eq('id', tableId)
        .eq('zones.business_id', scopedBusinessId)
        .maybeSingle();

    if (row == null) {
      throw Exception('TABLE_OUT_OF_SCOPE');
    }
  }

  /// Anular un pago puntual. Si el pago corresponde a una subcuenta,
  /// reabre solamente ese check. Si es un pago full-order (check_id null) y
  /// hay otros payments completed en la misma orden — es decir, un split por
  /// múltiples métodos — sólo anula ESE pago y deja a la orden en
  /// partially_paid. Si es el único pago, mantiene la anulación total
  /// (annulOrder).
  Future<void> annulPayment({
    required String paymentId,
    required String orderId,
    String? checkId,
    String? reason,
  }) async {
    final trimmedPaymentId = paymentId.trim();
    final trimmedOrderId = orderId.trim();
    final trimmedCheckId = checkId?.trim();
    final hasCheck = trimmedCheckId != null && trimmedCheckId.isNotEmpty;

    if (trimmedPaymentId.isEmpty) {
      throw Exception('PAYMENT_ID_REQUIRED');
    }
    if (trimmedOrderId.isEmpty) {
      throw Exception('ORDER_ID_REQUIRED');
    }

    // Para pagos full-order: detectar split por métodos. Si no hay pagos
    // hermanos, mantener anulación total (legacy). Si hay hermanos, caer al
    // flujo de anulación parcial sin tocar items.
    if (!hasCheck) {
      final siblingsRaw = await _client
          .from('payments')
          .select('id')
          .eq('order_id', trimmedOrderId)
          .isFilter('check_id', null)
          .eq('status', 'completed')
          .neq('id', trimmedPaymentId);
      final hasSiblings = (siblingsRaw as List).isNotEmpty;
      if (!hasSiblings) {
        await annulOrder(orderId: trimmedOrderId, reason: reason);
        return;
      }
    }

    try {
      final paymentRaw = await _client
          .from('payments')
          .select(
            'id, order_id, check_id, payment_method_id, amount, change_amount, session_id, status',
          )
          .eq('id', trimmedPaymentId)
          .maybeSingle();

      if (paymentRaw == null) {
        throw Exception('PAYMENT_NOT_FOUND');
      }

      final payment = Map<String, dynamic>.from(paymentRaw);
      if ((payment['status']?.toString() ?? '') != 'completed') {
        return;
      }

      final orderRaw = await _client
          .from('orders')
          .select('session_id')
          .eq('id', trimmedOrderId)
          .maybeSingle();
      final orderSessionId = orderRaw?['session_id']?.toString();

      String? tableId;
      if (orderSessionId != null && orderSessionId.isNotEmpty) {
        final sessionRaw = await _client
            .from('table_sessions')
            .select('table_id')
            .eq('id', orderSessionId)
            .maybeSingle();
        tableId = sessionRaw?['table_id']?.toString();
      }

      String? paymentMethodCode;
      final paymentMethodId = payment['payment_method_id']?.toString();
      if (paymentMethodId != null && paymentMethodId.isNotEmpty) {
        final methodRaw = await _client
            .from('payment_methods')
            .select('code')
            .eq('id', paymentMethodId)
            .maybeSingle();
        paymentMethodCode = methodRaw?['code']?.toString();
      }

      await _client
          .from('payments')
          .update({'status': 'cancelled'})
          .eq('id', trimmedPaymentId);

      await _client
          .from('fiscal_documents')
          .update({'status': 'cancelled'})
          .eq('payment_id', trimmedPaymentId);

      // Reabrir items y check sólo para el flujo basado en checks. En split
      // full-order los items pertenecen a la orden entera (no a un check);
      // los dejamos como 'paid' — siguen asociados a los otros pagos del
      // split, y la orden vuelve a `partially_paid` para que el cajero
      // pueda registrar otro pago que cubra el monto anulado.
      if (hasCheck) {
        await _client
            .from('order_items')
            .update({'status': 'served'})
            .eq('order_id', trimmedOrderId)
            .eq('check_id', trimmedCheckId)
            .eq('status', 'paid');

        await _client
            .from('order_checks')
            .update({'is_closed': false, 'closed_at': null})
            .eq('id', trimmedCheckId);
      }

      await _client
          .from('orders')
          .update({'status_ext': 'partially_paid', 'closed_at': null})
          .eq('id', trimmedOrderId);

      if (orderSessionId != null && orderSessionId.isNotEmpty) {
        await _client
            .from('table_sessions')
            .update({'closed_at': null})
            .eq('id', orderSessionId);
      }

      if (tableId != null && tableId.isNotEmpty) {
        await _client
            .from('dining_tables')
            .update({'state': 'occupied'})
            .eq('id', tableId);
      }

      if (paymentMethodCode == 'cash') {
        final cashierSessionId = payment['session_id']?.toString();
        final netAmount = netPaymentAmount(
          payment['amount'],
          payment['change_amount'],
        );
        if (cashierSessionId != null &&
            cashierSessionId.isNotEmpty &&
            netAmount > 0) {
          await _client.from('cash_transactions').insert({
            'session_id': cashierSessionId,
            'amount': -netAmount,
            'type': 'sale',
            'description': 'Anulacion pago ${trimmedPaymentId.substring(0, 8)}',
            'related_order_id': trimmedOrderId,
          });
        }
      }
    } catch (e) {
      throw Exception('Error al anular pago: $e');
    }
  }

  // ============================================================
  // 📊 SESIONES DE MESA
  // ============================================================

  /// Abrir sesión de mesa (venta por mesa)
  Future<Map<String, dynamic>> openTable({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcOpenTable,
        params: {
          'p_people_count': peopleCount,
          'p_table_id': tableId,
          'p_user_id': userId,
          // Solo se manda si el modo multimesero está activo y el mesero
          // metió PIN. El RPC tiene este param con default null para
          // mantener backwards compat.
          'p_opened_by_employee_id': openedByEmployeeId,
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

  /// Abre/reanuda una mesa y retorna el bundle COMPLETO en un solo
  /// round-trip — combina `fn_open_table` + `fn_get_order_bundle` +
  /// modifiers + tax_lines, todo embebido en items. Reduce la apertura
  /// de mesa de 3-4 queries (~700ms) a 1 RPC (~21ms server, ~150ms
  /// total con network).
  ///
  /// Retorna `(orderId, bundle)` donde `bundle` tiene la misma forma
  /// que el de `getOrderBundle()` — order/items/checks/customer — pero
  /// con `modifiers` y `tax_lines` ya pegados en cada item.
  Future<
    ({
      String orderId,
      ({
        Order? order,
        List<OrderItem> items,
        List<OrderCheck> checks,
        String? customerId,
        String? customerName,
        String? note,
      }) bundle,
    })
  > openTableAndLoad({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async {
    final response = await _client.rpc(
      'fn_open_table_and_load',
      params: {
        'p_table_id': tableId,
        'p_user_id': userId,
        'p_people_count': peopleCount,
        'p_opened_by_employee_id': openedByEmployeeId,
      },
    );

    if (response == null) {
      throw Exception('No se pudo abrir la mesa');
    }

    final payload = Map<String, dynamic>.from(response as Map);
    final orderId = payload['order_id']?.toString();
    if (orderId == null || orderId.isEmpty) {
      throw Exception('fn_open_table_and_load no retornó order_id');
    }

    final bundleRaw = payload['bundle'];
    if (bundleRaw is! Map) {
      return (
        orderId: orderId,
        bundle: (
          order: null,
          items: const <OrderItem>[],
          checks: const <OrderCheck>[],
          customerId: null,
          customerName: null,
          note: null,
        ),
      );
    }

    final bundleMap = Map<String, dynamic>.from(bundleRaw);

    final orderMapRaw = bundleMap['order'];
    final order = orderMapRaw is Map
        ? Order.fromMap(Map<String, dynamic>.from(orderMapRaw))
        : null;

    // Items con modifiers + tax_lines embebidos por el RPC
    final itemsRaw = (bundleMap['items'] as List?) ?? const [];
    final items = <OrderItem>[];
    for (final row in itemsRaw) {
      if (row is! Map) continue;
      final itemMap = Map<String, dynamic>.from(row);

      final baseItem = OrderItem.fromMap(itemMap);

      // Parsear modifiers embebidos en el item
      final modsRaw = itemMap['modifiers'];
      final modifiers = <OrderItemModifier>[];
      if (modsRaw is List) {
        for (final m in modsRaw) {
          if (m is Map) {
            modifiers.add(
              OrderItemModifier.fromMap(Map<String, dynamic>.from(m)),
            );
          }
        }
      }

      // Parsear tax_lines embebidos
      final taxRaw = itemMap['tax_lines'];
      final taxLines = <OrderItemTaxLine>[];
      if (taxRaw is List) {
        for (final t in taxRaw) {
          if (t is Map) {
            taxLines.add(
              OrderItemTaxLine.fromMap(Map<String, dynamic>.from(t)),
            );
          }
        }
      }

      items.add(
        baseItem.copyWith(modifiers: modifiers, taxLines: taxLines),
      );
    }

    final checksRaw = (bundleMap['checks'] as List?) ?? const [];
    final checks = checksRaw
        .whereType<Map>()
        .map((m) => OrderCheck.fromMap(Map<String, dynamic>.from(m)))
        .toList(growable: false);

    return (
      orderId: orderId,
      bundle: (
        order: order,
        items: items,
        checks: checks,
        customerId: bundleMap['customer_id']?.toString(),
        customerName: bundleMap['customer_name']?.toString(),
        note: bundleMap['note']?.toString(),
      ),
    );
  }

  /// Abrir venta manual o rápida
  ///
  /// [businessId] es CRÍTICO para Owners multi-sucursal: el RPC ignora
  /// `activeBusinessId` del cliente y por defecto elegía siempre el negocio
  /// más antiguo del usuario, abriendo la orden en otro tenant. Pasarlo
  /// explícitamente fuerza al RPC a abrir la orden en la sucursal activa.
  /// Ver migración 20260526_0003_fix_open_manual_or_quick_business_scope.sql.
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin, // 'manual' o 'quick_sale'
    String? customerName,
    int peopleCount = 1,
    String? businessId,
  }) async {
    try {
      await _ensureVirtualTableForOrigin(origin);

      final response = await _client.rpc(
        SalesQueries.rpcOpenManualOrQuick,
        params: {
          'p_origin': origin,
          'p_people_count': peopleCount,
          'p_user_id': _client.auth.currentUser?.id,
          if (businessId != null && businessId.isNotEmpty)
            'p_business_id': businessId,
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

  /// Venta rápida persistente: devuelve el id de la orden `quick` ABIERTA del
  /// negocio (la mesa virtual de venta rápida es única por negocio), o null si
  /// no hay ninguna. Permite RETOMAR una venta no cobrada en vez de abrir una
  /// nueva (que anularía la previa). Best-effort: null ante cualquier fallo.
  /// Ver docs/PRD_DELIVERY_FEE_PROPIO.md (Feature C venta rápida).
  Future<String?> findOpenQuickOrderId(String businessId) async {
    try {
      final rows = await _client
          .from('orders')
          .select(
            'id, created_at, table_sessions!inner(business_id, origin, closed_at)',
          )
          .eq('status_ext', 'open')
          .eq('table_sessions.business_id', businessId)
          .inFilter('table_sessions.origin', ['quick', 'quick_sale'])
          .isFilter('table_sessions.closed_at', null)
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isNotEmpty) {
        final id = (rows.first as Map)['id'];
        return id is String && id.isNotEmpty ? id : null;
      }
      return null;
    } catch (e) {
      // No es fatal: si falla la consulta, el caller abre una venta nueva.
      return null;
    }
  }

  /// Retail: abre una venta rápida en una mesa virtual DEDICADA por carrito
  /// (`slot`), permitiendo varias ventas rápidas simultáneas sin que abrir una
  /// nueva anule las demás. A diferencia de [openManualOrQuick] (que comparte
  /// una sola mesa virtual 'quick' y cierra la sesión previa), cada slot tiene
  /// su propia mesa/sesión/orden. Idempotente por slot: reabrir el mismo slot
  /// devuelve su orden abierta.
  Future<Map<String, dynamic>> openRetailCart({
    required String slot,
    required String businessId,
    int peopleCount = 1,
  }) async {
    try {
      final response = await _client.rpc(
        'fn_open_retail_cart',
        params: {
          'p_business_id': businessId,
          'p_user_id': _client.auth.currentUser?.id,
          'p_slot': slot,
          'p_people_count': peopleCount,
        },
      );
      if (response == null) {
        throw Exception('No se pudo abrir la venta rápida');
      }
      return Map<String, dynamic>.from(response as Map);
    } catch (e) {
      throw Exception('Error al abrir venta rápida (retail): $e');
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

  /// Libera defensivamente una mesa si la orden ya no tiene productos vigentes.
  Future<bool> releaseEmptyTableIfNeeded(
    String orderId, {
    String? businessId,
  }) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      final orderRow = await _client
          .from('orders')
          .select('id, session_id, closed_at')
          .eq('id', orderId)
          .maybeSingle();
      if (orderRow == null) return false;

      final sessionId = orderRow['session_id']?.toString();
      if (sessionId == null || sessionId.isEmpty) return false;

      final liveItems = await _client
          .from('order_items')
          .select('id')
          .eq('order_id', orderId)
          .neq('status', 'void')
          .limit(1);
      if ((liveItems as List).isNotEmpty) {
        return false;
      }

      final sessionRow = await _client
          .from('table_sessions')
          .select('id, table_id, closed_at')
          .eq('id', sessionId)
          .maybeSingle();
      final tableId = sessionRow?['table_id']?.toString();

      await _client
          .from('orders')
          .update({
            'status_ext': 'void',
            'closed_at': DateTime.now().toIso8601String(),
          })
          .eq('id', orderId)
          .isFilter('closed_at', null);

      final otherOpenOrders = await _client
          .from('orders')
          .select('id')
          .eq('session_id', sessionId)
          .isFilter('closed_at', null)
          .not('status_ext', 'in', '(paid,void)')
          .limit(1);

      if ((otherOpenOrders as List).isEmpty) {
        await _client
            .from('table_sessions')
            .update({'closed_at': DateTime.now().toIso8601String()})
            .eq('id', sessionId)
            .isFilter('closed_at', null);

        if (tableId != null && tableId.isNotEmpty) {
          await _client
              .from('dining_tables')
              .update({'state': 'available'})
              .eq('id', tableId);
        }
      }

      return true;
    } catch (e) {
      throw Exception('Error al liberar mesa vacia: $e');
    }
  }

  Future<({String? customerId, String? customerName, String? note})>
  getSessionCustomer(String sessionId, {String? businessId}) async {
    try {
      await _assertSessionInBusinessScope(sessionId, businessId: businessId);

      var query = _client
          .from('table_sessions')
          .select('customer_id, customer_name, note')
          .eq('id', sessionId);

      final scopedBusinessId = businessId?.trim();
      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        query = query.eq('business_id', scopedBusinessId);
      }

      final data = await query.maybeSingle();

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
    String? businessId,
  }) async {
    try {
      await _assertSessionInBusinessScope(sessionId, businessId: businessId);

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
    String? businessId,
  }) async {
    try {
      await _assertSessionInBusinessScope(sessionId, businessId: businessId);

      var query = _client
          .from('table_sessions')
          .update({'note': note?.trim().isEmpty == true ? null : note?.trim()})
          .eq('id', sessionId);

      final scopedBusinessId = businessId?.trim();
      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        query = query.eq('business_id', scopedBusinessId);
      }

      await query;
    } catch (e) {
      throw Exception('Error al actualizar nota de la sesión: $e');
    }
  }

  /// Actualiza la dirección de entrega del pedido de delivery. Update
  /// directo sobre `table_sessions.delivery_address` (mismo molde que
  /// [updateSessionNote]). Opcional: una dirección vacía la deja en null.
  Future<void> updateDeliveryAddress({
    required String sessionId,
    String? address,
    String? businessId,
  }) async {
    try {
      await _assertSessionInBusinessScope(sessionId, businessId: businessId);

      var query = _client.from('table_sessions').update({
        'delivery_address':
            address?.trim().isEmpty == true ? null : address?.trim(),
      }).eq('id', sessionId);

      final scopedBusinessId = businessId?.trim();
      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        query = query.eq('business_id', scopedBusinessId);
      }

      await query;
    } catch (e) {
      throw Exception('Error al actualizar la dirección de entrega: $e');
    }
  }

  /// Lee la dirección de entrega guardada en la sesión (o null).
  Future<String?> getSessionDeliveryAddress(
    String sessionId, {
    String? businessId,
  }) async {
    final row = await _client
        .from('table_sessions')
        .select('delivery_address')
        .eq('id', sessionId)
        .maybeSingle();
    final value = row?['delivery_address'] as String?;
    return (value == null || value.trim().isEmpty) ? null : value.trim();
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
  /// Agrega una OFERTA como UNA línea a precio ORIGINAL (cantidad N) con el
  /// [discount] del deal en `discounts`, en UN viaje vía `fn_add_offer_deal`.
  /// Así el descuento se ve abajo en los totales. La línea lleva [DEAL:] (el
  /// motor la ignora) + promotion_id. Si la RPC no está aplicada
  /// (20260605_0005), inserta el producto y fija nombre/descuento con update
  /// directo (los triggers recomputan los totales).
  Future<void> addOfferDealItem({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    required double discount,
    required String name,
    String? promotionId,
    int checkPosition = 1,
  }) async {
    try {
      await _client.rpc(
        'fn_add_offer_deal',
        params: {
          'p_order_id': orderId,
          'p_menu_item_id': menuItemId,
          'p_qty': quantity,
          'p_discount': discount,
          'p_name': name,
          'p_promotion_id': promotionId,
          'p_check_position': checkPosition,
        },
      );
    } catch (_) {
      // Degradado SIN la RPC: insertar y fijar nombre + descuento + marcador.
      final id = await addItemFromMenu(
        orderId: orderId,
        menuItemId: menuItemId,
        quantity: quantity,
        checkPosition: checkPosition,
      );
      if (id.isEmpty) return;
      final marker = promotionId != null ? '[DEAL:$promotionId]' : '[DEAL:]';
      final payload = <String, dynamic>{
        'product_name': name,
        'discounts': discount,
        'notes': marker,
      };
      if (promotionId != null) payload['promotion_id'] = promotionId;
      try {
        await _client.from('order_items').update(payload).eq('id', id);
      } catch (_) {
        payload.remove('promotion_id');
        await _client.from('order_items').update(payload).eq('id', id);
      }
    }
  }

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

  Future<List<Map<String, dynamic>>> getComboGroupsForMenuItem(
    String menuItemId,
  ) async {
    try {
      final data = await _client
          .from('combo_groups')
          .select(
            'id, name, min_select, max_select, is_required, sort_order, combo_group_items(id, menu_item_id, price_delta, is_default, sort_order, menu_items(id, name, price, is_active))',
          )
          .eq('menu_item_id', menuItemId)
          .order('sort_order');
      return List<Map<String, dynamic>>.from(data as List);
    } catch (e) {
      throw Exception('Error al obtener grupos del combo: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getModifierGroupsForMenuItem(
    String menuItemId,
  ) async {
    try {
      // Orden personalizado por producto (menu_item_groups.position).
      // El cliente reordena los grupos desde el editor de producto.
      final data = await _client
          .from('menu_item_groups')
          .select(
            'group_id, position, modifier_groups!inner(id, name, min_select, max_select, is_active, display_type, selection_mode, is_required, free_qty, max_qty_per_option, sort_order, modifiers(id, group_id, name, price_delta, is_active, sort_order, default_selected))',
          )
          .eq('menu_item_id', menuItemId)
          .eq('modifier_groups.is_active', true)
          .order('position', ascending: true);

      final rows = List<Map<String, dynamic>>.from(
        data as List,
      ).map((row) => Map<String, dynamic>.from(row)).toList(growable: false);

      for (final row in rows) {
        final group = row['modifier_groups'];
        if (group is Map && group['modifiers'] is List) {
          final modifiers = List<dynamic>.from(group['modifiers'] as List);
          // Ordenar opciones por sort_order ascendente; si empate, por nombre.
          modifiers.sort((a, b) {
            final ao = a is Map ? (a['sort_order'] as num?)?.toInt() ?? 0 : 0;
            final bo = b is Map ? (b['sort_order'] as num?)?.toInt() ?? 0 : 0;
            if (ao != bo) return ao.compareTo(bo);
            final an =
                (a is Map ? a['name'] : '')?.toString().toLowerCase() ?? '';
            final bn =
                (b is Map ? b['name'] : '')?.toString().toLowerCase() ?? '';
            return an.compareTo(bn);
          });
          group['modifiers'] = modifiers;
        }
      }

      return rows;
    } catch (e) {
      throw Exception('Error al obtener modificadores del producto: $e');
    }
  }

  Future<void> addOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    if (modifiers.isEmpty) return;
    // Incluye menu_item_id (identidad del componente de combo) para que el
    // inventario pueda descontar cada componente. Si la columna aún no existe
    // (migración 20260605_0002 sin aplicar), reintenta sin ella para no romper
    // el guardado de modifiers — el combo se sigue vendiendo, solo sin descuento
    // de inventario por componente hasta que se aplique la migración.
    List<Map<String, dynamic>> rows({required bool withMenuItem}) => modifiers
        .map(
          (modifier) => {
            'item_id': itemId,
            'name': modifier['name'],
            'qty': modifier['qty'] ?? 1,
            'price': modifier['price'] ?? 0,
            if (withMenuItem && modifier['menu_item_id'] != null)
              'menu_item_id': modifier['menu_item_id'],
          },
        )
        .toList(growable: false);

    final hasComponentId = modifiers.any((m) => m['menu_item_id'] != null);
    try {
      await _client
          .from('order_item_modifiers')
          .insert(rows(withMenuItem: true));
    } catch (e) {
      if (!hasComponentId) {
        throw Exception('Error al guardar modificadores del item: $e');
      }
      try {
        await _client
            .from('order_item_modifiers')
            .insert(rows(withMenuItem: false));
      } catch (_) {
        throw Exception('Error al guardar modificadores del item: $e');
      }
    }
  }

  Future<void> replaceOrderItemModifiers({
    required String itemId,
    required List<Map<String, dynamic>> modifiers,
  }) async {
    try {
      await _client.from('order_item_modifiers').delete().eq('item_id', itemId);
      if (modifiers.isEmpty) return;
      await addOrderItemModifiers(itemId: itemId, modifiers: modifiers);
    } catch (e) {
      throw Exception('Error al reemplazar modificadores del item: $e');
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
        // Detectar ITEM_NOT_FOUND (P0001) del RPC y exponerlo limpio. Sin
        // esto, el fallback tira PGRST116 y la UI ve un mensaje opaco con
        // "result contains 0 rows" en vez de "el item ya no existe".
        if (rpcError.toString().contains('ITEM_NOT_FOUND')) {
          throw Exception('ITEM_NOT_FOUND');
        }
        // Fallback solo si el RPC fallo por otro motivo (ej. RPC no migrado).
        // IMPORTANTE: el UPDATE directo NO dispara el recompute de tax_rate
        // ni repuebla tax_lines (lo hace fn_update_item_details). Si
        // is_takeout cambió y este fallback se ejecuta, el order.service_fee
        // queda stale — el cliente seguiría viendo el 10% de propina aunque
        // ya marcó takeout. Para mitigar, leemos el is_takeout previo y
        // si cambió, después del UPDATE invocamos manualmente
        // fn_toggle_item_takeout, que sí re-resuelve tax_rate + repuebla
        // tax_lines + recalcula totals (existe desde 20260502_0002).
        bool? previousIsTakeout;
        try {
          final prev = await _client
              .from('order_items')
              .select('is_takeout')
              .eq('id', itemId)
              .maybeSingle();
          previousIsTakeout = prev?['is_takeout'] as bool?;
        } catch (_) {
          // No bloqueamos el fallback si la lectura previa falla — el
          // problema mínimo es que NO disparamos la recompute auxiliar.
        }
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
          throw Exception('ITEM_NOT_FOUND');
        }
        // Si is_takeout cambió, disparar el toggle dedicado para
        // re-resolver tax_rate y repoblar tax_lines + recalc totals.
        // Es idempotente — flipea al mismo valor.
        if (previousIsTakeout != null && previousIsTakeout != isTakeout) {
          try {
            await toggleItemTakeout(itemId: itemId, isTakeout: isTakeout);
          } catch (e) {
            // Última línea de defensa: si toggle también falla, registramos
            // pero no rompemos el flow — el UPDATE básico ya se hizo.
            // ignore: avoid_print
            print(
              '[updateItemDetails fallback] toggleItemTakeout failed: $e',
            );
          }
        }
        await updateItemDiscountAndNotes(
          itemId: itemId,
          discounts: discounts,
          notes: notes,
        );
      }
    } catch (e) {
      final raw = e.toString();
      if (raw.contains('ITEM_NOT_FOUND') || raw.contains('PGRST116')) {
        throw Exception(
          'El producto ya no existe en la orden. Refresca la mesa para ver '
          'el estado actual.',
        );
      }
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
  /// Actualiza descuento + notas de una línea.
  ///
  /// Cuando [writePromotion] es true, además escribe la atribución estructurada
  /// `order_items.promotion_id` ([promotionId], o null al limpiar la promo) vía
  /// la RPC de 4 args (migración 20260605_0001). Si esa RPC aún no está aplicada,
  /// degrada al path legacy de 3 args (solo discount+notes) para NO romper la
  /// aplicación del descuento — la atribución por marcador en `notes` sigue
  /// funcionando hasta que la migración se aplique. Los callers no-promo
  /// (cortesía, descuento manual) dejan [writePromotion] en false y conservan el
  /// comportamiento exacto previo.
  Future<void> updateItemDiscountAndNotes({
    required String itemId,
    required double discounts,
    String? notes,
    bool writePromotion = false,
    String? promotionId,
  }) async {
    if (writePromotion) {
      try {
        await _client.rpc(
          SalesQueries.rpcUpdateItemDiscountAndNotes,
          params: {
            'p_item_id': itemId,
            'p_discounts': discounts,
            'p_notes': notes,
            'p_promotion_id': promotionId,
          },
        );
        return;
      } catch (_) {
        // RPC de 4 args no disponible aún (migración 20260605_0001 sin aplicar).
        // Caemos al path legacy para no bloquear el descuento de la promo.
      }
    }
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
  Future<Order?> getOrder(String orderId, {String? businessId}) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      final data = await _client
          .from('orders')
          .select()
          .eq('id', orderId)
          .maybeSingle();

      if (data == null) return null;

      return Order.fromMap(data);
    } on OrderOutOfScopeException {
      return null;
    } catch (e) {
      throw Exception('Error al obtener orden: $e');
    }
  }

  /// True si alguna fila del bundle trae qty no entera. Sirve para disparar
  /// el consolidate lazy (Fase 0 Toast redesign).
  bool _orderBundleHasFractionalQty(dynamic response) {
    if (response is! Map) return false;
    final items = (response['items'] as List?) ?? const [];
    for (final row in items) {
      if (row is! Map) continue;
      final raw = row['qty'] ?? row['quantity'];
      if (raw == null) continue;
      final qty = raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (qty == null) continue;
      if ((qty - qty.roundToDouble()).abs() > 0.001) {
        return true;
      }
    }
    return false;
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
      String? note,
    })
  >
  getOrderBundle(String orderId, {String? businessId}) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      var response = await _client.rpc(
        SalesQueries.rpcGetOrderBundle,
        params: {'p_order_id': orderId},
      );

      // Fase 0 del rediseño Toast: si la orden trae filas con qty fraccional
      // heredadas del legacy fn_split_items_equally, las consolidamos a
      // entero on-the-fly y recargamos. Es idempotente: la RPC vuelve a 0
      // filas tocadas en órdenes ya limpias, por lo que el costo es 1 RPC
      // extra sólo en órdenes afectadas.
      if (_orderBundleHasFractionalQty(response)) {
        try {
          await _client.rpc(
            SalesQueries.rpcConsolidateOrderToInteger,
            params: {'p_order_id': orderId},
          );
          response = await _client.rpc(
            SalesQueries.rpcGetOrderBundle,
            params: {'p_order_id': orderId},
          );
        } catch (_) {
          // Si el consolidate falla (DB sin la migration, permisos, etc.),
          // seguimos con la data fraccional original — la UI ya la tolera.
        }
      }

      if (response == null) {
        return (
          order: null,
          items: const <OrderItem>[],
          checks: const <OrderCheck>[],
          customerId: null,
          customerName: null,
          note: null,
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
      final itemMaps = itemsRaw
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);

      // Camino rápido: si el RPC (fn_get_order_bundle ≥ 20260605_0008) ya
      // embebió modifiers/tax_lines en cada item, abrir/recargar el pedido es
      // 1 solo viaje — los parseamos del propio item sin consultas extra.
      final hasEmbeddedRelations =
          itemMaps.isNotEmpty && itemMaps.first.containsKey('tax_lines');

      List<OrderItem> items;
      if (hasEmbeddedRelations) {
        items = itemMaps.map((itemMap) {
          return OrderItem.fromMap(itemMap).copyWith(
            modifiers: _parseEmbeddedModifiers(itemMap['modifiers']),
            taxLines: _parseEmbeddedTaxLines(itemMap['tax_lines']),
          );
        }).toList(growable: false);
      } else {
        // Retrocompat: DB sin la migración del embed → traemos modifiers y
        // tax_lines en lotes (ver _loadTaxLinesByItem) para evitar HTTP 414.
        final baseItems = itemMaps
            .map(OrderItem.fromMap)
            .toList(growable: false);

        final itemIds = baseItems
            .map((item) => item.id)
            .where((id) => id.isNotEmpty)
            .toList(growable: false);

        Map<String, List<OrderItemModifier>> modifiersByItem = const {};
        Map<String, List<OrderItemTaxLine>> taxLinesByItem = const {};
        if (itemIds.isNotEmpty) {
          // modifiers y tax_lines en paralelo (independientes).
          final relations = await Future.wait([
            _loadModifiersByItem(itemIds),
            _loadTaxLinesByItem(itemIds),
          ]);
          modifiersByItem =
              relations[0] as Map<String, List<OrderItemModifier>>;
          taxLinesByItem = relations[1] as Map<String, List<OrderItemTaxLine>>;
        }

        items = baseItems
            .map(
              (item) => item.copyWith(
                modifiers:
                    modifiersByItem[item.id] ?? const <OrderItemModifier>[],
                taxLines:
                    taxLinesByItem[item.id] ?? const <OrderItemTaxLine>[],
              ),
            )
            .toList(growable: false);
      }

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
        note: payload['note']?.toString(),
      );
    } on OrderOutOfScopeException {
      return (
        order: null,
        items: const <OrderItem>[],
        checks: const <OrderCheck>[],
        customerId: null,
        customerName: null,
        note: null,
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
    String? businessId,
  }) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      // Defensa en profundidad: si onlyOpen, validar que la orden padre
      // esté abierta. Esto evita devolver items huérfanos de órdenes
      // void/paid cuyos items no se marcaron correctamente.
      if (onlyOpen) {
        final parent = await _client
            .from('orders')
            .select('closed_at,status_ext')
            .eq('id', orderId)
            .maybeSingle();
        final closedAt = parent?['closed_at'];
        final statusExt = parent?['status_ext']?.toString();
        if (closedAt != null ||
            statusExt == 'void' ||
            statusExt == 'paid' ||
            statusExt == 'cancelled') {
          return const <OrderItem>[];
        }
      }

      var query = _client
          .from('order_items')
          .select(_itemFields)
          .eq('order_id', orderId);

      if (onlyOpen) {
        query = query.not('status', 'in', '(paid,void)');
      }

      final data = await query
          .order('created_at', ascending: true)
          .limit(limit);
      final items = data
          .map(
            (json) => OrderItem.fromMap(Map<String, dynamic>.from(json as Map)),
          )
          .toList(growable: false);

      if (!includeModifiers || items.isEmpty) {
        return items;
      }

      final itemIds = items
          .map((item) => item.id)
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      if (itemIds.isEmpty) {
        return items;
      }

      // modifiers y tax_lines son independientes → en paralelo (1 viaje en
      // vez de 2 en serie). Cada uno se trae en lotes (ver _loadTaxLinesByItem).
      final relations = await Future.wait([
        _loadModifiersByItem(itemIds),
        _loadTaxLinesByItem(itemIds),
      ]);
      final modifiersByItem =
          relations[0] as Map<String, List<OrderItemModifier>>;
      final taxLinesByItem =
          relations[1] as Map<String, List<OrderItemTaxLine>>;

      return items
          .map(
            (item) => item.copyWith(
              modifiers:
                  modifiersByItem[item.id] ?? const <OrderItemModifier>[],
              taxLines: taxLinesByItem[item.id] ?? const <OrderItemTaxLine>[],
            ),
          )
          .toList(growable: false);
    } on OrderOutOfScopeException {
      return const <OrderItem>[];
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

  /// Asigna (o limpia) el cliente y el tipo de comprobante a una sub-cuenta
  /// antes de que se cobre. Al pagar el check, el RPC `fn_process_payment_v3`
  /// hereda estos valores automáticamente si el modal de pago no los pisa.
  ///
  /// Pasa `customerId=null` y `customerRnc=null` para limpiar el cliente.
  /// Pasa `requestedNcfType=null` para volver al default del business.
  Future<OrderCheck> setCheckCustomerAndNcf({
    required String checkId,
    String? customerId,
    String? customerRnc,
    String? requestedNcfType,
  }) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcSetCheckCustomerAndNcf,
        params: {
          'p_check_id': checkId,
          'p_customer_id': customerId,
          'p_customer_rnc': customerRnc,
          'p_requested_ncf_type': requestedNcfType,
        },
      );

      if (response is Map) {
        return OrderCheck.fromMap(Map<String, dynamic>.from(response));
      }
      throw Exception('Respuesta inválida del RPC setCheckCustomerAndNcf');
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('CHECK_NOT_FOUND')) {
        throw Exception('La sub-cuenta ya no existe.');
      }
      if (msg.contains('CHECK_ALREADY_CLOSED')) {
        throw Exception(
          'La sub-cuenta ya fue cobrada y no se puede modificar.',
        );
      }
      throw Exception(
        'Error al asignar cliente/comprobante a la sub-cuenta: $e',
      );
    }
  }

  /// Eliminar un check y sus items
  /// Cierra (soft-close) un sub-check si quedó sin items abiertos. Pensado
  /// para llamarse tras un delete de item: si fue el último, el check se
  /// marca `is_closed=true` para que la UI no lo siga mostrando.
  /// No toca el principal (position=1). Idempotente: si el check ya está
  /// cerrado o no existe, devuelve false sin error.
  Future<bool> closeEmptyCheckIfApplicable(String checkId) async {
    try {
      final check = await _client
          .from('order_checks')
          .select('id, position, is_closed, order_id')
          .eq('id', checkId)
          .maybeSingle();
      if (check == null) return false;
      final position = (check['position'] as num?)?.toInt() ?? 0;
      if (position <= 1) return false;
      if (check['is_closed'] == true) return false;

      final remainingRaw = await _client
          .from('order_items')
          .select('id')
          .eq('check_id', checkId)
          .not('status', 'in', '("paid","void")');
      final remaining = (remainingRaw as List).length;
      if (remaining > 0) return false;

      await _client
          .from('order_checks')
          .update({
            'is_closed': true,
            'closed_at': DateTime.now().toIso8601String(),
          })
          .eq('id', checkId);
      return true;
    } catch (_) {
      return false;
    }
  }

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
  Future<Map<String, dynamic>?> getTableLive(
    String tableId, {
    String? businessId,
  }) async {
    try {
      await _assertTableInBusinessScope(tableId, businessId: businessId);

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

  /// Feature flag: cuando `kitchen_enabled = false`, los items se
  /// marcan directamente como `ready` sin pasar por cocina. Para
  /// negocios sin preparación (tiendas, kioskos, minimarkets).
  ///
  /// Update directo sobre order_items (sin RPC) porque
  /// fn_confirm_order_to_kitchen genera print_jobs de comanda, que es
  /// justo lo que queremos saltarnos.
  Future<void> markOrderItemsAsReady(String orderId) async {
    try {
      await _client
          .from('order_items')
          .update({'status': 'ready'})
          .eq('order_id', orderId)
          .inFilter('status', ['draft', 'pending', 'preparing']);
      // El status_ext de la orden lo gestionan otros triggers según el
      // flujo de pago — no lo tocamos acá para no romper checks/payments.
    } catch (e) {
      throw Exception('Error al marcar items como listos: $e');
    }
  }

  /// Fee de delivery propio (cargo EXENTO): fija `orders.delivery_fee` y
  /// recomputa el total en backend. El monto se redondea/clampa a ≥0 dentro
  /// del RPC. Ver docs/PRD_DELIVERY_FEE_PROPIO.md.
  Future<void> setDeliveryFee({
    required String orderId,
    required double amount,
  }) async {
    try {
      await _client.rpc(
        SalesQueries.rpcSetDeliveryFee,
        params: {'p_order_id': orderId, 'p_amount': amount},
      );
    } catch (e) {
      throw Exception('Error al fijar el fee de delivery: $e');
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

  /// Split bill UX (2026-05-13) — divide cada item abierto con qty>1 en
  /// N filas de qty=1 para que cada unidad sea transferible
  /// independientemente en el modal de dividir cuenta. Idempotente: si
  /// todos los items ya están en qty=1, es no-op.
  ///
  /// Retorna el número de filas nuevas creadas (qty original - 1 por
  /// cada item explotado). 0 = no había nada que dividir.
  Future<int> explodeItemsToUnits({required String orderId}) async {
    try {
      final response = await _client.rpc(
        SalesQueries.rpcExplodeItemsToUnits,
        params: {'p_order_id': orderId},
      );
      if (response == null) return 0;
      return (response as num).toInt();
    } catch (e) {
      throw Exception('Error al dividir productos en unidades: $e');
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
  Future<void> consolidateCheckItems({
    required String checkId,
    bool normalizeQtyToInteger = false,
  }) async {
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

      // Chunking inFilter (ver _loadTaxLinesByItem) — protege contra 414.
      const inChunkSize = 100;
      final itemIdsWithMods = <String>{};
      for (var i = 0; i < itemIds.length; i += inChunkSize) {
        final end = (i + inChunkSize > itemIds.length)
            ? itemIds.length
            : i + inChunkSize;
        final chunk = itemIds.sublist(i, end);

        final rawMods = await _client
            .from('order_item_modifiers')
            .select('item_id')
            .inFilter('item_id', chunk);
        for (final m in (rawMods as List)) {
          final id = (m as Map)['item_id']?.toString();
          if (id != null) itemIdsWithMods.add(id);
        }
      }

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

        final normalizedQty = normalizeQtyToInteger
            ? sumQty.roundToDouble()
            : sumQty;

        // RPC atómica: UPDATE keeper + DELETE duplicados + refresh tax_lines
        // en una sola transacción Postgres. Reemplaza el patrón previo de
        // dos llamadas separadas que podía perder items si el UPDATE fallaba
        // silenciosamente y el DELETE corría igual.
        await _client.rpc(
          'fn_consolidate_keeper_atomic',
          params: {
            'p_keeper_id': keeperId,
            'p_remove_ids': removeIds,
            'p_sum_qty': normalizedQty,
            'p_sum_discounts': sumDiscounts,
          },
        );
      }
    } catch (e) {
      throw Exception('Error al consolidar items de subcuenta: $e');
    }
  }

  Future<void> assignCustomerToCheck({
    required String checkId,
    required String customerId,
    required String customerName,
    String? customerRnc,
  }) async {
    try {
      // El RNC se persiste por sub-cuenta (order_checks.customer_rnc) para
      // que `fn_process_payment_v3` lo herede al cobrar el check (param > check
      // > default). Necesario para emitir Crédito Fiscal por sub-cuenta.
      final rnc = customerRnc?.trim();
      await _client
          .from('order_checks')
          .update({
            'customer_id': customerId,
            'customer_name': customerName.trim(),
            'customer_rnc': (rnc == null || rnc.isEmpty) ? null : rnc,
          })
          .eq('id', checkId);
    } catch (e) {
      throw Exception('Error al asignar cliente al check: $e');
    }
  }

  Future<void> clearCustomerFromCheck(String checkId) async {
    try {
      await _client
          .from('order_checks')
          .update({
            'customer_id': null,
            'customer_name': null,
            'customer_rnc': null,
          })
          .eq('id', checkId);
    } catch (e) {
      throw Exception('Error al limpiar cliente del check: $e');
    }
  }

  /// Asigna el tipo de comprobante a una sub-cuenta. Al pagar ese check, el
  /// RPC `fn_process_payment_v3` hereda este tipo si el modal de pago no lo
  /// sobrescribe. Pasa `ncfType=null` para volver al default del business.
  Future<void> setCheckNcfType({
    required String checkId,
    String? ncfType,
  }) async {
    try {
      final normalized = ncfType?.trim();
      await _client
          .from('order_checks')
          .update({
            'requested_ncf_type': (normalized == null || normalized.isEmpty)
                ? null
                : normalized,
          })
          .eq('id', checkId);
    } catch (e) {
      throw Exception('Error al asignar comprobante al check: $e');
    }
  }

  /// Obtener checks de una orden
  Future<List<OrderCheck>> getOrderChecks(
    String orderId, {
    String? businessId,
  }) async {
    try {
      await _assertOrderInBusinessScope(orderId, businessId: businessId);

      final data = await _client
          .from('order_checks')
          .select()
          .eq('order_id', orderId)
          .order('position', ascending: true);

      return data.map((json) => OrderCheck.fromMap(json)).toList();
    } on OrderOutOfScopeException {
      return const <OrderCheck>[];
    } catch (e) {
      throw Exception('Error al obtener checks: $e');
    }
  }

  // ============================================================
  // 💰 PAGOS
  // ============================================================

  /// Procesar pago
  ///
  /// `splitSequence` distingue múltiples pagos del mismo método sobre la
  /// misma orden/check (caso: tres clientes pagando 1000 cash cada uno
  /// en una orden compartida). El cliente Dart pasa 0, 1, 2... para cada
  /// split intencional; double-tap reusa el mismo valor y choca contra el
  /// unique index. Default 0 mantiene compatibilidad con callers que sólo
  /// emiten un payment por (order, check, method).
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
    DateTime? paidAt,
    // F4: NCF asignado offline (Hub/allocator). Solo se envía al sincronizar
    // un cobro offline que YA imprimió su comprobante; el RPC lo usa en vez de
    // generar uno nuevo. Null en cobros online (el servidor emite el NCF).
    String? offlineNcf,
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
          if (paidAt != null) 'p_paid_at': paidAt.toUtc().toIso8601String(),
          if (offlineNcf != null && offlineNcf.isNotEmpty)
            'p_offline_ncf': offlineNcf,
        },
      );

      return Payment.fromMap(response as Map<String, dynamic>);
    } catch (e) {
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

      // Recovery cuando el unique index bloquea un retry idempotente del
      // mismo split: (order_id, check_id, payment_method_id, split_sequence)
      // ya existe completed. El RPC propaga 23505 — el cliente lo recupera
      // devolviendo la fila previa, como si el insert hubiera sido exitoso.
      // Caso típico: doble-tap del usuario o retry por timeout de red.
      final isUniqueViolation =
          (e is PostgrestException && e.code == '23505') ||
          msg.contains('23505') ||
          msg.contains('payments_unique_completed_per_check_method');
      if (isUniqueViolation) {
        final recovered = await _recoverCompletedPaymentAfterUniqueViolation(
          orderId: orderId,
          checkId: checkId,
          splitSequence: splitSequence,
          amount: amount,
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

  Future<Payment?> _recoverCompletedPaymentAfterUniqueViolation({
    required String orderId,
    String? checkId,
    required int splitSequence,
    required double amount,
  }) async {
    try {
      dynamic query = _client
          .from('payments')
          .select()
          .eq('order_id', orderId)
          .eq('status', 'completed')
          .eq('split_sequence', splitSequence);

      query = checkId == null
          ? query.isFilter('check_id', null)
          : query.eq('check_id', checkId);

      final rows = await query.order('created_at', ascending: false).limit(5);

      for (final row in rows) {
        final payment = Payment.fromMap(Map<String, dynamic>.from(row as Map));
        if ((payment.amount - amount).abs() <= 0.01) {
          return payment;
        }
      }
    } catch (_) {}

    return null;
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

  /// Obtener documento fiscal por ID
  Future<FiscalDocument?> getFiscalDocumentById(String documentId) async {
    try {
      final data = await _client
          .from('fiscal_documents')
          .select()
          .eq('id', documentId)
          .maybeSingle();

      if (data == null) return null;

      return FiscalDocument.fromMap(data);
    } catch (e) {
      throw Exception('Error al obtener documento fiscal por ID: $e');
    }
  }

  /// Anular orden y sus pagos
  Future<void> annulOrder({required String orderId, String? reason}) async {
    try {
      // 1. Obtener pagos asociados
      final paymentsRaw = await _client
          .from('payments')
          .select('id, amount, session_id')
          .eq('order_id', orderId)
          .eq('status', 'completed');

      final payments = List<Map<String, dynamic>>.from(paymentsRaw);

      // 2. Anular la orden mediante RPC (cierra orden, sesión y libera mesa)
      await _client.rpc(
        SalesQueries.rpcCloseOrderAndTable,
        params: {'p_order_id': orderId, 'p_status': 'void'},
      );

      // 3. Anular todos los ítems de la orden (Reportes usan 'void')
      await _client
          .from('order_items')
          .update({'status': 'void'})
          .eq('order_id', orderId);

      // 4. Anular pagos asociados
      // Nota: La restricción de tabla 'payments_status_check' no acepta 'void',
      // pero sí acepta 'cancelled'.
      if (payments.isNotEmpty) {
        final paymentIds = payments.map((p) => p['id'] as String).toList();
        await _client
            .from('payments')
            .update({'status': 'cancelled'})
            .inFilter('id', paymentIds);
      }

      // 5. Anular Documentos Fiscales asociados
      await _client
          .from('fiscal_documents')
          .update({'status': 'cancelled'})
          .eq('order_id', orderId);
    } catch (e) {
      throw Exception('Error al anular orden: $e');
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

  /// Agrega una línea de auditoría de anulación a la nota de la sesión de
  /// [orderId]. Resuelve la sesión de la orden, lee la nota actual y le
  /// appendea `[ANULACION][stamp] actor: razón` (mismo formato que el flujo
  /// online en SalesViewModel.appendVoidAuditNote).
  ///
  /// Lo usa el replay offline de `void_order` para persistir la razón que
  /// en v1 solo quedaba en logs (gap F2.3). Best-effort: el caller no debe
  /// romper la anulación si esto falla.
  Future<void> appendVoidAuditNote({
    required String orderId,
    required String reason,
    String? userName,
    DateTime? voidedAt,
    String? businessId,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) return;

    final orderRow = await _client
        .from('orders')
        .select('session_id')
        .eq('id', orderId)
        .maybeSingle();
    final sessionId = orderRow?['session_id']?.toString();
    if (sessionId == null || sessionId.isEmpty) return;

    final sessionRow = await _client
        .from('table_sessions')
        .select('note')
        .eq('id', sessionId)
        .maybeSingle();
    final current = (sessionRow?['note']?.toString() ?? '').trim();

    final stamp = (voidedAt ?? DateTime.now()).toLocal().toIso8601String();
    final actor = (userName == null || userName.trim().isEmpty)
        ? 'Usuario'
        : userName.trim();
    final auditLine = '[ANULACION][$stamp] $actor: $trimmed';
    final nextNote = current.isEmpty ? auditLine : '$current\n$auditLine';

    await updateSessionNote(
      sessionId: sessionId,
      note: nextNote,
      businessId: businessId,
    );
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

  // ============================================================
  // 🚚 DELIVERY
  // ============================================================

  Future<Map<String, dynamic>> openDeliveryOrder({
    required String deliveryType,
    int peopleCount = 1,
  }) async {
    final response = await _client.rpc(
      SalesQueries.rpcOpenDeliveryOrder,
      params: {
        'p_user_id': _client.auth.currentUser?.id,
        'p_delivery_type': deliveryType,
        'p_people_count': peopleCount,
      },
    );
    if (response == null) {
      throw Exception('No se pudo crear orden de delivery');
    }
    return Map<String, dynamic>.from(response as Map);
  }

  Future<List<Map<String, dynamic>>> listDeliveryOrders({
    required String businessId,
  }) async {
    final response = await _client.rpc(
      SalesQueries.rpcListDeliveryOrders,
      params: {'p_business_id': businessId},
    );
    return List<Map<String, dynamic>>.from(response as List);
  }

  Future<void> closeDeliveryOrder({
    required String orderId,
    String status = 'paid',
  }) async {
    await _client.rpc(
      SalesQueries.rpcCloseDeliveryOrder,
      params: {'p_order_id': orderId, 'p_status': status},
    );
  }

  // ===========================================================================
  // Dashboard — widgets agregados (Top productos, recientes)
  // ===========================================================================

  /// Top N productos más vendidos por cantidad, en el período dado.
  /// Suma `order_items.quantity` por `product_id`, ordena descendente.
  ///
  /// Devuelve filas con: `product_id`, `product_name`, `image_url`,
  /// `total_quantity`, `total_amount`. NULL `product_id` (= productos
  /// borrados) se filtran fuera porque ya no se pueden mostrar como item.
  ///
  /// Scope: respeta business_id vía join orders → table_sessions → zones.
  /// Status filter: solo cuenta items de órdenes 'paid'/'sent'/'served'
  /// — excluye drafts y canceladas.
  Future<List<Map<String, dynamic>>> getTopSellingProducts({
    required String businessId,
    required DateTime from,
    required DateTime to,
    int limit = 3,
  }) async {
    // Query DIRECTA (sin el RPC fn_dashboard_top_selling_products, que no está
    // desplegado en todos los entornos). Agrega las líneas de venta del rango
    // por producto y devuelve el top-N por cantidad. La imagen sale de
    // menu_items (solo para los ids del top, batch pequeño).
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final itemRows = List<Map<String, dynamic>>.from(
      await _client
          .from('order_items')
          .select('product_id,product_name,qty,quantity,subtotal,discounts,status')
          .eq('business_id', businessId)
          .neq('status', 'void')
          .gte('created_at', fromIso)
          .lt('created_at', toIso)
          .limit(100000),
    );

    double asDouble(Object? v) => (v as num?)?.toDouble() ?? 0;

    final agg = <String, Map<String, dynamic>>{};
    for (final row in itemRows) {
      final productId = row['product_id']?.toString();
      if (productId == null || productId.isEmpty) continue;
      final qtyRaw = asDouble(row['qty']);
      final qty = qtyRaw != 0 ? qtyRaw : asDouble(row['quantity']);
      final amount = asDouble(row['subtotal']) - asDouble(row['discounts']);
      final bucket = agg.putIfAbsent(
        productId,
        () => <String, dynamic>{
          'product_id': productId,
          'product_name': row['product_name']?.toString() ?? 'Producto',
          'total_quantity': 0.0,
          'total_amount': 0.0,
        },
      );
      bucket['total_quantity'] = (bucket['total_quantity'] as double) + qty;
      bucket['total_amount'] = (bucket['total_amount'] as double) + amount;
    }

    final ranked = agg.values.toList()
      ..sort((a, b) => (b['total_quantity'] as double)
          .compareTo(a['total_quantity'] as double));
    final top = ranked.take(limit).toList(growable: false);
    if (top.isEmpty) return const [];

    // Imagen/nombre vigente desde menu_items para los productos del top.
    final ids = top.map((e) => e['product_id'] as String).toList();
    final menuRows = List<Map<String, dynamic>>.from(
      await _client
          .from('menu_items')
          .select('id,name,image_url')
          .inFilter('id', ids),
    );
    final meta = <String, Map<String, dynamic>>{
      for (final row in menuRows)
        if (row['id'] != null) row['id'].toString(): row,
    };

    return top.map((row) {
      final m = meta[row['product_id']];
      final menuName = m?['name']?.toString().trim();
      return <String, dynamic>{
        'product_id': row['product_id'],
        'product_name': (menuName != null && menuName.isNotEmpty)
            ? menuName
            : row['product_name'],
        'image_url': m?['image_url'],
        'total_quantity': row['total_quantity'],
        'total_amount': row['total_amount'],
      };
    }).toList(growable: false);
  }

  /// Últimas N órdenes del business para el panel "Recent Orders" del
  /// dashboard. Devuelve resumen ligero: id, número visible, customer_name,
  /// total, status, created_at, items_summary (string corto con 1-2 items).
  ///
  /// Ordenado por `created_at` DESC. Por default trae las últimas 10.
  Future<List<Map<String, dynamic>>> getRecentOrders({
    required String businessId,
    int limit = 10,
  }) async {
    final response = await _client.rpc(
      'fn_dashboard_recent_orders',
      params: {
        '_business_id': businessId,
        '_limit': limit,
      },
    );
    if (response == null) return const [];
    return List<Map<String, dynamic>>.from(response as List);
  }

  /// KPIs del "Order Summary" del dashboard: HOY vs AYER (mismo tramo
  /// del día). Devuelve hasta 2 filas — el caller las arma con
  /// [DashboardKpis.fromRpcRows].
  Future<List<Map<String, dynamic>>> getDashboardKpis({
    required String businessId,
    required DateTime todayFrom,
    required DateTime todayTo,
    required DateTime yesterdayFrom,
    required DateTime yesterdayTo,
  }) async {
    // Implementación con queries DIRECTAS (sin el RPC fn_dashboard_kpis).
    // Motivos:
    //   - El RPC scopeaba por COALESCE(zones.business_id, table_sessions.
    //     business_id); cuando esos venían NULL el dashboard mostraba 0 aunque
    //     SÍ hubiera órdenes. Aquí scopeamos por `orders.business_id` (poblado
    //     y misma fuente que get_sales_summary_v2 → los números concilian).
    //   - El RPC comparaba status_ext contra el vocabulario viejo del campo
    //     `status` ('sent'/'served'/'canceled'); el enum real es
    //     open/sent_to_kitchen/partially_paid/paid/void. Aquí usamos el correcto.
    //   - Ingreso = dinero cobrado (payments.amount - change_amount), robusto
    //     frente a orders.total = 0 en cuentas divididas.
    final lowerIso = AppTime.astToUtcIso(yesterdayFrom);
    final upperIso = AppTime.astToUtcIso(todayTo);

    // Límites como instantes UTC para clasificar cada fila por período. Las dos
    // ventanas (hoy / ayer, mismo tramo del día) no son contiguas: se sobre-pide
    // el hueco intermedio y cada fila se ubica con su created_at exacto.
    final tFrom = DateTime.parse(AppTime.astToUtcIso(todayFrom)).toUtc();
    final tTo = DateTime.parse(AppTime.astToUtcIso(todayTo)).toUtc();
    final yFrom = DateTime.parse(AppTime.astToUtcIso(yesterdayFrom)).toUtc();
    final yTo = DateTime.parse(AppTime.astToUtcIso(yesterdayTo)).toUtc();

    String? periodOf(Object? createdAtRaw) {
      final ts = DateTime.tryParse(createdAtRaw?.toString() ?? '')?.toUtc();
      if (ts == null) return null;
      if (!ts.isBefore(tFrom) && ts.isBefore(tTo)) return 'today';
      if (!ts.isBefore(yFrom) && ts.isBefore(yTo)) return 'yesterday';
      return null;
    }

    double asDouble(Object? v) => (v as num?)?.toDouble() ?? 0;

    final income = <String, double>{'today': 0, 'yesterday': 0};
    final ordersTotal = <String, int>{'today': 0, 'yesterday': 0};
    final ordersInProgress = <String, int>{'today': 0, 'yesterday': 0};
    final ordersCompleted = <String, int>{'today': 0, 'yesterday': 0};
    final itemsSold = <String, double>{'today': 0, 'yesterday': 0};

    // 1. Ingresos = pagos cobrados (misma fórmula que ventas/caja).
    final paymentRows = List<Map<String, dynamic>>.from(
      await _client
          .from('payments')
          .select('created_at,amount,change_amount,status')
          .eq('business_id', businessId)
          .gte('created_at', lowerIso)
          .lt('created_at', upperIso)
          .limit(50000),
    );
    for (final row in paymentRows) {
      final status = row['status']?.toString();
      if (status != null && status != 'completed') continue;
      final period = periodOf(row['created_at']);
      if (period == null) continue;
      income[period] =
          income[period]! + (asDouble(row['amount']) - asDouble(row['change_amount']));
    }

    // 2. Órdenes: total (no void), en curso y completadas. Vocabulario del
    //    enum order_status real.
    const inProgress = {'open', 'sent_to_kitchen', 'partially_paid'};
    final orderRows = List<Map<String, dynamic>>.from(
      await _client
          .from('orders')
          .select('created_at,status_ext')
          .eq('business_id', businessId)
          .gte('created_at', lowerIso)
          .lt('created_at', upperIso)
          .limit(50000),
    );
    for (final row in orderRows) {
      final period = periodOf(row['created_at']);
      if (period == null) continue;
      final status = row['status_ext']?.toString() ?? 'open';
      if (status == 'void') continue;
      ordersTotal[period] = ordersTotal[period]! + 1;
      if (inProgress.contains(status)) {
        ordersInProgress[period] = ordersInProgress[period]! + 1;
      } else if (status == 'paid') {
        ordersCompleted[period] = ordersCompleted[period]! + 1;
      }
    }

    // 3. Items vendidos (líneas no anuladas).
    final itemRows = List<Map<String, dynamic>>.from(
      await _client
          .from('order_items')
          .select('created_at,qty,quantity,status')
          .eq('business_id', businessId)
          .neq('status', 'void')
          .gte('created_at', lowerIso)
          .lt('created_at', upperIso)
          .limit(100000),
    );
    for (final row in itemRows) {
      final period = periodOf(row['created_at']);
      if (period == null) continue;
      final qtyRaw = asDouble(row['qty']);
      itemsSold[period] =
          itemsSold[period]! + (qtyRaw != 0 ? qtyRaw : asDouble(row['quantity']));
    }

    return [
      for (final period in const ['today', 'yesterday'])
        {
          'period': period,
          'income': income[period],
          'orders_total': ordersTotal[period],
          'orders_in_progress': ordersInProgress[period],
          'orders_completed': ordersCompleted[period],
          'items_sold': itemsSold[period],
        },
    ];
  }
}
