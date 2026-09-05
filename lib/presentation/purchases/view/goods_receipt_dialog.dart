// El papel de la compra en pantalla + las acciones que lo sacan impreso.
//
// Sirve a los dos documentos ([GoodsReceipt.kind]): la ORDEN DE COMPRA que se
// emite al registrar la compra y el CONDUCE que emite la recepción. Se abre
// después de registrar, después de recibir y al reimprimir desde el detalle
// de la orden: la misma pantalla siempre, porque es el mismo papel.

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

/// Muestra el documento de compra con las tres salidas: térmica, PDF e
/// imprimir PDF. Vale igual para la orden de compra y para el conduce.
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
              '${receipt.isOrder ? "Orden de compra" : "Conduce"} '
              '${receipt.number.isEmpty ? "s/n" : receipt.number}',
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
              _headerBlock(),
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
              // El desglose solo lo trae la orden: es el dinero de la factura
              // del suplidor. El conduce declara mercancía, no impuestos.
              if (receipt.hasAmountBreakdown) ...[
                _amountRow('Subtotal', money.formatAmount(receipt.subtotal ?? 0)),
                if ((receipt.taxTotal ?? 0) != 0)
                  _amountRow('ITBIS', money.formatAmount(receipt.taxTotal ?? 0)),
                if ((receipt.discountTotal ?? 0) != 0)
                  _amountRow(
                    'Descuento',
                    '-${money.formatAmount(receipt.discountTotal ?? 0)}',
                  ),
                const SizedBox(height: 6),
              ],
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
                    money.formatAmount(receipt.grandTotal),
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

  /// Cabecera del documento: el suplidor manda a la izquierda —es el dato que
  /// se busca primero al archivar— y a su lado, arriba, el resto de la
  /// identificación. Antes iban apilados uno debajo del otro y empujaban las
  /// líneas de mercancía fuera de la vista.
  Widget _headerBlock() {
    final fields = <(String, String)>[
      ('Almacén', receipt.warehouseName),
      if (!receipt.isOrder && receipt.orderNumber.isNotEmpty)
        ('Orden de compra', receipt.orderNumber),
      if (receipt.invoiceNumber.isNotEmpty) ('Factura', receipt.invoiceNumber),
      if (receipt.ncf.isNotEmpty) ('NCF', receipt.ncf),
      if (receipt.issuedByName.isNotEmpty)
        ('Realizado por', receipt.issuedByName),
      if (receipt.receivedByName.isNotEmpty)
        ('Recibido por', receipt.receivedByName),
    ];

    final supplier = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SUPLIDOR',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: AppColors.mutedForeground,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          receipt.supplierName,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
        ),
        if (receipt.supplierRnc.trim().isNotEmpty)
          Text(
            'RNC ${receipt.supplierRnc.trim()}',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.mutedForeground,
            ),
          ),
      ],
    );

    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final f in fields) _field(f.$1, f.$2)],
    );

    // En pantalla angosta (tablet de pie, teléfono) las dos columnas no caben
    // sin apretar los valores: se apilan.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 440) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [supplier, const SizedBox(height: 10), meta],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: supplier),
            const SizedBox(width: 16),
            Expanded(flex: 6, child: meta),
          ],
        );
      },
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
            width: 104,
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

  /// Renglón del desglose de la orden (subtotal / ITBIS / descuento).
  Widget _amountRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            Text(value, style: const TextStyle(fontSize: 12.5)),
          ],
        ),
      );

  static String _qty(double value) {
    if ((value - value.roundToDouble()).abs() < 0.001) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }
}
