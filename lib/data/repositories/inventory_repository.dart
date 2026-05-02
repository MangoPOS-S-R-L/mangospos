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

  /// PRD 9 Fase 1B: lista todas las bodegas del business (incluye inactivas
  /// y la virtual `__IN_TRANSIT__`), con dirección y flag is_active para CRUD.
  Future<List<InventoryWarehouseDetail>> getAllWarehouses(
    String businessId,
  ) async {
    final response = await _client
        .from(InventoryQueries.tableWarehouses)
        .select('id, name, address, is_main, is_active, created_at')
        .eq('business_id', businessId)
        .order('is_main', ascending: false)
        .order('name');

    return List<Map<String, dynamic>>.from(response)
        .map(InventoryWarehouseDetail.fromMap)
        .toList(growable: false);
  }

  Future<InventoryWarehouseDetail> createWarehouse({
    required String businessId,
    required String name,
    String? address,
    bool isMain = false,
    bool isActive = true,
  }) async {
    if (isMain) {
      // Sólo una bodega principal por business: bajar la marca de la actual.
      await _client
          .from(InventoryQueries.tableWarehouses)
          .update({'is_main': false})
          .eq('business_id', businessId)
          .eq('is_main', true);
    }
    final response = await _client
        .from(InventoryQueries.tableWarehouses)
        .insert({
          'business_id': businessId,
          'name': name,
          'address': address,
          'is_main': isMain,
          'is_active': isActive,
        }..removeWhere((key, value) => value == null))
        .select('id, name, address, is_main, is_active, created_at')
        .single();
    return InventoryWarehouseDetail.fromMap(
      Map<String, dynamic>.from(response),
    );
  }

  Future<void> updateWarehouse({
    required String businessId,
    required String warehouseId,
    required String name,
    String? address,
    required bool isMain,
    required bool isActive,
  }) async {
    if (isMain) {
      await _client
          .from(InventoryQueries.tableWarehouses)
          .update({'is_main': false})
          .eq('business_id', businessId)
          .eq('is_main', true)
          .neq('id', warehouseId);
    }
    await _client
        .from(InventoryQueries.tableWarehouses)
        .update({
          'name': name,
          'address': address,
          'is_main': isMain,
          'is_active': isActive,
        })
        .eq('id', warehouseId);
  }

  Future<List<InventoryItemSummary>> getItems({
    required String businessId,
    required String warehouseId,
    String? query,
  }) async {
    // PRD 9 Fase 1D: incluir costing_method y barcode (columnas nuevas).
    const columns =
        'id, sku, name, description, unit, cost, min_stock, max_stock, '
        'is_active, costing_method, barcode';
    final normalized = query?.trim();
    final itemsResponse = normalized != null && normalized.isNotEmpty
        ? await _client
              .from(InventoryQueries.tableInventoryItems)
              .select(columns)
              .eq('business_id', businessId)
              .or(
                'name.ilike.%${normalized.replaceAll(',', '')}%,sku.ilike.%${normalized.replaceAll(',', '')}%,description.ilike.%${normalized.replaceAll(',', '')}%',
              )
              .order('name')
        : await _client
              .from(InventoryQueries.tableInventoryItems)
              .select(columns)
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
    String? costingMethod,
    String? barcode,
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
            'costing_method': costingMethod,
            'barcode': barcode,
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
    String? costingMethod,
    String? barcode,
  }) async {
    final payload = <String, dynamic>{
      'name': name,
      'sku': sku,
      'description': description,
      'unit': unit,
      'cost': cost,
      'min_stock': minStock,
      'max_stock': maxStock,
      'is_active': isActive,
    };
    // costing_method y barcode son extensiones PRD 9 — solo se mandan
    // si el caller los provee, así no pisamos valores existentes.
    if (costingMethod != null) payload['costing_method'] = costingMethod;
    if (barcode != null) payload['barcode'] = barcode;
    payload.removeWhere((key, value) => value == null);
    await _client
        .from(InventoryQueries.tableInventoryItems)
        .update(payload)
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

  // ── PRD 9 Fase 1C: Proveedores (CRUD completo) ─────────────────────

  Future<List<InventorySupplierDetail>> getAllSuppliers(
    String businessId,
  ) async {
    final response = await _client
        .from('suppliers')
        .select(
          'id, name, rnc, contact_name, phone, email, address, '
          'payment_terms, notes, is_active, created_at',
        )
        .eq('business_id', businessId)
        .order('name');
    return List<Map<String, dynamic>>.from(response)
        .map(InventorySupplierDetail.fromMap)
        .toList(growable: false);
  }

  Future<InventorySupplierDetail> createSupplierDetailed({
    required String businessId,
    required String name,
    String? rnc,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    String? paymentTerms,
    String? notes,
    bool isActive = true,
  }) async {
    final response = await _client
        .from('suppliers')
        .insert({
          'business_id': businessId,
          'name': name,
          'rnc': rnc,
          'contact_name': contactName,
          'phone': phone,
          'email': email,
          'address': address,
          'payment_terms': paymentTerms,
          'notes': notes,
          'is_active': isActive,
        }..removeWhere((key, value) => value == null || value == ''))
        .select(
          'id, name, rnc, contact_name, phone, email, address, '
          'payment_terms, notes, is_active, created_at',
        )
        .single();
    return InventorySupplierDetail.fromMap(
      Map<String, dynamic>.from(response),
    );
  }

  Future<void> updateSupplierDetailed({
    required String supplierId,
    required String name,
    String? rnc,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    String? paymentTerms,
    String? notes,
    required bool isActive,
  }) async {
    await _client
        .from('suppliers')
        .update({
          'name': name,
          'rnc': rnc,
          'contact_name': contactName,
          'phone': phone,
          'email': email,
          'address': address,
          'payment_terms': paymentTerms,
          'notes': notes,
          'is_active': isActive,
        })
        .eq('id', supplierId);
  }

  /// PRD 9 Fase 1: invoca la RPC `bootstrap_menu_to_inventory_links` que
  /// genera, para el business, los `inventory_items` faltantes a partir
  /// del menú activo y crea las `recipes` + `recipe_ingredients` 1:1
  /// (qty=1) requeridas para que la integración con ventas resuelva
  /// menu_item → inventory_item.
  ///
  /// Retorna el JSON de la RPC: `{business_id, items_created,
  /// recipes_created, ingredients_created}`. Lanza si el caller no es
  /// owner/admin/manager (la RPC enforce backend).
  Future<Map<String, dynamic>> bootstrapMenuToInventoryLinks(
    String businessId,
  ) async {
    final response = await _client.rpc(
      'bootstrap_menu_to_inventory_links',
      params: {'p_business_id': businessId},
    );
    if (response is Map) {
      return Map<String, dynamic>.from(response);
    }
    return <String, dynamic>{};
  }
}
