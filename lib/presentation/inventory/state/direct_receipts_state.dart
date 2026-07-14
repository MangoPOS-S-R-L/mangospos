// Sprint 4 Inventario — Estado de recepciones directas (sin OC).

enum DirectReceiptStatus { received, cancelled, unknown }

DirectReceiptStatus _parseStatus(String? raw) {
  switch (raw) {
    case 'received':
      return DirectReceiptStatus.received;
    case 'cancelled':
      return DirectReceiptStatus.cancelled;
    default:
      return DirectReceiptStatus.unknown;
  }
}

class DirectReceipt {
  final String id;
  final String businessId;
  final String warehouseId;
  final String warehouseName;
  final String? supplierId;
  final String? supplierName;
  final String receiptNumber;
  final DirectReceiptStatus status;
  final double total;
  final String? notes;
  final String? cancelReason;
  final String? createdBy;
  final String? createdByName;
  final String? cancelledBy;
  final String? cancelledByName;
  final DateTime? createdAt;
  final DateTime? cancelledAt;
  final int itemCount;
  final double totalQuantity;
  final List<DirectReceiptLine> items; // vacía si vino del listado

  const DirectReceipt({
    required this.id,
    required this.businessId,
    required this.warehouseId,
    required this.warehouseName,
    required this.supplierId,
    required this.supplierName,
    required this.receiptNumber,
    required this.status,
    required this.total,
    required this.notes,
    required this.cancelReason,
    required this.createdBy,
    required this.createdByName,
    required this.cancelledBy,
    required this.cancelledByName,
    required this.createdAt,
    required this.cancelledAt,
    required this.itemCount,
    required this.totalQuantity,
    this.items = const [],
  });

  bool get isCancellable => status == DirectReceiptStatus.received;

  DirectReceipt copyWith({List<DirectReceiptLine>? items}) {
    return DirectReceipt(
      id: id,
      businessId: businessId,
      warehouseId: warehouseId,
      warehouseName: warehouseName,
      supplierId: supplierId,
      supplierName: supplierName,
      receiptNumber: receiptNumber,
      status: status,
      total: total,
      notes: notes,
      cancelReason: cancelReason,
      createdBy: createdBy,
      createdByName: createdByName,
      cancelledBy: cancelledBy,
      cancelledByName: cancelledByName,
      createdAt: createdAt,
      cancelledAt: cancelledAt,
      itemCount: itemCount,
      totalQuantity: totalQuantity,
      items: items ?? this.items,
    );
  }

  factory DirectReceipt.fromLogMap(Map<String, dynamic> map) {
    double toDouble(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    int toInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString()) ?? 0;
    }

    return DirectReceipt(
      id: map['receipt_id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      warehouseId: map['warehouse_id']?.toString() ?? '',
      warehouseName: map['warehouse_name']?.toString() ?? 'Almacén',
      supplierId: map['supplier_id']?.toString(),
      supplierName: map['supplier_name']?.toString(),
      receiptNumber: map['receipt_number']?.toString() ?? '',
      status: _parseStatus(map['status']?.toString()),
      total: toDouble(map['total']),
      notes: map['notes']?.toString(),
      cancelReason: map['cancel_reason']?.toString(),
      createdBy: map['created_by']?.toString(),
      createdByName: map['created_by_name']?.toString(),
      cancelledBy: map['cancelled_by']?.toString(),
      cancelledByName: map['cancelled_by_name']?.toString(),
      createdAt: DateTime.tryParse(map['created_at']?.toString() ?? ''),
      cancelledAt: DateTime.tryParse(map['cancelled_at']?.toString() ?? ''),
      itemCount: toInt(map['item_count']),
      totalQuantity: toDouble(map['total_quantity']),
    );
  }
}

class DirectReceiptLine {
  final String id;
  final String itemId;
  final String itemName;
  final String itemSku;
  final String unit;
  final double quantity;
  final double? unitCost;
  final double lineTotal;
  final String? notes;

  const DirectReceiptLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.itemSku,
    required this.unit,
    required this.quantity,
    required this.unitCost,
    required this.lineTotal,
    required this.notes,
  });

  factory DirectReceiptLine.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    double? toNullableDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final itemRel = map['inventory_items'];
    final itemName = itemRel is Map
        ? (itemRel['name']?.toString() ?? '—')
        : '—';
    final itemSku = itemRel is Map ? (itemRel['sku']?.toString() ?? '') : '';
    final unit = itemRel is Map
        ? (itemRel['unit']?.toString() ?? 'unidad')
        : 'unidad';

    return DirectReceiptLine(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: itemName,
      itemSku: itemSku,
      unit: unit,
      quantity: toDouble(map['quantity']),
      unitCost: toNullableDouble(map['unit_cost']),
      lineTotal: toDouble(map['line_total']),
      notes: map['notes']?.toString(),
    );
  }
}

class DirectReceiptsState {
  /// Tamaño de página de la lista de recepciones.
  static const pageSize = 50;

  final bool loading;
  final bool loadingMore;
  final bool saving;
  final String? error;
  final String? businessId;
  final String? statusFilter; // 'received' | 'cancelled' | null
  // Búsqueda libre (número de recepción, proveedor o bodega); server-side.
  final String? searchQuery;
  final List<DirectReceipt> receipts;
  final bool hasMore;

  const DirectReceiptsState({
    this.loading = false,
    this.loadingMore = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.statusFilter,
    this.searchQuery,
    this.receipts = const [],
    this.hasMore = false,
  });

  bool get hasSearch => searchQuery != null && searchQuery!.trim().isNotEmpty;

  DirectReceiptsState copyWith({
    bool? loading,
    bool? loadingMore,
    bool? saving,
    String? error,
    String? businessId,
    String? statusFilter,
    String? searchQuery,
    List<DirectReceipt>? receipts,
    bool? hasMore,
    bool clearError = false,
    bool clearStatusFilter = false,
    bool clearSearchQuery = false,
  }) {
    return DirectReceiptsState(
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      statusFilter: clearStatusFilter
          ? null
          : (statusFilter ?? this.statusFilter),
      searchQuery: clearSearchQuery ? null : (searchQuery ?? this.searchQuery),
      receipts: receipts ?? this.receipts,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}
