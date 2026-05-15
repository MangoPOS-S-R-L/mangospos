// Repositorio del módulo de producción.
// Encapsula:
//   - SELECT desde v_production_orders_summary (lista)
//   - Detalle de una orden + sus líneas
//   - RPCs fn_production_order_create / start / complete / cancel

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// =============================================================================
// MODELOS
// =============================================================================

enum ProductionOrderStatus { draft, inProgress, completed, cancelled }

extension ProductionOrderStatusX on ProductionOrderStatus {
  String get wire {
    switch (this) {
      case ProductionOrderStatus.draft:
        return 'draft';
      case ProductionOrderStatus.inProgress:
        return 'in_progress';
      case ProductionOrderStatus.completed:
        return 'completed';
      case ProductionOrderStatus.cancelled:
        return 'cancelled';
    }
  }

  String get label {
    switch (this) {
      case ProductionOrderStatus.draft:
        return 'Borrador';
      case ProductionOrderStatus.inProgress:
        return 'En proceso';
      case ProductionOrderStatus.completed:
        return 'Completada';
      case ProductionOrderStatus.cancelled:
        return 'Cancelada';
    }
  }

  static ProductionOrderStatus fromWire(String? value) {
    switch (value) {
      case 'in_progress':
        return ProductionOrderStatus.inProgress;
      case 'completed':
        return ProductionOrderStatus.completed;
      case 'cancelled':
        return ProductionOrderStatus.cancelled;
      case 'draft':
      default:
        return ProductionOrderStatus.draft;
    }
  }
}

class ProductionOrderSummary {
  final String id;
  final String code;
  final ProductionOrderStatus status;
  final double plannedYield;
  final double? actualYield;
  final String finishedItemId;
  final String finishedItemName;
  final String finishedItemUnit;
  final String sourceWarehouseId;
  final String sourceWarehouseName;
  final String destinationWarehouseId;
  final String destinationWarehouseName;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final String? notes;
  final String? cancellationReason;
  final int linesCount;

  const ProductionOrderSummary({
    required this.id,
    required this.code,
    required this.status,
    required this.plannedYield,
    required this.finishedItemId,
    required this.finishedItemName,
    required this.finishedItemUnit,
    required this.sourceWarehouseId,
    required this.sourceWarehouseName,
    required this.destinationWarehouseId,
    required this.destinationWarehouseName,
    required this.createdAt,
    required this.linesCount,
    this.actualYield,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.notes,
    this.cancellationReason,
  });

  factory ProductionOrderSummary.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString());
    }

    double? parseDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return ProductionOrderSummary(
      id: map['id']?.toString() ?? '',
      code: map['code']?.toString() ?? '',
      status: ProductionOrderStatusX.fromWire(map['status']?.toString()),
      plannedYield: parseDouble(map['planned_yield']) ?? 0,
      actualYield: parseDouble(map['actual_yield']),
      finishedItemId: map['finished_item_id']?.toString() ?? '',
      finishedItemName: map['finished_item_name']?.toString() ?? '',
      finishedItemUnit: map['finished_item_unit']?.toString() ?? 'unidad',
      sourceWarehouseId: map['source_warehouse_id']?.toString() ?? '',
      sourceWarehouseName: map['source_warehouse_name']?.toString() ?? '',
      destinationWarehouseId:
          map['destination_warehouse_id']?.toString() ?? '',
      destinationWarehouseName:
          map['destination_warehouse_name']?.toString() ?? '',
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
      startedAt: parseDate(map['started_at']),
      completedAt: parseDate(map['completed_at']),
      cancelledAt: parseDate(map['cancelled_at']),
      notes: map['notes']?.toString(),
      cancellationReason: map['cancellation_reason']?.toString(),
      linesCount: (map['lines_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class ProductionOrderLine {
  final String id;
  final String itemId;
  final String itemName;
  final String unit;
  final double plannedQuantity;
  final double? consumedQuantity;
  final double? costPerUnit;

  const ProductionOrderLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.plannedQuantity,
    this.consumedQuantity,
    this.costPerUnit,
  });

  factory ProductionOrderLine.fromMap(Map<String, dynamic> map) {
    double? parseDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final item = map['inventory_items'];
    final itemMap = item is Map<String, dynamic>
        ? item
        : (item is Map ? Map<String, dynamic>.from(item) : null);

    return ProductionOrderLine(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: itemMap?['name']?.toString() ?? '',
      unit: (map['unit']?.toString()) ??
          (itemMap?['unit']?.toString() ?? 'unidad'),
      plannedQuantity: parseDouble(map['planned_quantity']) ?? 0,
      consumedQuantity: parseDouble(map['consumed_quantity']),
      costPerUnit: parseDouble(map['cost_per_unit']),
    );
  }
}

