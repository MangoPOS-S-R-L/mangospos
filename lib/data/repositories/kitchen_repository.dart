import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/kitchen_models.dart';

/// 🍳 Repositorio de Cocina (KDS)
class KitchenRepository {
  final SupabaseClient _client;

  KitchenRepository(this._client);

  // ============================================================
  // 📊 OBTENER ITEMS ACTIVOS
  // ============================================================

  /// Obtener items activos de cocina (vista kds_active_items)
  Future<List<KitchenItem>> getActiveItems({
    String? businessId,
    String? areaCode,
    String? status,
    bool includeModifiers = false,
    int? limit,
  }) async {
    try {
      return await _fetchActiveItems(
        businessId: businessId,
        areaCode: areaCode,
        status: status,
        includeModifiers: includeModifiers,
        limit: limit,
      );
    } on PostgrestException catch (e) {
      // Fallback para evitar que la UI quede bloqueada en ambientes con dataset grande.
      if (e.code == '57014') {
        return _fetchActiveItems(
          businessId: businessId,
          areaCode: areaCode,
          status: status,
          includeModifiers: false,
          limit: limit ?? 250,
        );
      }
      throw Exception('Error al obtener items de cocina: $e');
    } catch (e) {
      throw Exception('Error al obtener items de cocina: $e');
    }
  }

  /// Ítems del KDS en modo "esperar al cocinero" (kds_complete_on_payment =
  /// false). Trae los ítems de órdenes cuya cocina NO está terminada
  /// (`orders.kitchen_done_at IS NULL`), INCLUIDOS los ya pagados, vía la vista
  /// `kds_open_orders`. Así una orden pagada sigue visible hasta que el
  /// cocinero la marque. Misma forma de columnas que `getActiveItems`.
  Future<List<KitchenItem>> getOpenItems({
    String? businessId,
    String? areaCode,
  }) async {
    try {
      const selectColumns =
          'id,order_id,order_number,product_name,quantity,notes,status,created_at,started_at,ready_at,table_name,waiter_name,business_id,area_code,area_name,is_takeout';
      var query = _client.from('kds_open_orders').select(selectColumns);
      if (businessId != null && businessId.isNotEmpty) {
        query = query.eq('business_id', businessId);
      }
      if (areaCode != null && areaCode.isNotEmpty) {
        query = query.eq('area_code', areaCode);
      }
      final data = await query;
      final items = List<Map<String, dynamic>>.from(data)
          .map(KitchenItem.fromMap)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return items;
    } catch (e) {
      throw Exception('Error al obtener items de cocina (abiertas): $e');
    }
  }

  /// Ítems que la cocina TERMINÓ HOY (`order_items.ready_at` de hoy), vía la
  /// vista `kds_completed_today`. Independiente del estado vivo del tablero:
  /// sobrevive al pago y al despacho, así que alimenta el stat/diálogo
  /// "Completados Hoy" de forma confiable en ambos modos. Devuelve `[]` ante
  /// cualquier error (el stat es opcional, no debe romper la pantalla).
  Future<List<KitchenItem>> getCompletedTodayItems({String? businessId}) async {
    try {
      const selectColumns =
          'id,order_id,order_number,product_name,quantity,notes,status,created_at,started_at,ready_at,table_name,waiter_name,business_id,area_code,area_name,is_takeout';
      var query = _client.from('kds_completed_today').select(selectColumns);
      if (businessId != null && businessId.isNotEmpty) {
        query = query.eq('business_id', businessId);
      }
      final data = await query;
      return List<Map<String, dynamic>>.from(data)
          .map(KitchenItem.fromMap)
          .toList(growable: false);
    } catch (e) {
      return const [];
    }
  }

  /// Sella la cocina de una orden como terminada: la saca del KDS en modo
  /// "esperar al cocinero" (`kitchen_done_at`). También sella `ready_at` en los
  /// ítems que no lo tengan —SIN tocar su `status` (p. ej. ítems ya 'paid')—
  /// para dejar registrado cuándo la cocina los completó. No afecta el pago.
  Future<void> markOrderKitchenDone(String orderId) async {
    final now = DateTime.now().toIso8601String();
    try {
      await _client
          .from('order_items')
          .update({'ready_at': now})
          .eq('order_id', orderId)
          .isFilter('ready_at', null)
          .neq('status', 'void');
    } catch (_) {
      // El sello por-ítem es best-effort; lo importante es la orden.
    }
    await _client
        .from('orders')
        .update({'kitchen_done_at': now})
        .eq('id', orderId)
        .isFilter('kitchen_done_at', null);
  }

