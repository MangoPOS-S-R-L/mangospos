// Sprint Inventario V1.1 — Fase B: transferencias entre bodegas.
// Modelos y estado del módulo de transferencias.

class StockTransferItem {
  final String id;
  final String itemId;
  final String itemName;
  final String unit;
  final double quantitySent;
  final double? quantityReceived;
  final double? costPerUnit;
  final String? varianceReason;

  const StockTransferItem({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.quantitySent,
    required this.quantityReceived,
    required this.costPerUnit,
    required this.varianceReason,
  });

  double get variance =>
      (quantityReceived ?? quantitySent) - quantitySent; // negativo = merma

  factory StockTransferItem.fromMap(Map<String, dynamic> map) {
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

    final itemMap = map['inventory_items'];
    final itemName = itemMap is Map
        ? (itemMap['name']?.toString() ?? 'Insumo')
        : (map['item_name']?.toString() ?? 'Insumo');
    final unit = itemMap is Map
        ? (itemMap['unit']?.toString() ?? 'unidad')
        : (map['item_unit']?.toString() ?? 'unidad');

    return StockTransferItem(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: itemName,
      unit: unit,
      quantitySent: toDouble(map['quantity_sent']),
      quantityReceived: toNullableDouble(map['quantity_received']),
      costPerUnit: toNullableDouble(map['cost_per_unit']),
      varianceReason: map['variance_reason']?.toString(),
    );
  }
}

enum StockTransferStatus { pendingApproval, sent, received, cancelled, unknown }

extension StockTransferStatusX on StockTransferStatus {
  String get wire {
    switch (this) {
      case StockTransferStatus.pendingApproval:
        return 'pending_approval';
      case StockTransferStatus.sent:
        return 'sent';
      case StockTransferStatus.received:
        return 'received';
      case StockTransferStatus.cancelled:
        return 'cancelled';
      case StockTransferStatus.unknown:
        return 'unknown';
    }
  }

  String get label {
    switch (this) {
      case StockTransferStatus.pendingApproval:
        return 'Pendiente de aprobación';
      case StockTransferStatus.sent:
        return 'En tránsito';
      case StockTransferStatus.received:
        return 'Recibida';
      case StockTransferStatus.cancelled:
        return 'Cancelada';
      case StockTransferStatus.unknown:
        return 'Desconocido';
    }
  }
}

StockTransferStatus _parseStatus(String? raw) {
  switch (raw) {
    case 'pending_approval':
      return StockTransferStatus.pendingApproval;
    case 'sent':
      return StockTransferStatus.sent;
    case 'received':
      return StockTransferStatus.received;
    case 'cancelled':
      return StockTransferStatus.cancelled;
    default:
      return StockTransferStatus.unknown;
  }
}

class StockTransfer {
  final String id;
  final String businessId;
  final String fromBusinessId;
  final String? fromBusinessName;
  final String toBusinessId;
  final String? toBusinessName;
  final bool isCrossBusiness;
  final String transferNumber;
  final StockTransferStatus status;
  final String fromWarehouseId;
  final String fromWarehouseName;
  final String toWarehouseId;
  final String toWarehouseName;
  final DateTime? sentAt;
  final DateTime? receivedAt;
  final DateTime? cancelledAt;
  final DateTime? approvedAt;
  final String? approvedByName;
  final String? notes;
  final String? createdByName;
  final String? receivedByName;
  final int itemCount;
  final double totalSent;
  final double totalReceived;
  final List<StockTransferItem> items; // vacía si vino del listado

  const StockTransfer({
    required this.id,
    required this.businessId,
    required this.fromBusinessId,
    required this.toBusinessId,
    required this.isCrossBusiness,
    required this.transferNumber,
    required this.status,
    required this.fromWarehouseId,
    required this.fromWarehouseName,
    required this.toWarehouseId,
    required this.toWarehouseName,
    required this.sentAt,
    required this.receivedAt,
    required this.cancelledAt,
    required this.notes,
    required this.createdByName,
    required this.receivedByName,
    required this.itemCount,
    required this.totalSent,
    required this.totalReceived,
    this.fromBusinessName,
    this.toBusinessName,
    this.items = const [],
    this.approvedAt,
    this.approvedByName,
  });

