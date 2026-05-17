// Repositorio de sugerencias de reorden. Lee la vista
// `v_inventory_reorder_suggestions` (migration 20260516_0016) y expone los
// datos al frontend en un modelo tipado.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ReorderSuggestion {
  final String inventoryItemId;
  final String businessId;
  final String? sku;
  final String name;
  final String unit;
  final double cost;
  final double minStock;
  final double? maxStock;
  final double currentStock;
  final double deficit;
  final double suggestedQty;
  final String? suggestedSupplierId;
  final String? suggestedSupplierName;
  final double? lastUnitCost;
  final DateTime? lastPurchaseAt;

  const ReorderSuggestion({
    required this.inventoryItemId,
    required this.businessId,
    required this.name,
    required this.unit,
    required this.cost,
    required this.minStock,
    required this.currentStock,
    required this.deficit,
    required this.suggestedQty,
    this.sku,
    this.maxStock,
    this.suggestedSupplierId,
    this.suggestedSupplierName,
    this.lastUnitCost,
    this.lastPurchaseAt,
  });

  /// Costo unitario "preferido" para usar en una OC: último costo real si
  /// existe, sino el costo del insumo, sino 0.
  double get preferredUnitCost {
    if (lastUnitCost != null && lastUnitCost! > 0) return lastUnitCost!;
    if (cost > 0) return cost;
    return 0;
  }

  factory ReorderSuggestion.fromMap(Map<String, dynamic> map) {
    double parseDouble(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    double? parseOptional(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse(v.toString());
    }

    return ReorderSuggestion(
      inventoryItemId: map['inventory_item_id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      sku: map['sku']?.toString(),
      name: map['name']?.toString() ?? 'Insumo',
      unit: map['unit']?.toString() ?? 'unidad',
      cost: parseDouble(map['cost']),
      minStock: parseDouble(map['min_stock']),
      maxStock: parseOptional(map['max_stock']),
      currentStock: parseDouble(map['current_stock']),
      deficit: parseDouble(map['deficit']),
      suggestedQty: parseDouble(map['suggested_qty']),
      suggestedSupplierId: map['suggested_supplier_id']?.toString(),
      suggestedSupplierName: map['suggested_supplier_name']?.toString(),
      lastUnitCost: parseOptional(map['last_unit_cost']),
      lastPurchaseAt: parseDate(map['last_purchase_at']),
    );
  }
}

class ReorderRepository {
  ReorderRepository(this._client);
  final SupabaseClient _client;

  static const _view = 'v_inventory_reorder_suggestions';

  Future<List<ReorderSuggestion>> getSuggestions(String businessId) async {
    final response = await _client
        .from(_view)
        .select()
        .eq('business_id', businessId)
        .order('deficit', ascending: false);
    return (response as List)
        .whereType<Map>()
        .map((row) =>
            ReorderSuggestion.fromMap(Map<String, dynamic>.from(row)))
        .toList(growable: false);
  }
}

final reorderRepositoryProvider = Provider<ReorderRepository>(
  (ref) => ReorderRepository(Supabase.instance.client),
);