  /// Obtener órdenes agrupadas
  Future<List<KitchenOrder>> getActiveOrders({
    String? businessId,
    String? areaCode,
  }) async {
    try {
      final items = await getActiveItems(
        businessId: businessId,
        areaCode: areaCode,
        includeModifiers: true,
      );

      // Agrupar items por orden
      final ordersMap = <String, List<KitchenItem>>{};

      for (final item in items) {
        if (!ordersMap.containsKey(item.orderId)) {
          ordersMap[item.orderId] = [];
        }
        ordersMap[item.orderId]!.add(item);
      }

      // Crear órdenes agrupadas
      return ordersMap.entries.map((entry) {
        final orderItems = entry.value;
        final firstItem = orderItems.first;

        return KitchenOrder(
          orderId: entry.key,
          orderNumber: firstItem.orderNumber,
          tableName: firstItem.tableName,
          waiterName: firstItem.waiterName,
          createdAt: firstItem.createdAt,
          items: orderItems,
        );
      }).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } catch (e) {
      throw Exception('Error al obtener órdenes de cocina: $e');
    }
  }

  // ============================================================
  // 🔄 ACTUALIZAR ESTADOS
  // ============================================================

  /// Actualizar estado de item
  Future<void> updateItemStatus({
    required String itemId,
    required String status,
  }) async {
    try {
      final updates = <String, dynamic>{'status': status};

      // Agregar timestamps según el estado
      if (status == 'preparing') {
        updates['started_at'] = DateTime.now().toIso8601String();
      } else if (status == 'ready') {
        updates['ready_at'] = DateTime.now().toIso8601String();
      }

      await _client.from('order_items').update(updates).eq('id', itemId);
    } catch (e) {
      throw Exception('Error al actualizar estado: $e');
    }
  }

  /// Marcar item como preparando
  Future<void> startPreparingItem(String itemId) async {
    await updateItemStatus(itemId: itemId, status: 'preparing');
  }

  /// Marcar todos los items pendientes de una orden como preparando
  Future<void> startPreparingOrder(String orderId) async {
    try {
      await _client.rpc(
        'fn_start_preparing_order',
        params: {'p_order_id': orderId},
      );
    } catch (e) {
      throw Exception('Error al iniciar preparacion: $e');
    }
  }

  /// Marcar item como listo
  Future<void> markItemReady(String itemId) async {
    await updateItemStatus(itemId: itemId, status: 'ready');
  }

  /// Marcar item como servido
  Future<void> markItemServed(String itemId) async {
    await updateItemStatus(itemId: itemId, status: 'served');
  }

  /// Marcar todos los items de una orden como listos
  Future<void> markOrderReady(String orderId) async {
    try {
      await _client.rpc('fn_mark_order_ready', params: {'p_order_id': orderId});
    } catch (e) {
      throw Exception('Error al marcar orden como lista: $e');
    }
  }

  // ============================================================
  // 🔔 SUSCRIPCIONES EN TIEMPO REAL
  // ============================================================

  /// Suscribirse a cambios en items de cocina
  Stream<List<KitchenItem>> subscribeToKitchenItems({String? areaCode}) {
    try {
      var query = _client
          .from('order_items')
          .stream(primaryKey: ['id'])
          .inFilter('status', ['pending', 'preparing', 'ready']);

      return query.map((data) {
        return data.map((json) => KitchenItem.fromMap(json)).toList();
      });
    } catch (e) {
      throw Exception('Error en suscripción: $e');
    }
  }

