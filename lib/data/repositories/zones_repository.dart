import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';
import 'package:mangopos/core/offline/zones_offline_cache.dart';

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

    // Multimesero: si la sesión tiene `opened_by_employee_id`, sobreescribir
    // el `waiter_name` con el nombre del empleado (no del auth user del
    // dispositivo). En modo single-mesero (sin opened_by_employee_id),
    // mantiene el comportamiento legacy.
    final openSessionIds = rows
        .map((row) => row['session_id']?.toString().trim())
        .whereType<String>()
        .where((sessionId) => sessionId.isNotEmpty)
        .toSet()
        .toList(growable: false);

    if (openSessionIds.isNotEmpty) {
      try {
        var sessionWaiterQuery = sb
            .from('table_sessions')
            .select('id, opened_by_employee_id')
            .inFilter('id', openSessionIds)
            .not('opened_by_employee_id', 'is', null);

        if (scopedBusinessId != null && scopedBusinessId.isNotEmpty) {
          sessionWaiterQuery =
              sessionWaiterQuery.eq('business_id', scopedBusinessId);
        }

        final sessionWaiterRows =
            List<Map<String, dynamic>>.from(await sessionWaiterQuery);

        if (sessionWaiterRows.isNotEmpty) {
          final employeeIds = sessionWaiterRows
              .map((s) => s['opened_by_employee_id']?.toString().trim())
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList(growable: false);

          final employeeNameById = <String, String>{};
          if (employeeIds.isNotEmpty) {
            final employeeRows = List<Map<String, dynamic>>.from(
              await sb
                  .from('employees')
                  .select('id, first_name, last_name')
                  .inFilter('id', employeeIds),
            );
            for (final emp in employeeRows) {
              final id = emp['id']?.toString().trim();
              final first = emp['first_name']?.toString().trim();
              final last = emp['last_name']?.toString().trim() ?? '';
              if (id == null || id.isEmpty) continue;
              if (first == null || first.isEmpty) continue;
              employeeNameById[id] = last.isEmpty
                  ? first
                  : preferredDisplayName(firstName: first);
            }
          }

          final employeeBySessionId = <String, String>{};
          for (final s in sessionWaiterRows) {
            final sessionId = s['id']?.toString();
            final empId = s['opened_by_employee_id']?.toString();
            if (sessionId == null || empId == null) continue;
            final name = employeeNameById[empId];
            if (name != null && name.isNotEmpty) {
              employeeBySessionId[sessionId] = name;
            }
          }

          if (employeeBySessionId.isNotEmpty) {
            for (final row in rows) {
              final sessionId = row['session_id']?.toString();
              if (sessionId == null) continue;
              final empName = employeeBySessionId[sessionId];
              if (empName != null && empName.isNotEmpty) {
                row['waiter_name'] = empName;
              }
            }
          }
        }
      } catch (_) {
        // Best-effort: si la query falla (columna missing en negocios sin
        // la migration multimesero, RLS, etc.), no rompemos el flujo.
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
