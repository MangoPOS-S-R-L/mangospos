import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/tax/tax_engine.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';

import '../models/sales_models.dart';
import '../models/zone.dart';
import '../models/table_status.dart';
import '../utils/order_pricing_utils.dart';
import '../models/dining_table.dart'; // ⬅️ importa el modelo de mesas

class ZonesRepository {
  final SupabaseClient sb;
  ZonesRepository(this.sb);

  double _roundMoney(double value) => double.parse(value.toStringAsFixed(2));

  // ---- ZONAS ----
  Future<List<Zone>> fetchZones(
    String businessId, {
    bool includeVirtualSalesZones = false,
  }) async {
    final rows = await sb
        .from('zones')
        .select('id,business_id,name,sort_index,is_active,created_at')
        .eq('business_id', businessId)
        .eq('is_active', true)
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
        ordersById[orderId] = Order.fromMap(order);
      }

      if (orderIds.isNotEmpty) {
        final itemRows = List<Map<String, dynamic>>.from(
          await sb
              .from('order_items')
              .select(
                'id,order_id,product_id,product_name,sku,qty,quantity,unit_price,subtotal,discounts,tax,total,check_id,is_takeout,status,notes,tax_mode,tax_rate,original_tax_rate,created_at',
              )
              .inFilter('order_id', orderIds)
              .not('status', 'in', '(paid,void)'),
        );

        final checkRows = List<Map<String, dynamic>>.from(
          await sb
              .from('order_checks')
              .select('id,order_id,is_closed')
              .inFilter('order_id', orderIds),
        );

        final itemsByOrderId = <String, List<OrderItem>>{};
        final closedCheckIdsByOrderId = <String, Set<String>>{};

        for (final itemRow in itemRows) {
          final item = OrderItem.fromMap(itemRow);
          final orderId = item.orderId.trim();
          if (orderId.isEmpty) continue;
          itemsByOrderId.putIfAbsent(orderId, () => <OrderItem>[]).add(item);
        }

        for (final checkRow in checkRows) {
          final checkId = checkRow['id']?.toString().trim();
          final orderId = checkRow['order_id']?.toString().trim();
          if (orderId == null || orderId.isEmpty) continue;
          if (checkRow['is_closed'] != true) continue;
          if (checkId == null || checkId.isEmpty) continue;
          closedCheckIdsByOrderId
              .putIfAbsent(orderId, () => <String>{})
              .add(checkId);
        }

        for (final orderId in orderIds) {
          final sessionId = sessionIdByOrderId[orderId];
          if (sessionId == null || sessionId.isEmpty) continue;
          final order = ordersById[orderId];
          if (order == null) continue;
          final closedCheckIds =
              closedCheckIdsByOrderId[orderId] ?? const <String>{};
          final pendingItems = (itemsByOrderId[orderId] ?? const <OrderItem>[])
              .where((item) => !closedCheckIds.contains(item.checkId))
              .toList(growable: false);

          final pendingTotal = summarizeOrderPricing(order, pendingItems).total;
          totalBySessionId[sessionId] = _roundMoney(
            (totalBySessionId[sessionId] ?? 0.0) + pendingTotal,
          );
        }
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
  Future<List<DiningTable>> fetchTablesByZone(String zoneId) async {
    final rows = await sb
        .from('dining_tables')
        .select(
          'id, zone_id, code, label, shape, capacity, '
          'pos_x, pos_y, width, height, rotation, '
          'state, is_active, created_at',
        )
        .eq('zone_id', zoneId)
        .eq('is_active', true)
        .order('code', ascending: true);

    return (rows as List)
        .map((e) => DiningTable.fromMap(e as Map<String, dynamic>))
        .toList();
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
