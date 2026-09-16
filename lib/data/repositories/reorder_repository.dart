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

  /// La misma sugerencia con el suplidor, el costo y la última compra que
  /// decidió `fn_purchase_resolve_suppliers`. Si la función resolvió, manda
  /// ELLA aunque diga «sin suplidor»: la vista contaba borradores y canceladas.
  ReorderSuggestion withResolved(ResolvedSupplier? resolved) {
    if (resolved == null) return this;
    return ReorderSuggestion(
      inventoryItemId: inventoryItemId,
      businessId: businessId,
      name: name,
      unit: unit,
      cost: cost,
      minStock: minStock,
      currentStock: currentStock,
      deficit: deficit,
      suggestedQty: suggestedQty,
      sku: sku,
      maxStock: maxStock,
      suggestedSupplierId: resolved.supplierId,
      suggestedSupplierName: resolved.supplierName,
      lastUnitCost: resolved.unitCostBase ?? lastUnitCost,
      lastPurchaseAt: resolved.lastPurchaseAt ?? lastPurchaseAt,
    );
  }

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

/// A quién comprarle un insumo y en qué presentación, según
/// `fn_purchase_resolve_suppliers` (20260915_0003): preferido → único vínculo
/// activo → última compra RECIBIDA.
class ResolvedSupplier {
  final String itemId;
  final String? supplierId;
  final String? supplierName;

  /// 'preferido' | 'vinculo' | 'ultima_compra' | null (nadie).
  final String? source;
  final int? leadTimeDays;

  /// Presentación de compra y cuántas unidades base trae (1 = sin empaque).
  final String purchaseUnit;
  final double packSize;

  /// Mínimo de compra del suplidor, en unidades de compra.
  final double? minOrderQty;

  /// Costo por unidad BASE y de dónde salió: 'ultima_compra' | 'lista' | 'insumo'.
  final double? unitCostBase;
  final String? costSource;
  final DateTime? lastPurchaseAt;

  const ResolvedSupplier({
    required this.itemId,
    this.supplierId,
    this.supplierName,
    this.source,
    this.leadTimeDays,
    this.purchaseUnit = '',
    this.packSize = 1,
    this.minOrderQty,
    this.unitCostBase,
    this.costSource,
    this.lastPurchaseAt,
  });

  factory ResolvedSupplier.fromMap(Map<String, dynamic> map) {
    double? optional(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final pack = optional(map['pack_size']);
    return ResolvedSupplier(
      itemId: map['item_id']?.toString() ?? '',
      supplierId: map['supplier_id']?.toString(),
      supplierName: map['supplier_name']?.toString(),
      source: map['supplier_source']?.toString(),
      leadTimeDays: (map['lead_time_days'] as num?)?.toInt(),
      purchaseUnit: map['purchase_unit']?.toString() ?? '',
      packSize: (pack == null || pack <= 0) ? 1 : pack,
      minOrderQty: optional(map['min_order_qty']),
      unitCostBase: optional(map['unit_cost_base']),
      costSource: map['cost_source']?.toString(),
      lastPurchaseAt: map['last_purchase_at'] == null
          ? null
          : DateTime.tryParse(map['last_purchase_at'].toString()),
    );
  }
}

class ReorderRepository {
  ReorderRepository(this._client);
  final SupabaseClient _client;

  /// Tri-estado de `fn_purchase_resolve_suppliers`. Estático: la función existe
  /// o no en el servidor, no por instancia.
  static bool? _resolverSupported;

  /// Suplidor, presentación y costo por insumo. Mapa vacío si la base no tiene
  /// la función (20260915_0003 sin aplicar): la pantalla sigue con la vista.
  Future<Map<String, ResolvedSupplier>> resolveSuppliers(
    String businessId,
    List<String> itemIds,
  ) async {
    if (itemIds.isEmpty || _resolverSupported == false) return const {};
    try {
      final rows = await _client.rpc(
        'fn_purchase_resolve_suppliers',
        params: {'p_business_id': businessId, 'p_item_ids': itemIds},
      );
      _resolverSupported = true;
      return {
        for (final row in (rows as List).whereType<Map>())
          row['item_id'].toString():
              ResolvedSupplier.fromMap(Map<String, dynamic>.from(row)),
      };
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' || e.code == '42883') {
        _resolverSupported = false;
        return const {};
      }
      rethrow;
    }
  }

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