  /// Suscribirse a nuevas órdenes
  Stream<KitchenOrder> subscribeToNewOrders({String? areaCode}) {
    return subscribeToKitchenItems(areaCode: areaCode)
        .asyncMap((items) async {
          // Agrupar por orden
          final ordersMap = <String, List<KitchenItem>>{};

          for (final item in items) {
            if (!ordersMap.containsKey(item.orderId)) {
              ordersMap[item.orderId] = [];
            }
            ordersMap[item.orderId]!.add(item);
          }

          // Retornar solo órdenes nuevas (con items pendientes)
          return ordersMap.entries
              .where((entry) => entry.value.any((i) => i.isPending))
              .map((entry) {
                final orderItems = entry.value;
                final firstItem = orderItems.first;

                return KitchenOrder(
                  orderId: entry.key,
                  orderNumber: firstItem.orderNumber,
                  tableName: firstItem.tableName,
                  waiterName: firstItem.waiterName,
                  createdAt: firstItem.createdAt,
                  items: orderItems,
                );
              });
        })
        .expand((orders) => orders);
  }

  // ============================================================
  // 📊 ESTADÍSTICAS
  // ============================================================

  /// Obtener estadísticas de cocina
  Future<Map<String, int>> getKitchenStats({String? businessId}) async {
    try {
      final items = await getActiveItems(businessId: businessId);

      return {
        'pending': items.where((i) => i.isPending).length,
        'preparing': items.where((i) => i.isPreparing).length,
        'ready': items.where((i) => i.isReady).length,
        'total': items.length,
      };
    } catch (e) {
      throw Exception('Error al obtener estadísticas: $e');
    }
  }

  /// Obtener tiempo promedio de preparación
  Future<Duration?> getAveragePreparationTime({String? businessId}) async {
    try {
      final items = await getActiveItems(
        businessId: businessId,
        status: 'ready',
      );

      final times = items
          .where((i) => i.preparingTime != null)
          .map((i) => i.preparingTime!.inSeconds)
          .toList();

      if (times.isEmpty) return null;

      final average = times.reduce((a, b) => a + b) / times.length;
      return Duration(seconds: average.round());
    } catch (e) {
      return null;
    }
  }

  Future<List<KitchenItem>> _fetchActiveItems({
    String? businessId,
    String? areaCode,
    String? status,
    required bool includeModifiers,
    int? limit,
  }) async {
    // `area_code` y `area_name` agregados al view en migration
    // 20260527_0002_kds_active_items_area_code.sql. Antes el view devolvía
    // NULL hardcoded para area_code; ahora vienen del oi.print_area_code +
    // LEFT JOIN a print_areas.name.
    const selectColumns =
        'id,order_id,order_number,product_name,quantity,notes,status,created_at,started_at,ready_at,table_name,waiter_name,business_id,area_code,area_name,is_takeout';

    final baseQuery = _client.from('kds_active_items').select(selectColumns);
    var query = baseQuery;

    if (businessId != null && businessId.isNotEmpty) {
      query = query.eq('business_id', businessId);
    }
    if (areaCode != null && areaCode.isNotEmpty) {
      query = query.eq('area_code', areaCode);
    }
    if (status != null && status.isNotEmpty) {
      query = query.eq('status', status);
    }
    final data = await (limit != null && limit > 0
        ? query.limit(limit)
        : query);
    var rows = List<Map<String, dynamic>>.from(data);

    // Fallback defensivo:
    // algunos ambientes aún tienen kds_active_items con business_id nulo
    // para órdenes manual/rápida. Suplementamos esos rows usando el
    // business real de la sesión de la orden.
    if (businessId != null && businessId.isNotEmpty) {
      var nullBusinessQuery = baseQuery.isFilter('business_id', null);
      if (areaCode != null && areaCode.isNotEmpty) {
        nullBusinessQuery = nullBusinessQuery.eq('area_code', areaCode);
      }
      if (status != null && status.isNotEmpty) {
        nullBusinessQuery = nullBusinessQuery.eq('status', status);
      }
      final nullBusinessData = await (limit != null && limit > 0
          ? nullBusinessQuery.limit(limit)
          : nullBusinessQuery);
      final nullBusinessRows = List<Map<String, dynamic>>.from(
        nullBusinessData,
      );

      if (nullBusinessRows.isNotEmpty) {
        final orderIds = nullBusinessRows
            .map((row) => row['order_id']?.toString())
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList(growable: false);

        if (orderIds.isNotEmpty) {
          final orderRows = await _client
              .from('orders')
              .select('id, table_sessions!inner(business_id)')
              .inFilter('id', orderIds)
              .eq('table_sessions.business_id', businessId);

          final allowedOrderIds = List<Map<String, dynamic>>.from(
            orderRows,
          ).map((row) => row['id']?.toString()).whereType<String>().toSet();

          if (allowedOrderIds.isNotEmpty) {
            final existingIds = rows
                .map((row) => row['id']?.toString())
                .whereType<String>()
                .toSet();
            final supplementalRows = nullBusinessRows.where((row) {
              final rowId = row['id']?.toString();
              final orderId = row['order_id']?.toString();
              return orderId != null &&
                  allowedOrderIds.contains(orderId) &&
                  (rowId == null || !existingIds.contains(rowId));
            });
            rows = [...rows, ...supplementalRows];
          }
        }
      }
    }

    final items = rows.map(KitchenItem.fromMap).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (items.isEmpty) return items;
    final withTakeout = await _attachTakeoutFlags(items);
    if (!includeModifiers) return withTakeout;
    return _attachModifiers(withTakeout);
  }

