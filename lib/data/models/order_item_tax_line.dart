import 'package:equatable/equatable.dart';

/// Mirror del row de `public.order_item_tax_lines` (PRD 2 §6.1).
///
/// Cada fila es un snapshot inmutable del impuesto aplicado a un item al
/// momento de la venta. `taxName` y `taxRate` se persisten al crear la
/// fila — si después se renombra o se cambia la tasa del impuesto, los
/// datos históricos no cambian.
///
/// Producto del PRD 2: el frontend usa estas líneas para construir el
/// desglose de impuestos en mesa, ticket, factura y modal de pago.
class OrderItemTaxLine extends Equatable {
  final String id;
  final String orderItemId;
  final String taxId;
  final String taxName;

  /// Tasa en porcentaje (ej: 18.0 para 18%, 10.0 para 10% de Propina).
  final double taxRate;

  /// Monto cobrado por este impuesto en este item (subtotal × rate / 100).
  final double amount;

  final DateTime createdAt;

  const OrderItemTaxLine({
    required this.id,
    required this.orderItemId,
    required this.taxId,
    required this.taxName,
    required this.taxRate,
    required this.amount,
    required this.createdAt,
  });

  factory OrderItemTaxLine.fromMap(Map<String, dynamic> map) {
    return OrderItemTaxLine(
      id: map['id'] ?? '',
      orderItemId: map['order_item_id'] ?? '',
      taxId: map['tax_id'] ?? '',
      taxName: map['tax_name']?.toString() ?? '',
      taxRate: (map['tax_rate'] ?? 0).toDouble(),
      amount: (map['amount'] ?? 0).toDouble(),
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [
    id,
    orderItemId,
    taxId,
    taxName,
    taxRate,
    amount,
    createdAt,
  ];
}
