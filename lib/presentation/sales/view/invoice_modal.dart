import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/data/models/sales_models.dart';

class InvoiceModal extends StatelessWidget {
  final Order order;
  final List<OrderItem> items;
  final List<Payment> payments;
  final String? tableName;
  final String? serverName;
  final double change;
  final VoidCallback onNewSale;
  final VoidCallback onPrint;

  const InvoiceModal({
    super.key,
    required this.order,
    required this.items,
    required this.payments,
    this.tableName,
    this.serverName,
    required this.change,
    required this.onNewSale,
    required this.onPrint,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 800),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Success Header
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: const BoxDecoration(
                color: Color(0xFF22C55E),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white, size: 64),
                  const SizedBox(height: 12),
                  const Text(
                    '¡Pago Completado!',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Business Info
                    const Text(
                      'MangoPOS Restaurant',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text('RNC: 123456789'),
                    const Text('Av. Principal #123, Santo Domingo'),
                    const Text('Tel: (809) 555-0123'),
                    const SizedBox(height: 24),

                    // Invoice Details
                    _DetailRow(
                      'No. Factura:',
                      'FAC-${order.id.substring(0, 8).toUpperCase()}',
                    ),
                    _DetailRow('NCF:', 'B0100000001'), // Placeholder
                    _DetailRow('Fecha:', dateFormat.format(DateTime.now())),
                    if (tableName != null) _DetailRow('Mesa:', tableName!),
                    if (serverName != null)
                      _DetailRow('Camarero:', serverName!),

                    const Divider(height: 32),

                    // Order Summary
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Resumen de Orden',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...items.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${item.quantity.toInt()}x',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.productName),
                                  if (item.modifiers.isNotEmpty)
                                    ...item.modifiers.map(
                                      (m) => Text(
                                        '+ ${m.name}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Text('RD\$ ${currency.format(item.total)}'),
                          ],
                        ),
                      ),
                    ),

                    const Divider(height: 32),

                    // Financial Breakdown
                    _SummaryRow('Subtotal', order.subtotal),
                    _SummaryRow('ITBIS (18%)', order.tax),
                    if (order.serviceFee > 0)
                      _SummaryRow('Propina Ley (10%)', order.serviceFee),
                    const SizedBox(height: 8),
                    _SummaryRow(
                      'TOTAL',
                      order.total,
                      isBold: true,
                      fontSize: 18,
                    ),

                    const Divider(height: 32),

                    // Payment Proof
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Detalle de Pago',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...payments.map(
                      (p) => Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Método: ${_getMethodLabel(p.paymentMethodId)}'),
                          Text('RD\$ ${currency.format(p.amount)}'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (change > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 8,
                          horizontal: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green[50],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green[200]!),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'CAMBIO',
                              style: TextStyle(
                                color: Colors.green[800],
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'RD\$ ${currency.format(change)}',
                              style: TextStyle(
                                color: Colors.green[800],
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Actions
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onPrint,
                      icon: const Icon(Icons.print),
                      label: const Text('Imprimir'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: const BorderSide(color: Color(0xFFFB7116)),
                        foregroundColor: const Color(0xFFFB7116),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: onNewSale,
                      icon: const Icon(Icons.add_shopping_cart),
                      label: const Text('Nueva Venta'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(
                          0xFFFB7116,
                        ), // Mango Orange
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getMethodLabel(String methodId) {
    if (methodId.contains('cash')) return 'Efectivo';
    if (methodId.contains('card')) return 'Tarjeta';
    if (methodId.contains('transfer')) return 'Transferencia';
    return 'Otro';
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final double value;
  final bool isBold;
  final double fontSize;

  const _SummaryRow(
    this.label,
    this.value, {
    this.isBold = false,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            'RD\$ ${currency.format(value)}',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