  Future<List<KitchenItem>> _attachTakeoutFlags(
    List<KitchenItem> items,
  ) async {
    // kds_active_items no expone is_takeout, asi que lo traemos directo
    // de order_items en lotes para no excederse en el filtro `in`.
    final itemIds = items.map((i) => i.id).toList(growable: false);
    final flagsByItem = <String, bool>{};
    const chunkSize = 100;

    for (var i = 0; i < itemIds.length; i += chunkSize) {
      final end = (i + chunkSize > itemIds.length)
          ? itemIds.length
          : i + chunkSize;
      final chunk = itemIds.sublist(i, end);

      final rows = await _client
          .from('order_items')
          .select('id,is_takeout')
          .inFilter('id', chunk);

      for (final row in List<Map<String, dynamic>>.from(rows)) {
        final id = row['id']?.toString();
        if (id == null || id.isEmpty) continue;
        flagsByItem[id] = row['is_takeout'] == true;
      }
    }

    return items
        .map(
          (item) =>
              item.copyWith(isTakeout: flagsByItem[item.id] ?? item.isTakeout),
        )
        .toList(growable: false);
  }

  Future<List<KitchenItem>> _attachModifiers(List<KitchenItem> items) async {
    final itemIds = items.map((i) => i.id).toList(growable: false);
    final modifiersByItem = <String, List<KitchenModifier>>{};
    const chunkSize = 100;

    for (var i = 0; i < itemIds.length; i += chunkSize) {
      final end = (i + chunkSize > itemIds.length)
          ? itemIds.length
          : i + chunkSize;
      final chunk = itemIds.sublist(i, end);

      final rows = await _client
          .from('order_item_modifiers')
          .select('id,item_id,name,qty')
          .inFilter('item_id', chunk);

      for (final row in List<Map<String, dynamic>>.from(rows)) {
        final itemId = row['item_id']?.toString();
        if (itemId == null || itemId.isEmpty) continue;

        final mods = modifiersByItem.putIfAbsent(
          itemId,
          () => <KitchenModifier>[],
        );
        mods.add(
          KitchenModifier.fromMap({
            'id': row['id'],
            'name': row['name'],
            'quantity': row['qty'],
          }),
        );
      }
    }

    return items
        .map(
          (item) =>
              item.copyWith(modifiers: modifiersByItem[item.id] ?? const []),
        )
        .toList(growable: false);
  }

  // ============================================================
  // 🗂️ ÁREAS DE PRODUCCIÓN (para filtro del KDS)
  // ============================================================

  /// Lista las áreas de producción activas del business (Cocina, Bar,
  /// Horno, etc.) ordenadas por nombre. Las consume el dropdown
  /// "Filtrar por área" del KDS.
  ///
  /// Retorna lista vacía si el business no tiene áreas configuradas
  /// (caso edge: instalación recién migrada o negocio sin cocina). En
  /// ese caso el UI debería esconder el dropdown.
  Future<List<KitchenArea>> getPrintAreas({required String businessId}) async {
    try {
      final rows = await _client
          .from('print_areas')
          .select('id, code, name')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('name');
      return List<Map<String, dynamic>>.from(rows)
          .map((row) => KitchenArea(
                id: row['id']?.toString() ?? '',
                code: row['code']?.toString() ?? '',
                name: row['name']?.toString() ?? '',
              ))
          .where((a) => a.code.isNotEmpty && a.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      // RLS o error transitorio — el UI muestra solo "Todos" sin opciones.
      return const [];
    }
  }
}
