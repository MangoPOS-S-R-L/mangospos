import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';

import '../models/order_item_tax_line.dart';
import '../models/sales_models.dart';
import '../models/zone.dart';
import '../models/table_status.dart';
import '../models/dining_table.dart';
import '../utils/order_pricing_utils.dart';

class ZonesRepository {
  final SupabaseClient sb;
  ZonesRepository(this.sb);

  double _roundMoney(double value) => double.parse(value.toStringAsFixed(2));

  // ---- ZONAS ----
  Future<List<Zone>> fetchZones(
    String businessId, {
    bool includeVirtualSalesZones = false,
    bool includeInactive = false,
  }) async {
    var query = sb
        .from('zones')
        .select('id,business_id,name,sort_index,is_active,created_at')
        .eq('business_id', businessId);

    if (!includeInactive) {
      query = query.eq('is_active', true);
    }

    final rows = await query
        .order('sort_index', ascending: true)
        .order('name', ascending: true);

    final zones = (rows as List)
        .map((e) => Zone.fromMap(e as Map<String, dynamic>))
        .toList();

    if (includeVirtualSalesZones) {
      return zones;
    }

    return zones.where((zone) => !_isVirtualSalesZone(zone)).toList();
  }

  bool _isVirtualSalesZone(Zone zone) {
    if (zone.sortIndex != 900 && zone.sortIndex != 901) {
      return false;
    }

    final normalizedName = _normalizeZoneName(zone.name);
    return normalizedName == 'ventas manuales' ||
        normalizedName == 'ventas rapidas';
  }

  String _normalizeZoneName(String value) {
    final buffer = StringBuffer();
    for (final rune in value.trim().toLowerCase().runes) {
      switch (rune) {
        case 225:
          buffer.write('a');
          break;
        case 233:
          buffer.write('e');
          break;
        case 237:
          buffer.write('i');
          break;
        case 243:
          buffer.write('o');
          break;
        case 250:
        case 252:
          buffer.write('u');
          break;
        case 241:
          buffer.write('n');
          break;
        default:
          buffer.writeCharCode(rune);
      }
    }

    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ');
  }

  // ---- ESTADO POR ZONA (vista para pantalla "Por zona") ----
  Future<List<TableStatus>> fetchByZone(
    String zoneId, {
    String? businessId,
  }) async {
    var query = sb.from('v_zone_table_status').select().eq('zone_id', zoneId);

    final scopedBusinessId = businessId?.trim();
    if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
      query = query.eq('business_id', scopedBusinessId);
    }

    final rows = List<Map<String, dynamic>>.from(
      await query.order('code', ascending: true),
    );

