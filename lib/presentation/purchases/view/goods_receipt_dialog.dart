// Conduce de recepción en pantalla + las acciones que lo sacan en papel.
//
// Se abre en dos momentos: justo después de recibir (con el conduce recién
// emitido) y al reimprimir uno viejo desde el detalle de la orden. La misma
// pantalla para los dos casos, porque es el mismo documento.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../state/goods_receipt.dart';
import '../state/purchases_state.dart';
import '../utils/goods_receipt_printing.dart';
import 'purchase_receive_dialog.dart';

/// Abre el diálogo de recepción y, si se emitió conduce, lo imprime y lo
/// muestra. Devuelve `true` si hubo recepción (para que la pantalla recargue).
///
/// Centraliza el "recibir → imprimir → mostrar" porque se dispara desde el
/// listado y desde el detalle: dos copias se desincronizarían.
Future<bool> showPurchaseReceiveFlow(
  BuildContext context,
  WidgetRef ref,
  PurchaseOrderSummary order,
) async {
  final receipt = await showDialog<GoodsReceipt>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PurchaseReceiveDialog(order: order),
  );
  if (receipt == null || !context.mounted) {
    // null = cancelado, o recibido por la ruta vieja (sin documento). El
    // diálogo ya avisó; acá no hay conduce que imprimir.
    return receipt != null;
  }

  // El papel sale solo: el almacenista no debería tener que pedirlo.
  await GoodsReceiptPrinting.printThermal(context, ref, receipt: receipt);
  if (!context.mounted) return true;
  await showGoodsReceiptDialog(context, ref, receipt: receipt);
  return true;
}

/// Muestra el conduce con las tres salidas: térmica, PDF e imprimir PDF.
Future<void> showGoodsReceiptDialog(
  BuildContext context,
  WidgetRef ref, {
  required GoodsReceipt receipt,
  bool isReprint = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _GoodsReceiptDialog(receipt: receipt, isReprint: isReprint),
  );
}

class _GoodsReceiptDialog extends ConsumerWidget {
  final GoodsReceipt receipt;
  final bool isReprint;

  const _GoodsReceiptDialog({required this.receipt, required this.isReprint});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = currentBusinessCurrencyOrFallback(ref);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.receipt_long_rounded, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Conduce ${receipt.number.isEmpty ? "s/n" : receipt.number}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (receipt.isPartial)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Entrega parcial: la orden todavía tiene mercancía '
                    'pendiente.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                  ),
                ),
              _field('Suplidor', receipt.supplierName),
              _field('Almacén', receipt.warehouseName),
              if (receipt.orderNumber.isNotEmpty)
                _field('Orden de compra', receipt.orderNumber),
              if (receipt.invoiceNumber.isNotEmpty)
                _field('Factura', receipt.invoiceNumber),
              if (receipt.ncf.isNotEmpty) _field('NCF', receipt.ncf),
              if (receipt.receivedByName.isNotEmpty)
                _field('Recibido por', receipt.receivedByName),
              const Divider(height: 20),
              for (final line in receipt.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              line.description,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              '${_qty(line.quantity)} ${line.unit}'
                              '  ×  ${money.formatAmount(line.unitCost)}'
                              '${line.code.isEmpty ? "" : "   ·   ${line.code}"}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        money.formatAmount(line.amount),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${receipt.lines.length} renglones · '
                    '${_qty(receipt.totalUnits)} unidades',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  Text(
                    money.formatAmount(receipt.total),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              if (receipt.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  receipt.notes.trim(),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actionsOverflowButtonSpacing: 6,
      actions: [
        TextButton.icon(
          onPressed: () => GoodsReceiptPrinting.printThermal(
            context,
            ref,
            receipt: receipt,
            isReprint: true,
          ),
          icon: const Icon(Icons.print_outlined, size: 18),
          label: const Text('Ticket'),
        ),
        TextButton.icon(
          onPressed: () => GoodsReceiptPrinting.sharePdf(
            context,
            ref,
            receipt: receipt,
            isReprint: isReprint,
          ),
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('PDF'),
        ),
        FilledButton.icon(
          onPressed: () => GoodsReceiptPrinting.printPdf(
            context,
            ref,
            receipt: receipt,
            isReprint: isReprint,
          ),
          icon: const Icon(Icons.local_printshop_outlined, size: 18),
          label: const Text('Imprimir hoja'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }

  Widget _field(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _qty(double value) {
    if ((value - value.roundToDouble()).abs() < 0.001) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }
}