class ProductionOrderDetail {
  final ProductionOrderSummary header;
  final List<ProductionOrderLine> lines;

  const ProductionOrderDetail({required this.header, required this.lines});
}

// =============================================================================
// REPO
// =============================================================================

class ProductionRepository {
  ProductionRepository(this._client);

  final SupabaseClient _client;

  Future<List<ProductionOrderSummary>> listByBusiness({
    required String businessId,
    Set<ProductionOrderStatus>? statusFilter,
    int limit = 200,
  }) async {
    var query = _client
        .from('v_production_orders_summary')
        .select()
        .eq('business_id', businessId);

    if (statusFilter != null && statusFilter.isNotEmpty) {
      final wires = statusFilter.map((s) => s.wire).toList(growable: false);
      query = query.inFilter('status', wires);
    }

    final response = await query
        .order('created_at', ascending: false)
        .limit(limit);

    return (response as List)
        .whereType<Map>()
        .map((row) =>
            ProductionOrderSummary.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }

  Future<ProductionOrderDetail> getDetail(String orderId) async {
    final headerRow = await _client
        .from('v_production_orders_summary')
        .select()
        .eq('id', orderId)
        .single();

    final linesRows = await _client
        .from('production_order_lines')
        .select('id, item_id, planned_quantity, consumed_quantity, unit, '
            'cost_per_unit, inventory_items(name, unit)')
        .eq('production_order_id', orderId)
        .order('id');

    final header = ProductionOrderSummary.fromMap(
      Map<String, dynamic>.from(headerRow),
    );
    final lines = (linesRows as List)
        .whereType<Map>()
        .map((row) =>
            ProductionOrderLine.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);

    return ProductionOrderDetail(header: header, lines: lines);
  }

  Future<Map<String, dynamic>> create({
    required String businessId,
    required String finishedItemId,
    required double plannedYield,
    required String sourceWarehouseId,
    required String destinationWarehouseId,
    String? notes,
  }) async {
    final response = await _client.rpc(
      'fn_production_order_create',
      params: {
        'p_business_id': businessId,
        'p_finished_item_id': finishedItemId,
        'p_planned_yield': plannedYield,
        'p_source_warehouse_id': sourceWarehouseId,
        'p_destination_warehouse_id': destinationWarehouseId,
        'p_notes': notes,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> start(String orderId) async {
    await _client.rpc(
      'fn_production_order_start',
      params: {'p_order_id': orderId},
    );
  }

  /// [lineConsumption] = mapa item_id → consumed quantity. Si está vacío o
  /// null, el RPC usa los `planned_quantity` por línea.
  Future<Map<String, dynamic>> complete({
    required String orderId,
    required double actualYield,
    Map<String, double>? lineConsumption,
  }) async {
    final overrides = lineConsumption?.entries
        .map((e) => {'item_id': e.key, 'consumed': e.value})
        .toList(growable: false);

    final response = await _client.rpc(
      'fn_production_order_complete',
      params: {
        'p_order_id': orderId,
        'p_actual_yield': actualYield,
        'p_line_consumption': overrides,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> cancel({required String orderId, String? reason}) async {
    await _client.rpc(
      'fn_production_order_cancel',
      params: {'p_order_id': orderId, 'p_reason': reason},
    );
  }

  /// Devuelve los inventory_items del business que tienen receta de
  /// producción asignada (`recipes.inventory_item_id` no nulo). Estos
  /// son los candidatos válidos para `p_finished_item_id`.
  Future<List<Map<String, dynamic>>> listProducibleItems({
    required String businessId,
  }) async {
    final rows = await _client
        .from('recipes')
        .select(
          'inventory_item_id, yield_quantity, '
          'inventory_items!inner(id, name, unit, business_id, item_classification, cost)',
        )
        .not('inventory_item_id', 'is', null);

    final list = List<Map<String, dynamic>>.from(rows);

    // Filter local-side by business_id (recipes no tiene business_id directo;
    // viene via inventory_items).
    final filtered = list.where((row) {
      final item = row['inventory_items'];
      final map = item is Map<String, dynamic>
          ? item
          : (item is Map ? Map<String, dynamic>.from(item) : null);
      return map?['business_id']?.toString() == businessId;
    }).toList(growable: false);

    return filtered.map((row) {
      final item = row['inventory_items'] as Map;
      return {
        'item_id': item['id'],
        'name': item['name'],
        'unit': item['unit'],
        'cost': item['cost'],
        'classification': item['item_classification'],
        'recipe_yield': row['yield_quantity'],
      };
    }).toList(growable: false);
  }
}

final productionRepositoryProvider = Provider<ProductionRepository>(
  (ref) => ProductionRepository(Supabase.instance.client),
);
