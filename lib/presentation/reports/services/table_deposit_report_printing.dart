// Impresión del reporte de abonos en la térmica del POS.
//
// Misma salida que el resto de documentos de caja: la impresora de recibos
// (registradora → áreas de recibo → primera activa, ver
// `CashMovementPrinting.resolveReceiptPrinter`) o, en modo sin impresora, el
// ticket en pantalla con opción de PDF / impresora del sistema.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/print_error_humanizer.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/printing.dart' show PrinterConfig;
import '../../../data/models/table_deposit_report.dart';
import '../../../services/printing/table_deposit_report_ticket.dart';
import '../../../services/session/session_controller.dart';
import '../../cashier/utils/cash_movement_printing.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

class TableDepositReportPrinting {
  const TableDepositReportPrinting._();

  /// Imprime el reporte. NO lanza: cualquier fallo se le dice al usuario.
  /// Devuelve `true` si salió por la impresora o se mostró en pantalla.
  static Future<bool> print(
    BuildContext context,
    WidgetRef ref, {
    required TableDepositReport report,
    required DateTime from,
    required DateTime to,
  }) async {
    PrinterConfig? printer;
    try {
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        if (context.mounted) {
          AppToast.warning(context, 'No hay un negocio activo para imprimir.');
        }
        return false;
      }

      final printerless = await PrinterlessMode.isEnabled(businessId);
      if (!printerless) {
        printer = await CashMovementPrinting.resolveReceiptPrinter(
          ref,
          businessId: businessId,
        );
      }

      final businessName = (session.activeBusinessName ?? '').trim();
      final ticket = TableDepositReportTicket.generate(
        report: report,
        businessName: businessName.isEmpty ? 'MangoPOS' : businessName,
        from: from,
        to: to,
        currency: currentBusinessCurrencyOrFallback(ref),
        paperWidth: printer?.paperWidth ?? 80,
      );

      // Un reporte no es un documento de cobro: si no hay térmica, se muestra
      // en pantalla (con PDF e impresora del sistema) en vez de no salir.
      if (printer == null) {
        if (!context.mounted) return false;
        if (!printerless) {
          AppToast.info(
            context,
            'No hay impresora de recibos configurada. El reporte se muestra '
            'en pantalla para imprimirlo o guardarlo en PDF.',
          );
        }
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: 'Reporte de abonos',
          fileNamePrefix: 'reporte_abonos',
        );
        return true;
      }

      await ref
          .read(printingPrintersRepositoryProvider)
          .printEscPos(
            printer: printer,
            data: ticket.escPosCommands,
            kind: 'table_deposit_report',
            areaCode: 'cashier',
            // Cada impresión es un trabajo nuevo: con una clave fija la cola
            // descartaría la segunda copia por idempotente.
            idempotencyKey:
                'deposits-report-$businessId-${DateTime.now().millisecondsSinceEpoch}',
          );
      if (context.mounted) {
        AppToast.success(context, 'Reporte enviado a ${printer.name}.');
      }
      return true;
    } catch (e) {
      final friendly = humanizePrintError(e, printerName: printer?.name);
      if (context.mounted) {
        AppToast.warning(
          context,
          friendly.hint == null
              ? friendly.message
              : '${friendly.message} ${friendly.hint}',
        );
      }
      return false;
    }
  }
}
