// Impresión del volante de movimiento manual de caja (ingreso, retiro,
// gasto).
//
// Un solo camino para las dos salidas del mismo documento: la impresora
// térmica del POS y la pantalla (modo sin impresora). Vive acá y no en la
// vista porque el volante se imprime desde DOS lugares —al registrar el
// movimiento y al reimprimirlo desde la lista— y dos copias de esta lógica
// se desincronizan en el primer cambio de formato.
//
// POR QUÉ EXISTE: la versión anterior vivía dentro de `IncomeExpenseView`,
// resolvía la impresora SOLO por las áreas `cashier`/`fiscal` y, si no
// encontraba ninguna, hacía `return` en silencio. El cajero registraba el
// gasto, no salía papel, y nadie se enteraba de por qué. Acá la resolución
// es la misma que la del cierre de caja (que sí sale siempre): registradora
// → áreas de recibo → primera impresora activa, y CUALQUIER fallo se le
// dice al cajero en pantalla.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/print_error_humanizer.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/models/printing.dart' show PrinterConfig;
import '../../../services/printing/print_ticket_service.dart';
import '../../../services/session/session_controller.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import '../viewmodel/cashier_viewmodel.dart';

class CashMovementPrinting {
  const CashMovementPrinting._();

  /// Áreas donde puede estar colgada la impresora del mostrador. Es la
  /// misma lista que usa el cierre de caja: hay instalaciones donde el
  /// área se llama `receipt`/`receipts` en vez de `cashier`, y con la
  /// lista corta el volante no salía en ninguna de ellas.
  static const _receiptAreaCodes = <String>[
    'cashier',
    'fiscal',
    'receipt',
    'receipts',
    'cash_close',
  ];

  /// Imprime el volante del movimiento.
  ///
  /// NO lanza. Un fallo de impresión no puede tumbar un movimiento que YA
  /// se registró y YA movió la caja: avisa y sigue. Devuelve `true` si el
  /// trabajo salió (o se mostró en pantalla).
  static Future<bool> printThermal(
    BuildContext context,
    WidgetRef ref, {
    required String movementType, // 'deposit' | 'withdrawal' | 'expense'
    required double amount,
    required String reasonLabel,
    String? description,
    required String sessionId,
    String? cashierName,
    String? approvedByName,
    DateTime? when,
    bool isReprint = false,
  }) async {
    PrinterConfig? printer;
    try {
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        if (context.mounted) {
          AppToast.warning(
            context,
            'No hay un negocio activo para imprimir el volante.',
          );
        }
        return false;
      }

      final printerless = await PrinterlessMode.isEnabled(businessId);
      if (!printerless) {
        printer = await _resolvePrinter(ref, businessId: businessId);
        if (printer == null) {
          // Antes esto era un `return` mudo. Es la causa más común de
          // "registré el gasto y no salió nada".
          if (context.mounted) {
            AppToast.warning(
              context,
              'El movimiento quedó registrado, pero no hay una impresora de '
              'recibos configurada para imprimir el volante.',
            );
          }
          return false;
        }
      }

      final businessName = (session.activeBusinessName ?? '').trim();
      final ticket = PrintTicketService.generateCashMovementReceipt(
        businessName: businessName.isEmpty ? 'MangoPOS' : businessName,
        movementType: movementType,
        amount: amount,
        reasonLabel: reasonLabel,
        description: description,
        cashierName: cashierName ?? session.userName,
        approvedByName: approvedByName,
        sessionId: sessionId,
        when: when ?? DateTime.now(),
        currency: currentBusinessCurrencyOrFallback(ref),
        // Layout según el papel de la impresora destino (58 u 80mm). En
        // modo sin impresora se arma a 80mm para pantalla/PDF.
        paperWidth: printer?.paperWidth ?? 80,
        isReprint: isReprint,
      );

      if (printerless || printer == null) {
        if (!context.mounted) return false;
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: 'Volante de caja',
          fileNamePrefix: 'movimiento_caja',
        );
        return true;
      }

      final repo = ref.read(printingPrintersRepositoryProvider);
      await repo.printEscPos(
        printer: printer,
        data: ticket.escPosCommands,
        kind: 'cash_movement',
        areaCode: 'cashier',
        // La reimpresión lleva sufijo propio: con la misma clave que el
        // original la cola la descarta por idempotente y el cajero se
        // queda esperando un papel que nunca sale.
        idempotencyKey:
            'cashmov-$sessionId-${isReprint ? 'reprint-' : ''}'
            '${DateTime.now().millisecondsSinceEpoch}',
      );
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

  /// Registradora → áreas de recibo → primera impresora activa.
  ///
  /// El último escalón es el que copia al cierre de caja: si el negocio
  /// tiene UNA sola impresora y nadie la asignó a un área, el volante
  /// igual sale por ella en vez de no salir por ningún lado.
  static Future<PrinterConfig?> _resolvePrinter(
    WidgetRef ref, {
    required String businessId,
  }) async {
    final repo = ref.read(printingPrintersRepositoryProvider);

    // 1. Impresora vinculada a la caja registradora abierta.
    final registerId = ref.read(cashierViewModelProvider).currentRegisterId;
    if (registerId != null && registerId.isNotEmpty) {
      try {
        final printerId = await ref
            .read(cashierRepositoryProvider)
            .getRegisterPrinterId(registerId);
        if (printerId != null && printerId.isNotEmpty) {
          final byRegister = await repo.getPrinter(printerId);
          if (byRegister != null) return byRegister;
        }
      } catch (_) {
        // La registradora sin impresora vinculada (o un fallo de red al
        // leerla) no puede cortar la cadena: seguimos por área.
      }
    }

    // 2. Impresora del área de recibos.
    try {
      final byArea = await repo.getAssignedPrinterForType(
        businessId: businessId,
        preferredAreaCodes: _receiptAreaCodes,
        printsReceipts: true,
      );
      if (byArea != null) return byArea;
    } catch (_) {
      // Idem: caemos al último escalón.
    }

    // 3. Cualquier impresora activa del negocio.
    try {
      final printers = await repo.getPrinters(businessId);
      for (final p in printers) {
        if (p.isActive) return p;
      }
    } catch (_) {
      // Sin catálogo de impresoras no hay nada más que intentar.
    }
    return null;
  }
}
