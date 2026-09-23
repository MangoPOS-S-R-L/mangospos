// Impresión del conduce de una salida de inventario.
//
// Sale cuando el ajuste es una SALIDA y no un cuadre —rotura, vencimiento,
// limpieza, faltante, donación—, porque esa mercancía se fue y alguien tiene
// que firmar por ella. La resolución de impresora es la misma que usa el
// volante de caja, el cierre y el comprobante de producto quitado
// (registradora → áreas de recibo → primera impresora activa): es la única que
// sale siempre en instalaciones donde nadie asignó áreas.
//
// NO lanza nunca. El ajuste YA se guardó cuando esto corre, así que un fallo de
// impresora no puede deshacerlo; lo único que corresponde es decírselo a quien
// está delante. Callarse ahí es lo que deja pérdidas sin rastro.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/print_error_humanizer.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../core/utils/app_toast.dart';
import '../../../services/printing/waste_exit_ticket.dart';
import '../../cashier/utils/cash_movement_printing.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

class WasteExitPrinting {
  const WasteExitPrinting._();

  /// Devuelve `true` si el conduce salió, o si se mostró en pantalla en modo
  /// sin impresora. Nunca lanza.
  static Future<bool> print(
    BuildContext context,
    WidgetRef ref, {
    required String businessId,
    required String businessName,
    required String itemName,
    required double quantity,
    required String unit,
    required String reasonLabel,
    required String warehouseName,
    String? notes,
    String? operatorName,
    double stockBefore = 0,
    double stockAfter = 0,
    double costPerUnit = 0,
  }) async {
    final printerless = await PrinterlessMode.isEnabled(businessId);
    final printer = printerless
        ? null
        : await CashMovementPrinting.resolveReceiptPrinter(
            ref,
            businessId: businessId,
          );
    try {
      final ticket = WasteExitTicket.generate(
        businessName: businessName,
        itemName: itemName,
        quantity: quantity,
        unit: unit,
        reasonLabel: reasonLabel,
        warehouseName: warehouseName,
        notes: notes,
        operatorName: operatorName,
        stockBefore: stockBefore,
        stockAfter: stockAfter,
        costPerUnit: costPerUnit,
        currencySymbol: currentBusinessCurrencyOrFallback(ref).symbol,
        paperWidth: printer?.paperWidth ?? 80,
      );

      if (printerless || printer == null) {
        if (!context.mounted) return false;
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: 'Conduce de salida',
          fileNamePrefix: 'salida_inventario',
        );
        return true;
      }

      await ref
          .read(printingPrintersRepositoryProvider)
          .printEscPos(
            printer: printer,
            data: ticket.escPosCommands,
            kind: 'inventory_waste_exit',
            areaCode: 'cashier',
            idempotencyKey:
                'waste-exit-${DateTime.now().millisecondsSinceEpoch}-'
                '${itemName.hashCode}',
          );
      return true;
    } catch (e) {
      final friendly = humanizePrintError(e, printerName: printer?.name);
      if (context.mounted) {
        AppToast.warning(
          context,
          'La salida se registró, pero el conduce no salió: '
          '${friendly.message}',
        );
      }
      return false;
    }
  }
}
