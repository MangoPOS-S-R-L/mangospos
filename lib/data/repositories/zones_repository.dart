import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/zone.dart';
import '../models/table_status.dart';
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
          .select('session_id,subtotal,tax,service_fee,discounts,total')
          .inFilter('session_id', sessionIds)
          .isFilter('closed_at', null)
          .not('status_ext', 'in', '(paid,void)');

      final orderRows = List<Map<String, dynamic>>.from(await orderTotalsQuery);
      final totalBySessionId = <String, double>{};
      for (final order in orderRows) {
        final sessionId = order['session_id']?.toString().trim();
        if (sessionId == null || sessionId.isEmpty) continue;
        final total = (order['total'] as num?)?.toDouble() ?? 0.0;
        final subtotal = (order['subtotal'] as num?)?.toDouble() ?? 0.0;
        final tax = (order['tax'] as num?)?.toDouble() ?? 0.0;
        final serviceFee = (order['service_fee'] as num?)?.toDouble() ?? 0.0;
        final discounts = (order['discounts'] as num?)?.toDouble() ?? 0.0;
        final rebuiltTotal = _roundMoney(
          (subtotal + tax + serviceFee - discounts).clamp(0, double.infinity),
        );
        final effectiveTotal = total >= rebuiltTotal ? total : rebuiltTotal;
        totalBySessionId[sessionId] = _roundMoney(
          (totalBySessionId[sessionId] ?? 0.0) + effectiveTotal,
        );
      }

      for (final row in rows) {
        final sessionId = row['session_id']?.toString().trim();
        if (sessionId == null || sessionId.isEmpty) continue;
        if (!totalBySessionId.containsKey(sessionId)) continue;
        row['total'] = totalBySessionId[sessionId]!;
      }
    }

    return rows.map(TableStatus.fromMap).toList();
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
        table: 'dining_tables',
        callback: (_) => onChange(),
      )
      ..subscribe();
    return ch;
  }
}