  bool get needsApproval =>
      status == StockTransferStatus.pendingApproval;
  bool get isInTransit => status == StockTransferStatus.sent;
  bool get isPending => status == StockTransferStatus.sent;
  bool get hasVariance => totalReceived < totalSent && status == StockTransferStatus.received;

  /// Indica si el negocio activo es el destinatario (incoming) o el emisor.
  bool isIncomingFor(String activeBusinessId) =>
      isCrossBusiness && toBusinessId == activeBusinessId;

  StockTransfer copyWith({List<StockTransferItem>? items}) {
    return StockTransfer(
      id: id,
      businessId: businessId,
      fromBusinessId: fromBusinessId,
      fromBusinessName: fromBusinessName,
      toBusinessId: toBusinessId,
      toBusinessName: toBusinessName,
      isCrossBusiness: isCrossBusiness,
      transferNumber: transferNumber,
      status: status,
      fromWarehouseId: fromWarehouseId,
      fromWarehouseName: fromWarehouseName,
      toWarehouseId: toWarehouseId,
      toWarehouseName: toWarehouseName,
      sentAt: sentAt,
      receivedAt: receivedAt,
      cancelledAt: cancelledAt,
      notes: notes,
      createdByName: createdByName,
      receivedByName: receivedByName,
      itemCount: itemCount,
      totalSent: totalSent,
      totalReceived: totalReceived,
      items: items ?? this.items,
      approvedAt: approvedAt,
      approvedByName: approvedByName,
    );
  }

  /// Parsea desde la vista `v_inventory_transfers_log`.
  factory StockTransfer.fromLogMap(Map<String, dynamic> map) {
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

    final businessId = map['business_id']?.toString() ?? '';
    final fromBusinessId = map['from_business_id']?.toString() ?? businessId;
    final toBusinessId = map['to_business_id']?.toString() ?? businessId;
    final bool isCross = map['is_cross_business'] is bool
        ? map['is_cross_business'] as bool
        : fromBusinessId.isNotEmpty &&
              toBusinessId.isNotEmpty &&
              fromBusinessId != toBusinessId;

    return StockTransfer(
      id: map['transfer_id']?.toString() ?? '',
      businessId: businessId,
      fromBusinessId: fromBusinessId,
      fromBusinessName: map['from_business_name']?.toString(),
      toBusinessId: toBusinessId,
      toBusinessName: map['to_business_name']?.toString(),
      isCrossBusiness: isCross,
      transferNumber: map['transfer_number']?.toString() ?? '',
      status: _parseStatus(map['status']?.toString()),
      fromWarehouseId: map['from_warehouse_id']?.toString() ?? '',
      fromWarehouseName: map['from_warehouse_name']?.toString() ?? 'Almacén',
      toWarehouseId: map['to_warehouse_id']?.toString() ?? '',
      toWarehouseName: map['to_warehouse_name']?.toString() ?? 'Almacén',
      sentAt: DateTime.tryParse(map['sent_at']?.toString() ?? ''),
      receivedAt: DateTime.tryParse(map['received_at']?.toString() ?? ''),
      cancelledAt: DateTime.tryParse(map['cancelled_at']?.toString() ?? ''),
      approvedAt: DateTime.tryParse(map['approved_at']?.toString() ?? ''),
      approvedByName: map['approved_by_name']?.toString(),
      notes: map['notes']?.toString(),
      createdByName: map['created_by_name']?.toString(),
      receivedByName: map['received_by_name']?.toString(),
      itemCount: toInt(map['item_count']),
      totalSent: toDouble(map['total_sent']),
      totalReceived: toDouble(map['total_received']),
    );
  }
}

class TransfersState {
  /// Tamaño de página para la lista de transferencias.
  static const pageSize = 50;

  final bool loading;
  final bool loadingMore;
  final bool saving;
  final String? error;
  final String? businessId;
  final List<StockTransfer> transfers;
  final bool hasMore;

  const TransfersState({
    this.loading = false,
    this.loadingMore = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.transfers = const [],
    this.hasMore = false,
  });

  TransfersState copyWith({
    bool? loading,
    bool? loadingMore,
    bool? saving,
    String? error,
    String? businessId,
    List<StockTransfer>? transfers,
    bool? hasMore,
    bool clearError = false,
  }) {
    return TransfersState(
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      transfers: transfers ?? this.transfers,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}
