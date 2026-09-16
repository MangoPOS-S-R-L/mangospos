// Pedido sugerido (Compras F2). Lee la proyección de `fn_purchase_projection`
// (20260915_0004) y crea las órdenes de todos los suplidores juntas con
// `fn_purchase_orders_create_batch` (20260915_0005).
//
// Las dos degradan: si la base no tiene la función devuelven `null` y la
// pantalla cae a lo de antes (Reorden, u orden por orden).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/inventory/purchase_quantity.dart';
import 'package:mangopos/core/inventory/suggested_order.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';

/// Una orden del lote: un suplidor y sus líneas (en unidad base).
class SuggestedOrderBatchOrder {
  final String supplierId;
  final String supplierName;
  final DateTime expectedDate;
  final List<PurchaseDraftItem> items;
  final String? notes;

  const SuggestedOrderBatchOrder({
    required this.supplierId,
    required this.supplierName,
    required this.expectedDate,
    required this.items,
    this.notes,
  });

  double get subtotal => items.fold<double>(0, (sum, i) => sum + i.total);
  double get tax => items.fold<double>(0, (sum, i) => sum + i.taxValue);

  Map<String, dynamic> toJson() => {
        'supplier_id': supplierId,
        'supplier_name': supplierName,
        'expected_date': expectedDate.toIso8601String().split('T').first,
        'header': {
          'subtotal': subtotal,
          'tax': tax,
          'total': subtotal + tax,
          'notes': notes,
        },
        'lines': [
          for (final item in items)
            {
              'inventory_item_id': item.inventoryItemId,
              'description': item.description,
              'quantity_ordered': item.quantity,
              'unit_cost': item.unitCost,
              'tax_rate': item.taxRate,
              'total': item.total,
              'discount': item.discountAmount,
              'purchase_unit':
                  item.purchaseUnit.trim().isEmpty ? null : item.purchaseUnit.trim(),
              'pack_size': item.packSize,
            },
        ],
      };
}

class CreatedSupplierOrder {
  final String supplierId;
  final String id;
  final String orderNumber;

  /// Ya existía con la misma llave (doble toque, reintento).
  final bool reused;

  const CreatedSupplierOrder({
    required this.supplierId,
    required this.id,
    required this.orderNumber,
    this.reused = false,
  });

  factory CreatedSupplierOrder.fromMap(Map<String, dynamic> map) {
    return CreatedSupplierOrder(
      supplierId: map['supplier_id']?.toString() ?? '',
      id: map['id']?.toString() ?? '',
      orderNumber: map['order_number']?.toString() ?? '',
      reused: map['reused'] == true,
    );
  }
}

class PurchaseProjectionRepository {
  PurchaseProjectionRepository(this._client);
  final SupabaseClient _client;

  /// Tri-estados estáticos: la función existe o no en el servidor.
  static bool? _projectionSupported;
  static bool? _batchSupported;

  /// PostgREST corta cada respuesta en 1,000 filas.
  static const int _pageSize = 1000;

  static bool _isMissingFunction(PostgrestException e) =>
      e.code == 'PGRST202' || e.code == '42883';

  /// Una fila por insumo, ordenada por costo estimado. `null` si la base no
  /// tiene `fn_purchase_projection`.
  Future<List<ProjectionLine>?> getProjection({
    required String businessId,
    String? warehouseId,
    int coverageDays = 7,
    int daysBack = 30,
    int defaultLeadTimeDays = kDefaultSupplierLeadTimeDays,
    int safetyDays = 3,
    String? supplierId,
    bool onlyNeeded = false,
  }) async {
    if (_projectionSupported == false) return null;
    final params = {
      'p_business_id': businessId,
      'p_warehouse_id': warehouseId,
      'p_coverage_days': coverageDays,
      'p_days_back': daysBack,
      'p_default_lead_time_days': defaultLeadTimeDays,
      'p_safety_days': safetyDays,
      'p_supplier_id': supplierId,
      'p_only_needed': onlyNeeded,
    };
    final lines = <ProjectionLine>[];
    try {
      for (var from = 0;; from += _pageSize) {
        final rows = await _client
            .rpc('fn_purchase_projection', params: params)
            .range(from, from + _pageSize - 1);
        _projectionSupported = true;
        final page = (rows as List).whereType<Map>().toList(growable: false);
        lines.addAll(
          page.map((row) => ProjectionLine.fromMap(Map<String, dynamic>.from(row))),
        );
        if (page.length < _pageSize) break;
      }
      return lines;
    } on PostgrestException catch (e) {
      if (_isMissingFunction(e)) {
        _projectionSupported = false;
        return null;
      }
      rethrow;
    }
  }

  /// Suplidores del negocio por id. `select *`: tiempo de entrega, pedido
  /// mínimo y WhatsApp vienen de migraciones que una base vieja puede no tener.
  Future<Map<String, SuggestedOrderSupplier>> getSuppliers(String businessId) async {
    final rows = await _client
        .from('suppliers')
        .select()
        .eq('business_id', businessId)
        .order('name');
    return {
      for (final row in (rows as List).whereType<Map>())
        row['id'].toString():
            SuggestedOrderSupplier.fromMap(Map<String, dynamic>.from(row)),
    };
  }

  /// Todas las órdenes en una transacción (todo o nada). `null` si la base no
  /// tiene `fn_purchase_orders_create_batch`: quien llama crea orden por orden
  /// con la llave `llave:suplidor`, la misma que usa la base por dentro.
  Future<List<CreatedSupplierOrder>?> createOrdersBatch({
    required String businessId,
    required String warehouseId,
    required List<SuggestedOrderBatchOrder> orders,
    required String idempotencyKey,
    String status = 'draft',
  }) async {
    if (_batchSupported == false) return null;
    try {
      final result = await _client.rpc(
        'fn_purchase_orders_create_batch',
        params: {
          'p_business_id': businessId,
          'p_warehouse_id': warehouseId,
          'p_orders': [for (final o in orders) o.toJson()],
          'p_status': status,
          'p_idempotency_key': idempotencyKey,
        },
      );
      _batchSupported = true;
      final map = Map<String, dynamic>.from(result as Map);
      return [
        for (final row in (map['orders'] as List? ?? const []).whereType<Map>())
          CreatedSupplierOrder.fromMap(Map<String, dynamic>.from(row)),
      ];
    } on PostgrestException catch (e) {
      if (_isMissingFunction(e)) {
        _batchSupported = false;
        return null;
      }
      rethrow;
    }
  }
}

final purchaseProjectionRepositoryProvider =
    Provider<PurchaseProjectionRepository>(
  (ref) => PurchaseProjectionRepository(Supabase.instance.client),
);
