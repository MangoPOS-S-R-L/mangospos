import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/purchases/state/purchases_state.dart';
import '../datasources/queries/purchases_queries.dart';

class PurchasesRepository {
  final SupabaseClient _client;

  PurchasesRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<PurchaseSupplier>> getSuppliers(String businessId) async {
    final response = await _client
        .from(PurchasesQueries.tableSuppliers)
        .select('id, name, contact_name, phone, email, is_active')
        .eq('business_id', businessId)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(PurchaseSupplier.fromMap).toList(growable: false);
  }

  Future<List<PurchaseWarehouse>> getWarehouses(String businessId) async {
    final response = await _client
        .from(PurchasesQueries.tableWarehouses)
        .select('id, name, is_main')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('is_main', ascending: false)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(PurchaseWarehouse.fromMap).toList(growable: false);
  }

  Future<List<PurchaseInventoryItem>> getInventoryItems(String businessId) async {
    final response = await _client
        .from(PurchasesQueries.tableInventoryItems)
        .select('id, name, sku, unit, cost, is_active')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(PurchaseInventoryItem.fromMap).toList(growable: false);
  }

  Future<List<PurchaseOrderSummary>> getOrders({
    required String businessId,
    String? status,
    int limit = 80,
  }) async {
    final ordersResponse = status != null && status.isNotEmpty
        ? await _client
              .from(PurchasesQueries.tablePurchaseOrders)
              .select(
                'id, supplier_id, warehouse_id, order_number, status, total, expected_date, received_date, created_at, notes',
              )
              .eq('business_id', businessId)
              .eq('status', status)
              .order('created_at', ascending: false)
              .limit(limit)
        : await _client
              .from(PurchasesQueries.tablePurchaseOrders)
              .select(
                'id, supplier_id, warehouse_id, order_number, status, total, expected_date, received_date, created_at, notes',
              )
              .eq('business_id', businessId)
              .order('created_at', ascending: false)
              .limit(limit);

    final orders = List<Map<String, dynamic>>.from(ordersResponse);
    if (orders.isEmpty) return const [];

    final supplierIds = orders
        .map((row) => row['supplier_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final warehouseIds = orders
        .map((row) => row['warehouse_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final suppliersById = <String, String>{};
    if (supplierIds.isNotEmpty) {
      final suppliers = await _client
          .from(PurchasesQueries.tableSuppliers)
          .select('id, name')
          .inFilter('id', supplierIds);
      for (final row in List<Map<String, dynamic>>.from(suppliers)) {
        suppliersById[row['id']?.toString() ?? ''] = row['name']?.toString() ?? '';
      }
    }

    final warehousesById = <String, String>{};
    if (warehouseIds.isNotEmpty) {
      final warehouses = await _client
          .from(PurchasesQueries.tableWarehouses)
          .select('id, name')
          .inFilter('id', warehouseIds);
      for (final row in List<Map<String, dynamic>>.from(warehouses)) {
        warehousesById[row['id']?.toString() ?? ''] =
            row['name']?.toString() ?? '';
      }
    }

    return orders
        .map(
          (row) => PurchaseOrderSummary.fromMap(
            row,
            supplierName:
                suppliersById[row['supplier_id']?.toString() ?? ''] ??
                'Proveedor no asignado',
            warehouseName:
                warehousesById[row['warehouse_id']?.toString() ?? ''] ??
                'Almacen',
          ),
        )
        .toList(growable: false);
  }

  Future<void> createSupplier({
    required String businessId,
    required String name,
    String? contactName,
    String? phone,
    String? email,
  }) async {
    await _client.from(PurchasesQueries.tableSuppliers).insert({
      'business_id': businessId,
      'name': name,
      'contact_name': contactName,
      'phone': phone,
      'email': email,
      'is_active': true,
    }..removeWhere((key, value) => value == null || value == ''));
  }

  Future<void> createPurchaseOrder({
    required String businessId,
    required String supplierId,
    required String warehouseId,
    required String orderNumber,
    required String status,
    required DateTime expectedDate,
    String? notes,
    required List<PurchaseDraftItem> items,
  }) async {
    if (items.isEmpty) {
      throw Exception('Debes agregar al menos una linea a la orden.');
    }

    final subtotal = items.fold<double>(0, (sum, item) => sum + item.total);
    final tax = items.fold<double>(
      0,
      (sum, item) => sum + ((item.total * item.taxRate) / 100),
    );
    final total = subtotal + tax;

    final createdOrder = await _client
        .from(PurchasesQueries.tablePurchaseOrders)
        .insert({
          'business_id': businessId,
          'supplier_id': supplierId,
          'warehouse_id': warehouseId,
          'order_number': orderNumber,
          'status': status,
          'subtotal': subtotal,
          'tax': tax,
          'total': total,
          'expected_date': expectedDate.toIso8601String().split('T').first,
          'notes': notes,
        }..removeWhere((key, value) => value == null || value == ''))
        .select('id')
        .single();

    final orderId = createdOrder['id']?.toString();
    if (orderId == null || orderId.isEmpty) {
      throw Exception('No se pudo crear la orden de compra.');
    }

    await _client.from(PurchasesQueries.tablePurchaseOrderItems).insert(
      items
          .map(
            (item) => {
              'purchase_order_id': orderId,
              'inventory_item_id': item.inventoryItemId,
              'description': item.description,
              'quantity_ordered': item.quantity,
              'unit_cost': item.unitCost,
              'tax_rate': item.taxRate,
              'total': item.total,
            },
          )
          .toList(growable: false),
    );
  }

  Future<void> receivePurchaseOrder(String orderId, {String? notes}) async {
    await _client.rpc(
      PurchasesQueries.rpcReceivePurchaseOrder,
      params: {
        'p_order_id': orderId,
        'p_notes': notes,
      }..removeWhere((key, value) => value == null || value == ''),
    );
  }

  Future<String> generateNextOrderNumber(String businessId) async {
    final latest = await _client
        .from(PurchasesQueries.tablePurchaseOrders)
        .select('order_number')
        .eq('business_id', businessId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    final raw = latest?['order_number']?.toString() ?? '';
    final match = RegExp(r'(\d+)$').firstMatch(raw);
    final next = match == null ? 1 : (int.tryParse(match.group(1)!) ?? 0) + 1;
    return 'PO-${next.toString().padLeft(5, '0')}';
  }

  Future<Map<String, double>> getOrderTotalsByStatus(String businessId) async {
    final rows = List<Map<String, dynamic>>.from(
      await _client
          .from(PurchasesQueries.tablePurchaseOrders)
          .select('status, total')
          .eq('business_id', businessId),
    );

    final totals = <String, double>{};
    for (final row in rows) {
      final status = row['status']?.toString() ?? 'draft';
      totals[status] = (totals[status] ?? 0) + _toDouble(row['total']);
    }
    return totals;
  }
}
