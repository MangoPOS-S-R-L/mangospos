import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/inventory/state/inventory_state.dart';
import '../datasources/queries/inventory_queries.dart';

class InventoryRepository {
  final SupabaseClient _client;

  InventoryRepository(this._client);

  Future<List<InventoryWarehouse>> getWarehouses(String businessId) async {
    final response = await _client
        .from(InventoryQueries.tableWarehouses)
        .select('id, name, is_main')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('is_main', ascending: false)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(InventoryWarehouse.fromMap).toList(growable: false);
  }

  Future<List<InventoryItemSummary>> getItems({
    required String businessId,
    required String warehouseId,
    String? query,
  }) async {
    final normalized = query?.trim();
    final itemsResponse = normalized != null && normalized.isNotEmpty
        ? await _client
              .from(InventoryQueries.tableInventoryItems)
              .select(
                'id, sku, name, description, unit, cost, min_stock, max_stock, is_active',
              )
              .eq('business_id', businessId)
              .or(
                'name.ilike.%${normalized.replaceAll(',', '')}%,sku.ilike.%${normalized.replaceAll(',', '')}%,description.ilike.%${normalized.replaceAll(',', '')}%',
              )
              .order('name')
        : await _client
              .from(InventoryQueries.tableInventoryItems)
              .select(
                'id, sku, name, description, unit, cost, min_stock, max_stock, is_active',
              )
              .eq('business_id', businessId)
              .order('name');
    final itemsRaw = List<Map<String, dynamic>>.from(itemsResponse);

    final stockResponse = await _client
        .from(InventoryQueries.tableInventoryStock)
        .select('item_id, quantity')
        .eq('warehouse_id', warehouseId);

    final stockByItem = <String, double>{};
    for (final row in List<Map<String, dynamic>>.from(stockResponse)) {
      final itemId = row['item_id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      final quantity = row['quantity'];
      stockByItem[itemId] = quantity is num
          ? quantity.toDouble()
          : double.tryParse(quantity?.toString() ?? '') ?? 0;
    }

    return itemsRaw
        .map(
          (item) => InventoryItemSummary.fromMap(
            item,
            stock: stockByItem[item['id']?.toString() ?? ''] ?? 0,
          ),
        )
        .toList(growable: false);
  }

  Future<List<InventoryMovementEntry>> getMovements({
    required String businessId,
    String? warehouseId,
    String? itemId,
    int limit = 60,
  }) async {
    final movementsResponse = warehouseId != null && warehouseId.isNotEmpty
        ? await _client
              .from(InventoryQueries.tableInventoryMovements)
              .select(
                'id, item_id, warehouse_id, movement_type, quantity, notes, reference_type, created_at',
              )
              .eq('business_id', businessId)
              .eq('warehouse_id', warehouseId)
              .order('created_at', ascending: false)
              .limit(limit)
        : itemId != null && itemId.isNotEmpty
        ? await _client
              .from(InventoryQueries.tableInventoryMovements)
              .select(
                'id, item_id, warehouse_id, movement_type, quantity, notes, reference_type, created_at',
              )
              .eq('business_id', businessId)
              .eq('item_id', itemId)
              .order('created_at', ascending: false)
              .limit(limit)
        : await _client
              .from(InventoryQueries.tableInventoryMovements)
              .select(
                'id, item_id, warehouse_id, movement_type, quantity, notes, reference_type, created_at',
              )
              .eq('business_id', businessId)
              .order('created_at', ascending: false)
              .limit(limit);
    final movementsRaw = List<Map<String, dynamic>>.from(movementsResponse);

    final itemIds = movementsRaw
        .map((row) => row['item_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final warehouseIds = movementsRaw
        .map((row) => row['warehouse_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final itemsById = <String, String>{};
    if (itemIds.isNotEmpty) {
      final items = await _client
          .from(InventoryQueries.tableInventoryItems)
          .select('id, name')
          .inFilter('id', itemIds);
      for (final row in List<Map<String, dynamic>>.from(items)) {
        itemsById[row['id']?.toString() ?? ''] = row['name']?.toString() ?? '';
      }
    }

    final warehousesById = <String, String>{};
    if (warehouseIds.isNotEmpty) {
      final warehouses = await _client
          .from(InventoryQueries.tableWarehouses)
          .select('id, name')
          .inFilter('id', warehouseIds);
      for (final row in List<Map<String, dynamic>>.from(warehouses)) {
        warehousesById[row['id']?.toString() ?? ''] =
            row['name']?.toString() ?? '';
      }
    }

    return movementsRaw
        .map(
          (row) => InventoryMovementEntry.fromMap(
            row,
            itemName: itemsById[row['item_id']?.toString() ?? ''] ?? 'Insumo',
            warehouseName:
                warehousesById[row['warehouse_id']?.toString() ?? ''] ??
                'Almacen',
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> createItem({
    required String businessId,
    required String name,
    String? sku,
    String? description,
    String unit = 'unidad',
    double cost = 0,
    double minStock = 0,
    double? maxStock,
    bool isActive = true,
  }) async {
    final response = await _client
        .from(InventoryQueries.tableInventoryItems)
        .insert(
          {
            'business_id': businessId,
            'name': name,
            'sku': sku,
            'description': description,
            'unit': unit,
            'cost': cost,
            'min_stock': minStock,
            'max_stock': maxStock,
            'is_active': isActive,
          }..removeWhere((key, value) => value == null),
        )
        .select()
        .single();

    return Map<String, dynamic>.from(response);
  }

  Future<void> updateItem({
    required String itemId,
    required String name,
    String? sku,
    String? description,
    required String unit,
    required double cost,
    required double minStock,
    double? maxStock,
    required bool isActive,
  }) async {
    await _client
        .from(InventoryQueries.tableInventoryItems)
        .update(
          {
            'name': name,
            'sku': sku,
            'description': description,
            'unit': unit,
            'cost': cost,
            'min_stock': minStock,
            'max_stock': maxStock,
            'is_active': isActive,
          }..removeWhere((key, value) => value == null),
        )
        .eq('id', itemId);
  }

  Future<void> recordMovement({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required String movementType,
    required double quantity,
    double? costPerUnit,
    String? notes,
    String? referenceType,
  }) async {
    await _client.rpc(
      InventoryQueries.rpcRecordMovement,
      params: {
        'p_business_id': businessId,
        'p_warehouse_id': warehouseId,
        'p_item_id': itemId,
        'p_movement_type': movementType,
        'p_quantity': quantity,
        'p_cost_per_unit': costPerUnit,
        'p_notes': notes,
        'p_reference_type': referenceType,
      },
    );
  }
}
