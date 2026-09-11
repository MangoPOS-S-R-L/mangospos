import 'package:equatable/equatable.dart';

/// NOTA DE VENTA: documento de venta **no fiscal**, numerado por negocio
/// (`NV-000123`).
///
/// Ampara una venta real — descuenta inventario, entra a caja y suma en
/// ventas — pero no consume NCF, no se declara a la DGII y no aparece en el
/// 607. Por eso vive en `sales_notes` y no en `fiscal_documents`: esa tabla es
/// la fuente del reporte fiscal, y meterle un documento sin valor fiscal
/// ensuciaría lo que se le declara a la DGII.
///
/// La emite la BD al cerrar el contenedor cobrado (sub-cuenta u orden), en el
/// mismo punto donde una venta normal emitiría su NCF. Ver la migración
/// `20260910_0001_sales_notes.sql`.
class SalesNote extends Equatable {
  final String id;
  final String businessId;
  final String orderId;

  /// Sub-cuenta a la que pertenece (split bill). `null` = orden completa.
  final String? checkId;

  /// Número correlativo con su prefijo, tal como se imprime: `NV-000123`.
  final String noteNumber;

  final String? customerId;
  final String customerName;
  final String? customerRnc;

  final double subtotal;
  final double discount;
  final double tax;
  final double serviceFee;
  final double total;

  /// `active` | `cancelled`.
  final String status;
  final DateTime issuedAt;

  const SalesNote({
    required this.id,
    required this.businessId,
    required this.orderId,
    this.checkId,
    required this.noteNumber,
    this.customerId,
    required this.customerName,
    this.customerRnc,
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.serviceFee,
    required this.total,
    required this.status,
    required this.issuedAt,
  });

  static double _toDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  factory SalesNote.fromMap(Map<String, dynamic> map) {
    return SalesNote(
      id: map['id'].toString(),
      businessId: map['business_id'].toString(),
      orderId: map['order_id'].toString(),
      checkId: map['check_id']?.toString(),
      noteNumber: map['note_number']?.toString() ?? '',
      customerId: map['customer_id']?.toString(),
      customerName: map['customer_name']?.toString().trim().isNotEmpty == true
          ? map['customer_name'].toString()
          : 'Consumidor Final',
      customerRnc: map['customer_rnc']?.toString(),
      subtotal: _toDouble(map['subtotal']),
      discount: _toDouble(map['discount']),
      tax: _toDouble(map['tax']),
      serviceFee: _toDouble(map['service_fee']),
      total: _toDouble(map['total']),
      status: map['status']?.toString() ?? 'active',
      issuedAt:
          DateTime.tryParse(map['issued_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }

  bool get isActive => status == 'active';

  @override
  List<Object?> get props => [
    id,
    businessId,
    orderId,
    checkId,
    noteNumber,
    customerId,
    customerName,
    customerRnc,
    subtotal,
    discount,
    tax,
    serviceFee,
    total,
    status,
    issuedAt,
  ];
}
