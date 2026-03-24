import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/data/models/sales_models.dart';

String _formatQty(double qty) {
  if ((qty - qty.roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(0);
  }
  if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(1);
  }
  return qty.toStringAsFixed(2);
}

List<OrderItem> _buildInvoiceItems(
  List<OrderItem> items,
  String receiptItemDisplayMode,
) {
  if (receiptItemDisplayMode != 'separate') {
    return items;
  }

  final expanded = <OrderItem>[];
  for (final item in items) {
    final roundedQty = item.quantity.roundToDouble();
    final isWholeQuantity = (item.quantity - roundedQty).abs() < 0.001;
    if (!isWholeQuantity || roundedQty <= 1) {
      expanded.add(item);
      continue;
    }

    final parts = roundedQty.toInt();
    final baseSubtotal = item.subtotal / parts;
    final baseDiscount = item.discounts / parts;
    final baseTax = item.tax / parts;
    final baseTotal = item.total / parts;
    double subtotalAccum = 0;
    double discountAccum = 0;
    double taxAccum = 0;
    double totalAccum = 0;

    for (var idx = 0; idx < parts; idx++) {
      final isLast = idx == parts - 1;
      final lineSubtotal = isLast
          ? item.subtotal - subtotalAccum
          : baseSubtotal;
      final lineDiscount = isLast
          ? item.discounts - discountAccum
          : baseDiscount;
      final lineTax = isLast ? item.tax - taxAccum : baseTax;
      final lineTotal = isLast ? item.total - totalAccum : baseTotal;
      expanded.add(
        item.copyWith(
          quantity: 1,
          subtotal: lineSubtotal,
          discounts: lineDiscount,
          tax: lineTax,
          total: lineTotal,
        ),
      );
      subtotalAccum += lineSubtotal;
      discountAccum += lineDiscount;
      taxAccum += lineTax;
      totalAccum += lineTotal;
    }
  }

  return expanded;
}

class InvoiceModal extends StatelessWidget {
  final Order order;
  final List<OrderItem> items;
  final List<Payment> payments;
  final String? tableName;
  final String? serverName;
  final String? businessName;
  final String? legalName;
  final String? businessAddress;
  final String? businessPhone;
  final String? businessRnc;
  final String? fiscalNcf;
  final String? fiscalTypeLabel;
  final String? customerName;
  final String? customerLegalName;
  final String? customerTaxId;
  final DateTime? issuedAt;
  final double change;
  final VoidCallback onNewSale;
  final VoidCallback onPrint;
  final String? checkId; // si se paga solo un check, filtramos
  final String receiptItemDisplayMode;

  const InvoiceModal({
    super.key,
    required this.order,
    required this.items,
    required this.payments,
    this.tableName,
    this.serverName,
    this.businessName,
    this.legalName,
    this.businessAddress,
    this.businessPhone,
    this.businessRnc,
    this.fiscalNcf,
    this.fiscalTypeLabel,
    this.customerName,
    this.customerLegalName,
    this.customerTaxId,
    this.issuedAt,
    required this.change,
    required this.onNewSale,
    required this.onPrint,
    this.checkId,
    this.receiptItemDisplayMode = 'grouped',
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');

    final baseItems = checkId == null
        ? items
        : items.where((i) => i.checkId == checkId).toList();
    final filteredItems = _buildInvoiceItems(baseItems, receiptItemDisplayMode);
    final filteredPayments = checkId == null
        ? payments
        : payments.where((p) => p.checkId == checkId).toList();
    final effectiveIssuedAt =
        issuedAt ??
        (filteredPayments.isNotEmpty
            ? filteredPayments
                  .map((payment) => payment.createdAt)
                  .reduce((a, b) => a.isAfter(b) ? a : b)
            : order.createdAt);

    final subtotal = filteredItems.fold<double>(0, (s, i) => s + i.subtotal);
    final tax = filteredItems.fold<double>(0, (s, i) => s + i.tax);
    final total = filteredItems.fold<double>(0, (s, i) => s + i.total);

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
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
                    Text(
                      businessName?.trim().isNotEmpty == true
                          ? businessName!.trim()
                          : 'Negocio',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (legalName?.trim().isNotEmpty == true &&
                        legalName != businessName)
                      Text(
                        legalName!.trim(),
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      ),
                    if (businessRnc?.trim().isNotEmpty == true)
                      Text('RNC: ${businessRnc!.trim()}'),
                    if (businessAddress?.trim().isNotEmpty == true)
                      Text(businessAddress!.trim()),
                    if (businessPhone?.trim().isNotEmpty == true)
                      Text('Tel: ${businessPhone!.trim()}'),
                    const SizedBox(height: 24),

                    // Invoice Details
                    _DetailRow(
                      'No. Factura:',
                      'FAC-${order.id.substring(0, 8).toUpperCase()}',
                    ),
                    if (fiscalNcf?.trim().isNotEmpty == true) ...[
                      if (fiscalTypeLabel != null)
                        _DetailRow('Tipo:', fiscalTypeLabel!),
                      _DetailRow('NCF:', fiscalNcf!.trim()),
                    ] else ...[
                      if (fiscalTypeLabel != null)
                        _DetailRow('Tipo:', fiscalTypeLabel!),
                    ],
                    if (customerName != null && customerName != 'Cliente')
                      _DetailRow('Cliente:', customerName!),
                    if (customerLegalName != null &&
                        customerLegalName!.isNotEmpty &&
                        customerLegalName != customerName)
                      _DetailRow('Razón Social:', customerLegalName!),
                    if (customerTaxId != null &&
                        customerTaxId != null &&
                        customerTaxId!.isNotEmpty)
                      _DetailRow('RNC/Cédula:', customerTaxId!),
                    _DetailRow('Fecha:', dateFormat.format(effectiveIssuedAt)),
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
                    ...filteredItems.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_formatQty(item.quantity)}x',
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

                    // Financial Breakdown (filtrado al check si aplica)
                    _SummaryRow('Subtotal', subtotal),
                    _SummaryRow('ITBIS (18%)', tax),
                    if (order.serviceFee > 0)
                      _SummaryRow(
                        'Propina Ley (10%)',
                        order.subtotal > 0
                            ? order.serviceFee * (subtotal / order.subtotal)
                            : 0,
                      ),
                    const SizedBox(height: 8),
                    _SummaryRow('TOTAL', total, isBold: true, fontSize: 18),

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
                    ...filteredPayments.map(
                      (p) => Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Método: ${_getMethodLabel(p)}'),
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
                          color: const Color(0xFF22C55E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF22C55E)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'CAMBIO',
                              style: TextStyle(
                                color: const Color(0xFF22C55E),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'RD\$ ${currency.format(change)}',
                              style: TextStyle(
                                color: const Color(0xFF22C55E),
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
                        side: const BorderSide(color: Color(0xFFF97316)),
                        foregroundColor: const Color(0xFFF97316),
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
                        backgroundColor: const Color(0xFFF97316),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.arrow_back_ios_new),
                      label: const Text('Volver a la cuenta'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        foregroundColor: Colors.black87,
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

  String _getMethodLabel(Payment payment) {
    final explicitName = payment.paymentMethodName?.trim();
    if (explicitName != null && explicitName.isNotEmpty) {
      return explicitName;
    }

    final methodCode =
        payment.paymentMethodCode?.toLowerCase().trim() ??
        payment.paymentMethodId.toLowerCase().trim();
    if (methodCode.contains('cash')) return 'Efectivo';
    if (methodCode.contains('card')) return 'Tarjeta';
    if (methodCode.contains('transfer')) return 'Transferencia';
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
