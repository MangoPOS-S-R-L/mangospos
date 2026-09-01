// F2 — Requisición de mercancía: la cocina pide, el almacén despacha.
//
// Modelos del módulo. El stock lo mueve la transferencia que dispara el
// despacho (ver 20260902_0001_requisitions.sql); acá vive el documento.

/// Estados por los que pasa una requisición.
///
/// `partial` no es un error: es la respuesta honesta del almacén cuando no
/// tenía todo. El faltante queda a la vista para reclamarlo.
enum RequisitionStatus {
  pending,
  partial,
  dispatched,
  received,
  cancelled;

  static RequisitionStatus fromWire(String? raw) {
    switch (raw) {
      case 'partial':
        return RequisitionStatus.partial;
      case 'dispatched':
        return RequisitionStatus.dispatched;
      case 'received':
        return RequisitionStatus.received;
      case 'cancelled':
        return RequisitionStatus.cancelled;
      default:
        return RequisitionStatus.pending;
    }
  }

  String get wire => name;

  String get label {
    switch (this) {
      case RequisitionStatus.pending:
        return 'Por despachar';
      case RequisitionStatus.partial:
        return 'Despachada parcial';
      case RequisitionStatus.dispatched:
        return 'Despachada';
      case RequisitionStatus.received:
        return 'Recibida';
      case RequisitionStatus.cancelled:
        return 'Cancelada';
    }
  }

  /// Le toca actuar al almacén de origen.
  bool get esperaDespacho => this == RequisitionStatus.pending;

  /// Le toca actuar a quien pidió: confirmar lo que llegó.
  bool get esperaRecepcion =>
      this == RequisitionStatus.dispatched || this == RequisitionStatus.partial;

  bool get cerrada =>
      this == RequisitionStatus.received || this == RequisitionStatus.cancelled;
}

class RequisitionLine {
  final String id;
  final String itemId;
  final String itemName;
  final String unit;
  final double requestedQty;

  /// `null` = todavía no se despachó. `0` = se despachó la requisición y de
  /// esta línea no había nada. Son respuestas distintas y la pantalla las
  /// muestra distinto.
  final double? dispatchedQty;
  final double? receivedQty;
  final String? lineNotes;

  const RequisitionLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.requestedQty,
    this.dispatchedQty,
    this.receivedQty,
    this.lineNotes,
  });

  /// Lo que se pidió y no llegó. Cero si todavía no se despachó — un
  /// faltante solo existe después de que alguien miró la solicitud.
  double get faltante {
    final d = dispatchedQty;
    if (d == null) return 0;
    final f = requestedQty - d;
    return f > 0 ? f : 0;
  }

  bool get tieneFaltante => faltante > 0;

  factory RequisitionLine.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic v) {
      if (v == null) return 0;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString()) ?? 0;
    }

    double? toNullable(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final item = map['inventory_items'];
    return RequisitionLine(
      id: map['id']?.toString() ?? '',
      itemId: map['item_id']?.toString() ?? '',
      itemName: item is Map
          ? (item['name']?.toString() ?? 'Insumo')
          : (map['item_name']?.toString() ?? 'Insumo'),
      unit: map['unit']?.toString() ??
          (item is Map ? (item['unit']?.toString() ?? 'unidad') : 'unidad'),
      requestedQty: toDouble(map['requested_qty']),
      dispatchedQty: toNullable(map['dispatched_qty']),
      receivedQty: toNullable(map['received_qty']),
      lineNotes: map['line_notes']?.toString(),
    );
  }
}

class Requisition {
  final String id;
  final String businessId;
  final String code;
  final RequisitionStatus status;
  final String fromWarehouseId;
  final String fromWarehouseName;
  final String toWarehouseId;
  final String toWarehouseName;
  final String? transferId;
  final DateTime? requestedAt;
  final DateTime? dispatchedAt;
  final DateTime? receivedAt;
  final String? cancelReason;
  final String? notes;

  /// Las líneas se cargan aparte (la bandeja no las necesita).
  final List<RequisitionLine> lines;

  const Requisition({
    required this.id,
    required this.businessId,
    required this.code,
    required this.status,
    required this.fromWarehouseId,
    required this.fromWarehouseName,
    required this.toWarehouseId,
    required this.toWarehouseName,
    this.transferId,
    this.requestedAt,
    this.dispatchedAt,
    this.receivedAt,
    this.cancelReason,
    this.notes,
    this.lines = const [],
  });

  Requisition copyWith({List<RequisitionLine>? lines}) => Requisition(
        id: id,
        businessId: businessId,
        code: code,
        status: status,
        fromWarehouseId: fromWarehouseId,
        fromWarehouseName: fromWarehouseName,
        toWarehouseId: toWarehouseId,
        toWarehouseName: toWarehouseName,
        transferId: transferId,
        requestedAt: requestedAt,
        dispatchedAt: dispatchedAt,
        receivedAt: receivedAt,
        cancelReason: cancelReason,
        notes: notes,
        lines: lines ?? this.lines,
      );

  factory Requisition.fromMap(Map<String, dynamic> map) {
    String nombreBodega(dynamic embedded, String fallback) {
      if (embedded is Map) return embedded['name']?.toString() ?? fallback;
      return fallback;
    }

    return Requisition(
      id: map['id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      code: map['code']?.toString() ?? '',
      status: RequisitionStatus.fromWire(map['status']?.toString()),
      fromWarehouseId: map['from_warehouse_id']?.toString() ?? '',
      fromWarehouseName: nombreBodega(map['from_warehouse'], 'Bodega origen'),
      toWarehouseId: map['to_warehouse_id']?.toString() ?? '',
      toWarehouseName: nombreBodega(map['to_warehouse'], 'Bodega destino'),
      transferId: map['transfer_id']?.toString(),
      requestedAt: DateTime.tryParse(map['requested_at']?.toString() ?? ''),
      dispatchedAt: DateTime.tryParse(map['dispatched_at']?.toString() ?? ''),
      receivedAt: DateTime.tryParse(map['received_at']?.toString() ?? ''),
      cancelReason: map['cancel_reason']?.toString(),
      notes: map['notes']?.toString(),
    );
  }
}
