import 'package:flutter/foundation.dart';

/// Una sucursal de la cadena (otro `business_id` del mismo dueño).
@immutable
class ConsolidatedBranch {
  final String businessId;
  final String name;

  const ConsolidatedBranch({required this.businessId, required this.name});

  factory ConsolidatedBranch.fromMap(Map<String, dynamic> m) {
    final name = m['name']?.toString().trim() ?? '';
    return ConsolidatedBranch(
      businessId: m['business_id']?.toString() ?? '',
      name: name.isEmpty ? 'Sucursal' : name,
    );
  }
}

/// Un producto consolidado (emparejado por SKU) con su stock por sucursal.
@immutable
class ConsolidatedProduct {
  final String? sku;
  final String name;
  final String? unit;
  final double totalQty;
  final double totalValue;

  /// businessId → cantidad en esa sucursal.
  final Map<String, double> qtyByBranch;

  /// businessId → stock mínimo configurado en esa sucursal (si lo hay).
  final Map<String, double> minByBranch;

  const ConsolidatedProduct({
    required this.sku,
    required this.name,
    required this.unit,
    required this.totalQty,
    required this.totalValue,
    required this.qtyByBranch,
    required this.minByBranch,
  });

  factory ConsolidatedProduct.fromMap(Map<String, dynamic> m) {
    final qty = <String, double>{};
    final min = <String, double>{};
    final byBranch = m['by_branch'];
    if (byBranch is List) {
      for (final e in byBranch) {
        if (e is! Map) continue;
        final bid = e['business_id']?.toString() ?? '';
        if (bid.isEmpty) continue;
        qty[bid] = (e['qty'] as num?)?.toDouble() ?? 0;
        final ms = (e['min_stock'] as num?)?.toDouble();
        if (ms != null) min[bid] = ms;
      }
    }
    final sku = m['sku']?.toString().trim();
    final unit = m['unit']?.toString().trim();
    return ConsolidatedProduct(
      sku: (sku == null || sku.isEmpty) ? null : sku,
      name: m['name']?.toString() ?? '—',
      unit: (unit == null || unit.isEmpty) ? null : unit,
      totalQty: (m['total_qty'] as num?)?.toDouble() ?? 0,
      totalValue: (m['total_value'] as num?)?.toDouble() ?? 0,
      qtyByBranch: qty,
      minByBranch: min,
    );
  }

  double qtyFor(String businessId) => qtyByBranch[businessId] ?? 0;
  double? minFor(String businessId) => minByBranch[businessId];

  /// True si la sucursal está por debajo del mínimo configurado.
  bool isLowAt(String businessId) {
    final m = minByBranch[businessId];
    if (m == null || m <= 0) return false;
    return qtyFor(businessId) < m;
  }
}

@immutable
class ConsolidatedInventoryState {
  final bool loading;
  final String? error;
  final String? businessId;
  final List<ConsolidatedBranch> branches;
  final List<ConsolidatedProduct> products;

  const ConsolidatedInventoryState({
    this.loading = false,
    this.error,
    this.businessId,
    this.branches = const [],
    this.products = const [],
  });

  double get totalValue =>
      products.fold(0.0, (sum, p) => sum + p.totalValue);

  ConsolidatedInventoryState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    String? businessId,
    List<ConsolidatedBranch>? branches,
    List<ConsolidatedProduct>? products,
  }) {
    return ConsolidatedInventoryState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      branches: branches ?? this.branches,
      products: products ?? this.products,
    );
  }
}
