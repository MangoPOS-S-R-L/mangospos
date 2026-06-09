import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/offline/zones_offline_cache.dart';

import '../models/zone.dart';
import '../models/table_status.dart';
import '../models/dining_table.dart';

class ZonesRepository {
  final SupabaseClient sb;
  ZonesRepository(this.sb);

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

    final rowsList = (rows as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);

    // Persistir el conjunto crudo (sin filtros de virtuales / activos) en el
    // cache offline. El wrapper [fetchZonesWithCache] lo usa como fallback
    // cuando Supabase es inalcanzable.
    unawaited(ZonesOfflineCache().saveZonesSnapshot(
      businessId: businessId,
      zonesRaw: rowsList,
    ));

    final zones = rowsList.map(Zone.fromMap).toList();

    if (includeVirtualSalesZones) {
      return zones;
    }

    return zones.where((zone) => !_isVirtualSalesZone(zone)).toList();
  }

  /// Variante de [fetchZones] con fallback al cache offline. Devuelve el
  /// timestamp del snapshot cuando los datos vienen del cache, para que el
  /// ViewModel pueda renderizar un banner "modo offline".
  ///
  /// Usa los defaults de [fetchZones] (sin virtuales, solo activas). Esos
  /// son los unicos parametros que la vista "Por zona" necesita.
  Future<({List<Zone> zones, bool fromCache, DateTime? cachedAt})>
      fetchZonesWithCache(String businessId) async {
    try {
      final zones = await fetchZones(businessId);
      return (zones: zones, fromCache: false, cachedAt: null);
    } catch (_) {
      final snap = await ZonesOfflineCache().loadZonesSnapshot(
        businessId: businessId,
      );
      if (snap == null) rethrow;
      final zones = snap.zones
          .where((m) => (m['is_active'] ?? true) == true)
          .map(Zone.fromMap)
          .where((z) => !_isVirtualSalesZone(z))
          .toList();
      return (zones: zones, fromCache: true, cachedAt: snap.savedAt);
    }
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

    // PERF (20260605_0007): la vista v_zone_table_status ya trae total,
    // waiter_name, is_own y customer_name resueltos en el servidor → la
    // carga de la zona es UNA sola consulta (antes ~10 viajes encadenados).

    // Persistir filas enriquecidas (con waiter_name / customer_name / total
    // calculado) para el cache offline. fetchByZoneWithCache las reusa.
    unawaited(ZonesOfflineCache().saveZoneStatusSnapshot(
      zoneId: zoneId,
      rowsRaw: rows,
    ));

    return rows.map(TableStatus.fromMap).toList();
  }

  /// Variante de [fetchByZone] con fallback al cache offline. Devuelve un
  /// flag + timestamp cuando los datos vienen del cache para que la vista
  /// pueda mostrar el banner "modo offline".
  ///
  /// Importante: los datos del cache pueden estar stale — sesiones abiertas
  /// en otro terminal mientras estabamos offline no se reflejan hasta que
  /// el internet vuelva y se llame de nuevo a este metodo.
  Future<({List<TableStatus> rows, bool fromCache, DateTime? cachedAt})>
      fetchByZoneWithCache(
    String zoneId, {
    String? businessId,
  }) async {
    try {
      final rows = await fetchByZone(zoneId, businessId: businessId);
      return (rows: rows, fromCache: false, cachedAt: null);
    } catch (_) {
      final snap = await ZonesOfflineCache().loadZoneStatusSnapshot(
        zoneId: zoneId,
      );
      if (snap == null) rethrow;
      final rows = snap.rows.map(TableStatus.fromMap).toList();
      return (rows: rows, fromCache: true, cachedAt: snap.savedAt);
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

  /// Floor map: persiste los campos de layout de UNA mesa (posición,
  /// tamaño, rotación, forma, capacidad, label). Reusa
  /// [DiningTable.toUpdateLayoutMap] — NO toca `state` ni sesiones, así
  /// que es seguro llamarlo aunque la mesa esté ocupada (solo cambia su
  /// representación visual en el plano).
  Future<void> updateTableLayout(DiningTable table) async {
    await sb
        .from('dining_tables')
        .update(table.toUpdateLayoutMap())
        .eq('id', table.id);
  }

  /// Floor map: persiste el layout de varias mesas en serie. Usado por
  /// "Guardar diseño" después de arrastrar/editar mesas en el editor.
  ///
  /// Updates secuenciales (igual que `reorderZones`): Supabase no soporta
  /// batch update por id distinto en una sola llamada. Best-effort por
  /// mesa — si una falla, propaga para que el caller muestre el error.
  Future<void> bulkUpdateLayout(List<DiningTable> tables) async {
    for (final t in tables) {
      await sb
          .from('dining_tables')
          .update(t.toUpdateLayoutMap())
          .eq('id', t.id);
    }
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

  /// Marca la sesión como "precuenta impresa" para que la mesa aparezca
  /// azul en la vista por zonas. Best-effort: no propaga errores —
  /// la impresión ya ocurrió, el visual es solo un nice-to-have. La
  /// columna `precheck_printed_at` la consume `v_zone_table_status`
  /// para devolver `status='paying'` mientras la sesión siga abierta.
  /// Se resetea solo al cerrar la sesión (via `closed_at`).
  Future<void> markPrecheckPrinted(String sessionId) async {
    if (sessionId.isEmpty) {
      // ignore: avoid_print
      print('[ZonesRepo] markPrecheckPrinted SKIP — sessionId vacio');
      return;
    }
    try {
      // ignore: avoid_print
      print('[ZonesRepo] markPrecheckPrinted START sessionId=$sessionId');
      final result = await sb
          .from('table_sessions')
          .update({
            'precheck_printed_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', sessionId)
          .select('id');
      // ignore: avoid_print
      print('[ZonesRepo] markPrecheckPrinted OK rows=${result.length} '
          'sessionId=$sessionId');
    } catch (e) {
      // No relanzamos: la mesa simplemente seguirá en naranja, pero
      // la precuenta ya salió en papel — el flujo principal no debe
      // romperse por un visual.
      // ignore: avoid_print
      print('[ZonesRepo] markPrecheckPrinted FAIL sessionId=$sessionId: $e');
    }
  }

  /// Barrido de mesas fantasma acotado al negocio: cierra órdenes/sesiones
  /// vacías y viejas (> [graceMinutes]) y libera la mesa, vía
  /// `fn_release_empty_tables`. Red de seguridad para cuando la limpieza al
  /// salir falló (crash/recarga/red). Solo toca casos seguros (sin items
  /// pendientes); las mesas con productos nunca se tocan. Best-effort: el
  /// caller lo envuelve en try/catch + unawaited.
  Future<void> releaseEmptyTables(
    String businessId, {
    int graceMinutes = 15,
  }) async {
    await sb.rpc(
      'fn_release_empty_tables',
      params: {
        'p_older_than_minutes': graceMinutes,
        'p_business_id': businessId,
      },
    );
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

  // ---- Realtime de estado de zonas ----
  //
  // PRD 7 Fase 4.1 — versión anterior usaba `channel('zones:status')`
  // global SIN filtro `business_id` en ninguna tabla. Eso provocaba que
  // el cliente recibiera eventos de TODOS los negocios del cluster
  // (filtrados luego por RLS, pero igual viajando por la red) y, peor,
  // el caller nunca llamaba `.unsubscribe()` → memory leak +
  // suscripción persistente en el server.
  //
  // Fix: exigir `businessId`, scopear el nombre del canal a ese
  // business, y aplicar `filter: business_id=eq.X` server-side en cada
  // tabla. Las tablas que NO tienen `business_id` directo
  // (order_items, order_checks, payments) se quedan sin filter — eso
  // es deuda asumida porque su business_id se infiere via JOINs.
  // RLS sigue siendo la barrera real para esos casos.
  //
  // Devuelve el channel para que el caller PUEDA hacer `.unsubscribe()`
  // en su dispose. Recomendado encarecidamente (no opcional como antes).
  RealtimeChannel subscribe({
    required String businessId,
    required void Function() onChange,
  }) {
    final ch = sb.channel('zones:status:$businessId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'table_sessions',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'business_id',
          value: businessId,
        ),
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'orders',
        // orders no tiene business_id directo — viene via table_sessions.
        // RLS filtra cross-tenant. Cambio del table_session padre dispara
        // refresh igual via la suscripción anterior.
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
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'business_id',
          value: businessId,
        ),
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'dining_tables',
        // dining_tables no tiene business_id directo — está scoped via
        // zones.business_id (JOIN). RLS lo filtra correctamente.
        callback: (_) => onChange(),
      )
      ..subscribe();
    return ch;
  }
}
