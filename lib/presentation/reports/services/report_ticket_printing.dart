// Impresión de reportes en la térmica del POS (Abonos, Comandas…).
//
// Misma salida que el resto de documentos de caja: la impresora de recibos
// (registradora → áreas de recibo → primera activa, ver
// `CashMovementPrinting.resolveReceiptPrinter`) o, en modo sin impresora, el
// ticket en pantalla con opción de PDF / impresora del sistema.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/print_error_humanizer.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/printing.dart' show PrintTicket, PrinterConfig;
import '../../../services/session/session_controller.dart';
import '../../cashier/utils/cash_movement_printing.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

/// Arma el ticket para el ancho de papel de la impresora destino.
typedef ReportTicketBuilder =
    PrintTicket Function({
      required String businessName,
      required BusinessCurrency currency,
      required int paperWidth,
    });

class ReportTicketPrinting {
  const ReportTicketPrinting._();

  /// Imprime el ticket de un reporte. NO lanza: cualquier fallo se le dice
  /// al usuario. Devuelve `true` si salió por la impresora o se mostró en
  /// pantalla.
  static Future<bool> print(
    BuildContext context,
    WidgetRef ref, {
    required ReportTicketBuilder build,
    required String title,
    required String fileNamePrefix,
    required String kind,
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
      final ticket = build(
        businessName: businessName.isEmpty ? 'MangoPOS' : businessName,
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
          title: title,
          fileNamePrefix: fileNamePrefix,
        );
        return true;
      }

      await ref
          .read(printingPrintersRepositoryProvider)
          .printEscPos(
            printer: printer,
            data: ticket.escPosCommands,
            kind: kind,
            areaCode: 'cashier',
            // Cada impresión es un trabajo nuevo: con una clave fija la cola
            // descartaría la segunda copia por idempotente.
            idempotencyKey:
                '$kind-$businessId-${DateTime.now().millisecondsSinceEpoch}',
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
