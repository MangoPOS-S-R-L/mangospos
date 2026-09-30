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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/print_error_humanizer.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/printing.dart' show PrinterConfig;
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
    String? destination,
    String? operatorName,
    double? stockBefore = 0,
    double? stockAfter = 0,
    double costPerUnit = 0,
    /// Instante (UTC o local real) de la salida; por defecto, ahora.
    DateTime? occurredAt,
    bool reprint = false,
  }) async {
    // Aviso inmediato: saber si hay impresora y mandar el ticket son
    // consultas de red. Sin esto la pantalla se quedaba quieta, sin decir
    // nada, y se leía como «congelada».
    final progress = _PrintProgress.show(context);
    PrinterConfig? printer;
    try {
      final printerless = await PrinterlessMode.isEnabled(
        businessId,
      ).timeout(_resolveTimeout, onTimeout: () => false);
      // Si no se sabe a tiempo qué impresora usar, el ticket sale EN
      // PANTALLA (desde ahí se imprime por el sistema o se comparte) en vez
      // de dejar a la persona esperando.
      printer = printerless
          ? null
          : await CashMovementPrinting.resolveReceiptPrinter(
              ref,
              businessId: businessId,
            ).timeout(_resolveTimeout, onTimeout: () => null);
      final ticket = WasteExitTicket.generate(
        businessName: businessName,
        itemName: itemName,
        quantity: quantity,
        unit: unit,
        reasonLabel: reasonLabel,
        warehouseName: warehouseName,
        notes: notes,
        destination: destination,
        operatorName: operatorName,
        stockBefore: stockBefore,
        stockAfter: stockAfter,
        costPerUnit: costPerUnit,
        currencySymbol: currentBusinessCurrencyOrFallback(ref).symbol,
        paperWidth: printer?.paperWidth ?? 80,
        occurredAt: occurredAt,
        reprint: reprint,
      );

      if (printerless || printer == null) {
        progress.close();
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
          )
          .timeout(_sendTimeout);
      return true;
    } on TimeoutException {
      if (context.mounted) {
        AppToast.warning(
          context,
          'La impresora no respondió a tiempo. Puede salir con retraso; si '
          'no sale, imprime la hoja A4 o reimprime desde la ficha del insumo.',
        );
      }
      return false;
    } catch (e) {
      final friendly = humanizePrintError(e, printerName: printer?.name);
      if (context.mounted) {
        AppToast.warning(
          context,
          reprint
              ? 'El conduce no salió: ${friendly.message}'
              : 'La salida se registró, pero el conduce no salió: '
                    '${friendly.message}',
        );
      }
      return false;
    } finally {
      progress.close();
    }
  }

  /// Tope para saber si hay impresora (cada consulta puede esperar hasta el
  /// timeout de red de 30 s y son hasta tres en serie).
  static const _resolveTimeout = Duration(seconds: 8);

  /// Tope para el envío: agente local, host remoto, reintento con config
  /// fresca y cola en la nube pueden sumar más de un minuto.
  static const _sendTimeout = Duration(seconds: 25);
}

/// «Imprimiendo conduce…» encima de todo, sin tocar el Navigator (así cerrarlo
/// nunca saca por error otro diálogo abierto).
class _PrintProgress {
  _PrintProgress._(this._entry);

  final OverlayEntry? _entry;
  bool _closed = false;

  static _PrintProgress show(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return _PrintProgress._(null);
    final entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Color(0x55000000)),
          Center(
            child: Material(
              borderRadius: BorderRadius.circular(14),
              color: Colors.white,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    SizedBox(width: 14),
                    Text('Imprimiendo conduce…'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
    return _PrintProgress._(entry);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _entry?.remove();
  }
}