    final currentUserId = sb.auth.currentUser?.id;
    final waiterUserIds = rows
        .map((row) => row['waiter_user_id']?.toString().trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final openedByIds = rows
        .map((row) => row['opened_by']?.toString().trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final profileIds = {...waiterUserIds, ...openedByIds}.toList(growable: false);

    final displayNameByUserId = <String, String>{};
    if (profileIds.isNotEmpty) {
      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        final employeeRows = List<Map<String, dynamic>>.from(
          await sb
              .from('v_employees_summary')
              .select('user_id, first_name')
              .eq('business_id', scopedBusinessId)
              .inFilter('user_id', profileIds),
        );
        for (final employee in employeeRows) {
          final userId = employee['user_id']?.toString().trim();
          final firstName = employee['first_name']?.toString().trim();
          if (userId == null || userId.isEmpty) continue;
          if (firstName == null || firstName.isEmpty) continue;
          displayNameByUserId[userId] = preferredDisplayName(firstName: firstName);
        }
      }

      final missingProfileIds = profileIds
          .where((id) => !displayNameByUserId.containsKey(id))
          .toList(growable: false);
      if (missingProfileIds.isNotEmpty) {
        final profileRows = List<Map<String, dynamic>>.from(
          await sb
              .from('profiles')
              .select('id, full_name')
              .inFilter('id', missingProfileIds),
        );
        for (final profile in profileRows) {
          final id = profile['id']?.toString().trim();
          final fullName = profile['full_name']?.toString().trim();
          if (id == null || id.isEmpty) continue;
          if (fullName == null || fullName.isEmpty) continue;
          displayNameByUserId[id] = preferredDisplayName(fullName: fullName);
        }
      }
    }

    for (final row in rows) {
      final waiterUserId = row['waiter_user_id']?.toString().trim();
      final openedBy = row['opened_by']?.toString().trim();
      final ownerUserId = (waiterUserId != null && waiterUserId.isNotEmpty)
          ? waiterUserId
          : ((openedBy != null && openedBy.isNotEmpty) ? openedBy : null);
      if (ownerUserId != null && ownerUserId.isNotEmpty) {
        row['waiter_name'] =
            displayNameByUserId[ownerUserId] ??
            preferredDisplayName(fullName: row['waiter_name']?.toString());
        row['is_own'] = currentUserId != null && currentUserId == ownerUserId;
      } else {
        row['is_own'] = false;
      }
    }

    final sessionIds = rows
        .map((row) => row['session_id']?.toString().trim())
        .whereType<String>()
        .where((sessionId) => sessionId.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final missingCustomerSessionIds = rows
        .where(
          (row) =>
              (row['customer_name']?.toString().trim().isEmpty ?? true) &&
              (row['session_id']?.toString().trim().isNotEmpty ?? false),
        )
        .map((row) => row['session_id'].toString())
        .toSet()
        .toList(growable: false);

    if (missingCustomerSessionIds.isNotEmpty) {
      var sessionQuery = sb
          .from('table_sessions')
          .select('id, customer_name')
          .inFilter('id', missingCustomerSessionIds);

      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        sessionQuery = sessionQuery.eq('business_id', scopedBusinessId);
      }

      final sessionRows = List<Map<String, dynamic>>.from(await sessionQuery);

      final customerBySessionId = <String, String>{};
      for (final session in sessionRows) {
        final sessionId = session['id']?.toString();
        final customerName = session['customer_name']?.toString().trim();
        if (sessionId == null || sessionId.isEmpty) continue;
        if (customerName == null || customerName.isEmpty) continue;
        customerBySessionId[sessionId] = customerName;
      }

      for (final row in rows) {
        final sessionId = row['session_id']?.toString();
        if (sessionId == null || sessionId.isEmpty) continue;
        row['customer_name'] ??= customerBySessionId[sessionId];
        if ((row['customer_name']?.toString().trim().isEmpty ?? true) &&
            customerBySessionId.containsKey(sessionId)) {
          row['customer_name'] = customerBySessionId[sessionId];
        }
      }
    }

    if (sessionIds.isNotEmpty) {
      var orderTotalsQuery = sb
          .from('orders')
          .select(
            'id,session_id,status_ext,subtotal,tax,service_fee,discounts,total,created_at,closed_at',
          )
          .inFilter('session_id', sessionIds)
          .isFilter('closed_at', null)
          .not('status_ext', 'in', '(paid,void)');

      final orderRows = List<Map<String, dynamic>>.from(await orderTotalsQuery);
      final orderIds = orderRows
          .map((order) => order['id']?.toString().trim())
          .whereType<String>()
          .where((orderId) => orderId.isNotEmpty)
          .toList(growable: false);
      final totalBySessionId = <String, double>{};
      final sessionIdByOrderId = <String, String>{};
      final ordersById = <String, Order>{};

      for (final order in orderRows) {
        final orderId = order['id']?.toString().trim();
        final sessionId = order['session_id']?.toString().trim();
        if (orderId == null || orderId.isEmpty) continue;
        if (sessionId == null || sessionId.isEmpty) continue;

        sessionIdByOrderId[orderId] = sessionId;
        // PRD 2 fix (2026-05-13): forzar serviceFee=0 igual que hace
        // sales_viewmodel.dart:415. El "10% De Ley" vive en
        // `oi.tax_lines` per ítem, así que `orders.service_fee` cached
        // (calculado por triggers backend que a veces aplican 10% sobre
        // subtotal completo aunque solo algunos items lo paguen) genera
        // double-counting si se suma aparte. El detail screen lo
        // ignoraba, el zone view no — por eso la card mostraba ~10%
        // de más vs la pantalla de la mesa.
        ordersById[orderId] =
            Order.fromMap(order).copyWith(serviceFee: 0);
      }

      // Use items to calculate the real total using our harmonized logic.
      // This ensures inclusive pricing is respected and matches the order screen.
      //
      // Excluimos 'paid' y 'void': los items pagados ya no representan deuda
      // pendiente de la mesa. Si la mesa tenía dos productos de 275 y el
      // cajero cobró uno via split bill (item → status='paid'), la card
      // debe mostrar 275 (lo que queda por cobrar), no 550. Sin este
      // filtro, items paid seguían sumando al total mostrado fuera de la
      // mesa, creando la ilusión de un "lag" (en realidad era data stale).
      final itemsMap = <String, List<OrderItem>>{};

      final itemsRows = await sb
          .from('order_items')
          .select()
          .inFilter('order_id', orderIds)
          .not('status', 'in', '(paid,void)') as List;

      final itemIds = itemsRows.map((r) => r['id'] as String).toList();
      final modifiersMap = <String, List<OrderItemModifier>>{};
      // PRD 6: cargar también tax_lines (snapshot per-tax filtrado por
      // takeout/origin) para que summarizeOrderPricing prefiera esa fuente
      // sobre `oi.tax` que puede estar stale tras un toggle. Sin esto, el
      // total del card de mesa quedaba inconsistente con la pantalla del
      // pedido (afuera mostraba 64, adentro 59).
      final taxLinesMap = <String, List<OrderItemTaxLine>>{};

      if (itemIds.isNotEmpty) {
        final modsRows = await sb
            .from('order_item_modifiers')
            .select()
            .inFilter('item_id', itemIds) as List;

        for (final row in modsRows) {
          final itemId = row['item_id'] as String;
          final mod = OrderItemModifier.fromMap(row);
          modifiersMap[itemId] = [...(modifiersMap[itemId] ?? []), mod];
        }

        final taxLinesRows = await sb
            .from('order_item_tax_lines')
            .select(
              'id, order_item_id, tax_id, tax_name, tax_rate, amount, created_at',
            )
            .inFilter('order_item_id', itemIds) as List;
        for (final row in taxLinesRows) {
          final line = OrderItemTaxLine.fromMap(
            Map<String, dynamic>.from(row as Map),
          );
          taxLinesMap
              .putIfAbsent(line.orderItemId, () => <OrderItemTaxLine>[])
              .add(line);
        }
      }

      for (final row in itemsRows) {
        final orderId = row['order_id'] as String;
        final itemId = row['id'] as String;
        final item = OrderItem.fromMap(row).copyWith(
          modifiers: modifiersMap[itemId] ?? [],
          taxLines: taxLinesMap[itemId] ?? const <OrderItemTaxLine>[],
        );
        itemsMap[orderId] = [...(itemsMap[orderId] ?? []), item];
      }

      for (final orderId in orderIds) {
        final sessionId = sessionIdByOrderId[orderId];
        if (sessionId == null || sessionId.isEmpty) continue;
        final order = ordersById[orderId];
        final items = itemsMap[orderId] ?? [];

        // FIX 2026-05-01: usar summary.total directamente — ahora se
        // ancla al gross catálogo para órdenes 100% inclusive (limpio,
        // sin drift de centavos ni doble-cuenta de serviceFee legacy).
        final summary = summarizeOrderPricing(
          order,
          items,
          forcedOrigin: 'table',
        );

        totalBySessionId[sessionId] = _roundMoney(
          (totalBySessionId[sessionId] ?? 0.0) + summary.total,
        );
      }

      for (final row in rows) {
        final sessionId = row['session_id']?.toString().trim();
        if (sessionId == null || sessionId.isEmpty) continue;
        row['total'] = totalBySessionId[sessionId] ?? 0.0;
      }
    }

    return rows.map(TableStatus.fromMap).toList();
  }

