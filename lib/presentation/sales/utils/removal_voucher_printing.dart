// Impresión del comprobante de un producto quitado de la cuenta.
//
// Sale SIEMPRE, igual que el volante de caja: es el papel que queda del
// hecho. La resolución de impresora es la misma que usa el volante de caja y
// el cierre (registradora → áreas de recibo → primera impresora activa),
// porque es la única que sale siempre en instalaciones donde nadie asignó
// áreas. Cualquier fallo se le dice al cajero: el borrado YA pasó y un
// silencio ahí fue exactamente lo que dejó a un negocio sin rastro de
// RD$214,200 en una noche.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/print_error_humanizer.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/order_item_removal_reason.dart';
import '../../../services/printing/removal_voucher_ticket.dart';
import '../../cashier/utils/cash_movement_printing.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

class RemovalVoucherPrinting {
  const RemovalVoucherPrinting._();

  /// NO lanza: el producto ya se quitó. Devuelve `true` si el comprobante
  /// salió (o se mostró en pantalla en modo sin impresora).
  static Future<bool> print(
    BuildContext context,
    WidgetRef ref, {
    required String businessName,
    required String productName,
    required double quantity,
    required OrderItemRemovalDecision decision,
    String? tableName,
    String? orderNumber,
    double unitPrice = 0,
    DateTime? sentAt,
    String? operatorName,
    required String businessId,
  }) async {
    final printerless = await PrinterlessMode.isEnabled(businessId);
    final printer = printerless
        ? null
        : await CashMovementPrinting.resolveReceiptPrinter(
            ref,
            businessId: businessId,
          );
    try {
      final ticket = RemovalVoucherTicket.generate(
        businessName: businessName,
        productName: productName,
        quantity: quantity,
        decision: decision,
        tableName: tableName,
        orderNumber: orderNumber,
        unitPrice: unitPrice,
        sentAt: sentAt,
        operatorName: operatorName,
        currencySymbol: currentBusinessCurrencyOrFallback(ref).symbol,
        paperWidth: printer?.paperWidth ?? 80,
      );

      if (printerless || printer == null) {
        if (!context.mounted) return false;
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: 'Comprobante de eliminación',
          fileNamePrefix: 'producto_quitado',
        );
        return true;
      }

      await ref
          .read(printingPrintersRepositoryProvider)
          .printEscPos(
            printer: printer,
            data: ticket.escPosCommands,
            kind: 'order_item_removal',
            areaCode: 'cashier',
            idempotencyKey:
                'removal-${DateTime.now().millisecondsSinceEpoch}-'
                '${productName.hashCode}',
          );
      return true;
    } catch (e) {
      final friendly = humanizePrintError(e, printerName: printer?.name);
      if (context.mounted) {
        AppToast.warning(
          context,
          'El producto se quitó, pero el comprobante no salió: '
          '${friendly.message}',
        );
      }
      return false;
    }
  }
}
