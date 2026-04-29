import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';

/// 🧾 Panel de totales de la orden.
///
/// Muestra: Subtotal + breakdown de impuestos (desde tax_lines del PRD 2,
/// con fallback heurístico para órdenes pre-PRD-2) + descuentos + Total.
///
/// Se usa por OrderScreen (Quick/Manual) y futuras vistas alternativas.
/// La vista de zona (`table_order_screen.dart`) usa su propio
/// `_SummaryRow` interno por la regla cardinal del PRD 4.
class OrderSummaryPanel extends StatelessWidget {
  final Order order;
  final List<OrderItem> items;

  /// Origin opcional para forzar el cálculo de impuestos contra ese canal.
  /// Si es null, se usa `order.origin`.
  final String? forcedOrigin;

  /// Padding interno del panel. La vista que lo embebe puede ajustarlo
  /// según el layout (ej. 12 en móvil, 24 en desktop).
  final EdgeInsets padding;

  const OrderSummaryPanel({
    super.key,
    required this.order,
    required this.items,
    this.forcedOrigin,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');
    final summary = summarizeOrderPricing(
      order,
      items,
      forcedOrigin: forcedOrigin ?? order.origin,
    );
    final breakdown = buildOrderTaxBreakdown(
      order,
      items,
      forcedOrigin: forcedOrigin ?? order.origin,
    );

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB), width: 1)),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _row('Subtotal', 'RD\$ ${currency.format(summary.subtotal)}'),
            for (final entry in breakdown) ...[
              const SizedBox(height: 8),
              _row(entry.label, 'RD\$ ${currency.format(entry.amount)}'),
            ],
            if (summary.discounts > 0) ...[
              const SizedBox(height: 8),
              _row(
                'Descuento',
                '- RD\$ ${currency.format(summary.discounts)}',
                valueColor: const Color(0xFF16A34A),
                valueWeight: FontWeight.w700,
              ),
            ],
            const SizedBox(height: 12),
            _row(
              'Total',
              'RD\$ ${currency.format(summary.total)}',
              valueColor: const Color(0xFFF97316),
              valueWeight: FontWeight.w700,
              labelWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    String label,
    String value, {
    Color? valueColor,
    FontWeight valueWeight = FontWeight.w500,
    FontWeight labelWeight = FontWeight.w500,
    double fontSize = 14,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: fontSize, fontWeight: labelWeight),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: valueWeight,
            color: valueColor ?? const Color(0xFF2C2C2C),
          ),
        ),
      ],
    );
  }
}