  /// Detects and releases stale tables: sessions with no open orders that
  /// were left occupied (e.g. due to partial cleanup failures).
  /// Returns the number of tables released.
  Future<int> releaseStaleTablesInZone(
    String zoneId, {
    String? businessId,
  }) async {
    try {
      // Find open sessions in this zone that have 0 open orders.
      var query = sb
          .from('v_zone_table_status')
          .select('table_id, session_id, orders_count')
          .eq('zone_id', zoneId)
          .not('session_id', 'is', null);

      final scopedBusinessId = businessId?.trim();
      if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
        query = query.eq('business_id', scopedBusinessId);
      }

      final rows = List<Map<String, dynamic>>.from(await query);

      // Filter: session exists but 0 open orders = stale
      final staleRows = rows.where((r) {
        final count = r['orders_count'];
        return count == null || count == 0;
      }).toList(growable: false);

      if (staleRows.isEmpty) return 0;

      int released = 0;
      for (final row in staleRows) {
        final sessionId = row['session_id']?.toString();
        final tableId = row['table_id']?.toString();
        if (sessionId == null || sessionId.isEmpty) continue;

        // Close the orphan session
        await sb
            .from('table_sessions')
            .update({'closed_at': DateTime.now().toIso8601String()})
            .eq('id', sessionId)
            .isFilter('closed_at', null);

        // Mark table as available
        if (tableId != null && tableId.isNotEmpty) {
          await sb
              .from('dining_tables')
              .update({'state': 'available'})
              .eq('id', tableId);
        }

        released++;
      }

      return released;
    } catch (_) {
      return 0;
    }
  }

  // ---- MESAS POR ZONA (para Ajustes → Salones y mesas) ----
  Future<List<DiningTable>> fetchTablesByZone(
    String zoneId, {
    bool includeInactive = false,
  }) async {
    var query = sb
        .from('dining_tables')
        .select(
          'id, zone_id, code, label, shape, capacity, '
          'pos_x, pos_y, width, height, rotation, '
          'state, is_active, created_at',
        )
        .eq('zone_id', zoneId);

    if (!includeInactive) {
      query = query.eq('is_active', true);
    }

    final rows = await query.order('code', ascending: true);

    return (rows as List)
        .map((e) => DiningTable.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  /// PRD-12 F1: cambia la zona de una mesa sin tocar sesiones ni
  /// órdenes. Backend valida same-business y permisos admin via la
  /// función `fn_move_table_to_zone` (security definer, manual RBAC
  /// check). Devuelve true si se movió, false si la mesa ya estaba
  /// en la zona destino (no-op silencioso).
  Future<bool> moveTableToZone({
    required String tableId,
    required String targetZoneId,
  }) async {
    final res = await sb.rpc(
      'fn_move_table_to_zone',
      params: {
        'p_table_id': tableId,
        'p_target_zone_id': targetZoneId,
      },
    );
    if (res is Map) {
      return res['moved'] == true;
    }
    return true;
  }

  /// PRD-12 F2: transfiere una sesión completa o items específicos a
  /// otra mesa via `fn_transfer_table_session`. Si destino tiene
  /// sesión abierta, combina automático. PIN supervisor se valida
  /// client-side ANTES de invocar este método.
  ///
  /// - `itemIds = null` → transfiere TODA la cuenta.
  /// - `itemIds = []` o lista → mueve solo esos items, manteniendo el
  ///   resto en la mesa origen.
  ///
  /// Devuelve el `Map` crudo del RPC (mode, source_*, target_*, etc.)
  /// para que el caller pueda mostrar feedback específico.
  Future<Map<String, dynamic>> transferTableSession({
    required String sourceSessionId,
    required String targetTableId,
    List<String>? itemIds,
  }) async {
    final res = await sb.rpc(
      'fn_transfer_table_session',
      params: {
        'p_source_session_id': sourceSessionId,
        'p_target_table_id': targetTableId,
        'p_item_ids': itemIds,
      },
    );
    if (res is Map) {
      return Map<String, dynamic>.from(res);
    }
    return <String, dynamic>{};
  }

  /// PRD-12 F3: devuelve el `id` de la sesión abierta de una mesa
  /// (sin closed_at). Si no hay ninguna abierta, devuelve null. Usado
  /// por el flow de "Unir mesas" desde el grid: el cajero hace
  /// long-press en una mesa ocupada y necesitamos su session_id antes
  /// de invocar `fn_transfer_table_session`.
  Future<String?> fetchActiveSessionId(String tableId) async {
    final row = await sb
        .from('table_sessions')
        .select('id')
        .eq('table_id', tableId)
        .isFilter('closed_at', null)
        .order('opened_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return row?['id']?.toString();
  }

  /// Lista todas las mesas activas de un negocio (todas las zonas)
  /// junto con el estado actual y la zona a la que pertenecen. Usado
  /// por el dialog de transferencia para que el cajero elija destino.
  /// Excluye la mesa origen y zonas inactivas.
  Future<List<Map<String, dynamic>>> fetchTablesForTransfer({
    required String businessId,
    required String excludeTableId,
  }) async {
    final rows = await sb
        .from('dining_tables')
        .select(
          'id, code, label, capacity, state, zone_id, '
          'zones!inner(id, name, business_id, is_active)',
        )
        .neq('id', excludeTableId)
        .eq('is_active', true)
        .eq('zones.business_id', businessId)
        .eq('zones.is_active', true);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  // ---- Realtime usado en la pantalla "Por zona" ----
  RealtimeChannel subscribe(void Function() onChange) {
    final ch = sb.channel('zones:status')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'table_sessions',
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'orders',
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'order_items',
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'order_checks',
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'payments',
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'dining_tables',
        callback: (_) => onChange(),
      )
      ..subscribe();
    return ch;
  }
}
