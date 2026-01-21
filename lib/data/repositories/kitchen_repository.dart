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
  }) async {
    try {
      // Por ahora, obtener todos y filtrar en memoria
      // TODO: Mejorar con filtros en query cuando se actualice Supabase
      var query = _client.from('kds_active_items').select();
      if (businessId != null) {
        query = query.eq('business_id', businessId);
      }

      final data = await query.order('created_at', ascending: true);

      var rawData = List<Map<String, dynamic>>.from(data);

      // Filtrar en memoria por areaCode antes de convertir
      if (areaCode != null) {
        rawData = rawData.where((map) => map['area_code'] == areaCode).toList();
      }

      var items = rawData.map((json) {
        final item = KitchenItem.fromMap(json);

        // Cargar modificadores si existen
        final modifiers =
            (json['modifiers'] as List?)
                ?.map((m) => KitchenModifier.fromMap(m))
                .toList() ??
            [];

        return item.copyWith(modifiers: modifiers);
      }).toList();

      if (status != null) {
        items = items.where((i) => i.status == status).toList();
      }

      return items;
    } catch (e) {
      throw Exception('Error al obtener items de cocina: $e');
    }
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
      await _client.rpc(
        'fn_mark_order_ready',
        params: {'p_order_id': orderId},
      );
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
}
