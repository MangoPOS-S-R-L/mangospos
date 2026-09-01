// Impresión del recibo de abono a crédito.
//
// Un solo camino para las dos salidas del mismo documento: la impresora
// térmica del POS y la pantalla (modo sin impresora). Vive acá y no en la
// vista porque el recibo se imprime desde DOS lugares —al registrar el abono
// y al reimprimirlo desde el historial— y dos copias de esta lógica se
// desincronizan en el primer cambio de formato.
//
// REGLA: el recibo sale pague como pague. El abono en efectivo tiene el
// arqueo de la caja que lo respalda; el de tarjeta o transferencia no tiene
// nada, y es justo el que más falta hace en papel.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../data/repositories/business_profile_repository.dart';
import '../../../services/printing/credit_payment_ticket.dart';
import '../../../services/session/session_controller.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import '../state/credit_payment_receipt.dart';

/// Encabezado del negocio para el recibo.
class _CreditReceiptHeader {
  final String name;
  final String branch;
  final String? address;
  final String? phone;
  final String? rnc;

  const _CreditReceiptHeader({
    required this.name,
    this.branch = '',
    this.address,
    this.phone,
    this.rnc,
  });
}

class CreditPaymentPrinting {
  const CreditPaymentPrinting._();

  static Future<_CreditReceiptHeader> _header(WidgetRef ref) async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    final sessionName = (session.activeBusinessName ?? '').trim();

    if (businessId == null || businessId.isEmpty) {
      return _CreditReceiptHeader(name: sessionName);
    }
    try {
      final profile = await BusinessProfileRepository(
        Supabase.instance.client,
      ).getProfile(businessId);
      if (profile == null) return _CreditReceiptHeader(name: sessionName);

      // Nombre comercial arriba: es el que el cliente reconoce cuando saca
      // el papel de la cartera. El RNC va abajo, que es lo que da fe de
      // quién recibió el dinero.
      final commercial = (profile.businessName ?? '').trim();
      return _CreditReceiptHeader(
        name: commercial.isNotEmpty ? commercial : sessionName,
        branch: (profile.branchName ?? '').trim(),
        address: profile.address,
        phone: profile.phone,
        rnc: profile.fiscalRnc,
      );
    } catch (_) {
      // El recibo vale con el nombre del negocio: no se deja de imprimir
      // porque el perfil no cargue.
      return _CreditReceiptHeader(name: sessionName);
    }
  }

  /// Imprime el recibo del abono.
  ///
  /// NO lanza. Un fallo de impresión no puede tumbar un abono que YA se
  /// registró y YA movió la caja: avisa y sigue. Devuelve `true` si el
  /// trabajo salió (o se mostró en pantalla).
  static Future<bool> printThermal(
    BuildContext context,
    WidgetRef ref, {
    required CreditPaymentReceipt receipt,
    bool isReprint = false,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) return false;

      final header = await _header(ref);
      final currency = currentBusinessCurrencyOrFallback(ref);
      final printerless = await PrinterlessMode.isEnabled(businessId);

      final repo = ref.read(printingPrintersRepositoryProvider);
      // El abono se cobra en el mostrador: sale por donde salen los recibos.
      final printer = printerless
          ? null
          : await repo.getAssignedPrinterForType(
              businessId: businessId,
              preferredAreaCodes: const ['cashier', 'fiscal'],
              printsReceipts: true,
            );

      final ticket = CreditPaymentTicket.build(
        receipt: receipt,
        businessName: header.name,
        businessBranch: header.branch,
        businessAddress: header.address,
        businessPhone: header.phone,
        businessRnc: header.rnc,
        currency: currency,
        paperWidth: printer?.paperWidth ?? 80,
        isReprint: isReprint,
        cashierName: session.userName,
      );

      if (printerless || printer == null) {
        if (!context.mounted) return false;
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: receipt.code.isEmpty ? 'Abono' : 'Abono ${receipt.code}',
          subtitle: receipt.customerName,
          fileNamePrefix: 'abono',
        );
        return true;
      }

      await repo.printEscPos(
        printer: printer,
        data: ticket.escPosCommands,
        kind: 'credit_payment',
        areaCode: 'cashier',
        // La reimpresión lleva sufijo propio: con la misma clave que el
        // original, la cola la descarta por idempotente y el cajero se queda
        // esperando un papel que nunca sale.
        idempotencyKey: isReprint
            ? 'abono-${receipt.paymentId}-reprint-'
                '${DateTime.now().millisecondsSinceEpoch}'
            : 'abono-${receipt.paymentId}',
      );
      return true;
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('El recibo no se pudo imprimir: $e')),
      );
      return false;
    }
  }
}
