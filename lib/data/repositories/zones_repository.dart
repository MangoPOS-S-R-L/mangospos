import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/zone.dart';
import '../models/table_status.dart';
import '../models/dining_table.dart'; // ⬅️ importa el modelo de mesas

class ZonesRepository {
  final SupabaseClient sb;
  ZonesRepository(this.sb);

  // ---- ZONAS ----
  Future<List<Zone>> fetchZones(String businessId) async {
    final rows = await sb
        .from('zones')
        .select('id,business_id,name,sort_index,is_active,created_at')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('sort_index', ascending: true)
        .order('name', ascending: true);

    return (rows as List)
        .map((e) => Zone.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  // ---- ESTADO POR ZONA (vista para pantalla "Por zona") ----
  Future<List<TableStatus>> fetchByZone(String zoneId) async {
    final rows = await sb
        .from('v_zone_table_status')
        .select(
          'table_id,zone_id,code,session_id,orders_count,minutes_open,items_count,total,people_count',
        )
        .eq('zone_id', zoneId)
        .order('code');

    return (rows as List)
        .map((e) => TableStatus.fromMap(e as Map<String, dynamic>))
        .toList();
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
