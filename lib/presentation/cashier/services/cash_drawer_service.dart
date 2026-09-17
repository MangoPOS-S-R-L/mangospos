// Apertura de gaveta SIN imprimir ticket.
//
// La usan dos disparadores:
//   - El botón "Pagar", si el negocio activó `open_drawer_on_pay_button`.
//   - El botón manual "Abrir gaveta" de la barra superior (cajero/admin).
//
// El pulso va a la MISMA impresora que recibiría la factura en esta caja,
// resuelta igual que en el cobro pero sin UI (una gaveta nunca abre el
// selector de destino):
//   1. impresora asignada a la caja (`cash_registers.receipt_printer_id`),
//   2. la única impresora de recibos, o la fijada en este dispositivo si hay
//      varias (si no hay fijada, la primera),
//   3. impresora con recibos del área fiscal/caja (cacheada en disco, sirve
//      offline).
//
// Sin idempotencyKey a propósito: si la impresora no responde, el pulso NO
// se encola en la nube. Una gaveta que se abre minutos después, sola, es
// peor que una que no se abre.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/core/printing/star/printer_emulation.dart';
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/sales/widgets/precheck/print_destination_picker.dart'
    show ReceiptPrinterPreference;
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
import 'package:mangopos/services/printing/print_destination.dart';
import 'package:mangopos/services/session/session_controller.dart';

enum CashDrawerKickResult {
  opened,

  /// Modo sin impresora activo en este dispositivo: no hay a dónde mandar.
  printerless,

  /// Ninguna impresora de recibos resuelta para esta caja.
  noPrinter,

  /// Había impresora pero el envío falló (apagada, fuera de red…).
  failed,
}

final cashDrawerServiceProvider = Provider<CashDrawerService>(
  CashDrawerService.new,
);

class CashDrawerService {
  CashDrawerService(this._ref);

  final Ref _ref;

  /// Cada consulta de resolución. Conectado-pero-malo no debe dejar al
  /// cajero esperando la gaveta.
  static const Duration _lookupTimeout = Duration(seconds: 3);

  /// La impresora de la caja casi nunca cambia; cachearla deja el pulso del
  /// botón "Pagar" en lo que tarda el TCP.
  static const Duration _printerCacheTtl = Duration(minutes: 2);

  ({String key, PrinterConfig printer, DateTime at})? _cachedPrinter;

  /// Llamar al tocar "Pagar". Fire-and-forget: si el negocio no activó el
  /// ajuste no hace nada, y nunca lanza (el cobro sigue pase lo que pase).
  Future<void> openOnPayButton() async {
    try {
      final businessId = _ref.read(sessionProvider).activeBusinessId;
      if (businessId == null || businessId.isEmpty) return;
      final enabled = await _ref
          .read(posSettingsRepositoryProvider)
          .getOpenDrawerOnPayButton(businessId);
      if (!enabled) return;
      final result = await open();
      if (result != CashDrawerKickResult.opened) {
        debugPrint('[CashDrawer] botón Pagar: gaveta no abierta ($result)');
      }
    } catch (e) {
      debugPrint('[CashDrawer] botón Pagar: $e');
    }
  }

  /// Manda el pulso de apertura a la impresora de recibos de esta caja.
  Future<CashDrawerKickResult> open() async {
    final businessId = _ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      return CashDrawerKickResult.noPrinter;
    }
    if (await PrinterlessMode.isEnabled(businessId)) {
      return CashDrawerKickResult.printerless;
    }

    final printer = await _resolvePrinter(businessId);
    if (printer == null) return CashDrawerKickResult.noPrinter;

    try {
      await _ref
          .read(printingPrintersRepositoryProvider)
          .printEscPos(
            printer: printer,
            data: kickBytesFor(printer),
            kind: 'cash_drawer',
          );
      return CashDrawerKickResult.opened;
    } catch (e) {
      debugPrint('[CashDrawer] ${printer.name}: no se pudo abrir: $e');
      // La IP pudo cambiar o la caja se reasignó: la próxima vez se resuelve
      // de cero en vez de insistir con la misma.
      _cachedPrinter = null;
      return CashDrawerKickResult.failed;
    }
  }

  /// Bytes del pulso para [printer].
  ///
  /// ESC/POS: `ESC p 0 25 250`, el mismo que va pegado al recibo en efectivo
  /// (pin 2 del conector RJ-11).
  ///
  /// Star raster (TSP100): no entiende `ESC p`. Su equivalente es
  /// `ESC * r D 1 NUL` ("drive external device 1") dentro del modo raster.
  /// Sale ya en raster, así que el adaptador lo deja pasar intacto.
  @visibleForTesting
  static List<int> kickBytesFor(PrinterConfig printer) {
    if (resolvePrinterEmulation(printer).isStarRaster) {
      return const [
        0x1B, 0x40, // ESC @
        0x1B, 0x2A, 0x72, 0x41, // ESC * r A — entrar a raster
        0x1B, 0x2A, 0x72, 0x44, 0x31, 0x00, // ESC * r D 1 NUL — gaveta 1
        0x1B, 0x2A, 0x72, 0x42, // ESC * r B — salir de raster
      ];
    }
    return (EscPosGenerator()..openCashDrawer()).getCommands();
  }

  Future<PrinterConfig?> _resolvePrinter(String businessId) async {
    final registerId = _ref.read(cashierViewModelProvider).currentRegisterId;
    final cacheKey = '$businessId|${registerId ?? ''}';
    final cached = _cachedPrinter;
    if (cached != null &&
        cached.key == cacheKey &&
        DateTime.now().difference(cached.at) < _printerCacheTtl) {
      return cached.printer;
    }

    final printRepo = _ref.read(printingPrintersRepositoryProvider);
    PrinterConfig? printer;

    // 1. Impresora de la caja.
    if (registerId != null) {
      try {
        final printerId = await _ref
            .read(cashierRepositoryProvider)
            .getRegisterPrinterId(registerId)
            .timeout(_lookupTimeout);
        if (printerId != null) {
          printer = await printRepo
              .getPrinter(printerId)
              .timeout(_lookupTimeout);
        }
      } catch (_) {}
    }

    // 2. Impresoras de recibos del negocio (única, o la fijada aquí).
    if (printer == null) {
      try {
        final destinations = await _ref
            .read(printDestinationResolverProvider)
            .resolveForReceipt(businessId: businessId)
            .timeout(_lookupTimeout);
        final printers = [
          for (final d in destinations)
            if (d.kind == PrintDestinationKind.printer && d.printer != null)
              d.printer!,
        ];
        if (printers.length == 1) {
          printer = printers.first;
        } else if (printers.length > 1) {
          final deviceId = await DeviceIdentity.getOrCreateId(businessId);
          final pinnedId = await ReceiptPrinterPreference.read(deviceId);
          printer = printers.firstWhere(
            (p) => p.id == pinnedId,
            orElse: () => printers.first,
          );
        }
      } catch (_) {}
    }

    // 3. Área fiscal/caja (con respaldo en disco para offline).
    if (printer == null) {
      try {
        printer = await printRepo
            .getAssignedPrinterForType(
              businessId: businessId,
              preferredAreaCodes: const ['fiscal', 'cashier'],
              printsReceipts: true,
            )
            .timeout(_lookupTimeout);
      } catch (_) {}
    }

    if (printer != null) {
      _cachedPrinter = (key: cacheKey, printer: printer, at: DateTime.now());
    }
    return printer;
  }
}
