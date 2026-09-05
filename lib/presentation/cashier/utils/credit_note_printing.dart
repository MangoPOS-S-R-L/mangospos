// Impresión de la nota de crédito.
//
// Un solo camino para las dos salidas del mismo documento: la impresora
// térmica del POS y la pantalla (modo sin impresora). Vive acá y no dentro
// del diálogo de anulación porque la nota se imprime desde DOS lugares —al
// anular la venta y al reimprimirla desde el historial— y dos copias de esta
// lógica se desincronizan en el primer cambio de formato.
//
// Copiado en estructura de `CreditPaymentPrinting` a propósito: mismo
// encabezado, mismo fallback a pantalla, misma regla de idempotencia en la
// reimpresión.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/business_profile_repository.dart';
import '../../../services/printing/credit_note_ticket.dart';
import '../../../services/printing/qr_esc_pos_builder.dart';
import '../../../services/session/session_controller.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

class CreditNotePrinting {
  const CreditNotePrinting._();

  /// Imprime la nota de crédito.
  ///
  /// NO lanza. Un fallo de impresión no puede tumbar una anulación que YA
  /// ocurrió y una nota que YA se emitió a la DGII: avisa y sigue. Devuelve
  /// `true` si el trabajo salió (o se mostró en pantalla).
  static Future<bool> printThermal(
    BuildContext context,
    WidgetRef ref, {
    required FiscalDocument note,
    required String originalNcf,
    DateTime? originalIssuedAt,
    String? reason,
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
      // La anulación se hace en el mostrador: sale por donde salen las
      // facturas.
      final printer = printerless
          ? null
          : await repo.getAssignedPrinterForType(
              businessId: businessId,
              preferredAreaCodes: const ['cashier', 'fiscal'],
              printsReceipts: true,
            );

      // QR solo cuando la DGII ya devolvió la URL de verificación. Si todavía
      // está en proceso, el ticket lo dice en texto.
      List<int>? qrBytes;
      final publicUrl = note.publicUrl ?? '';
      if (note.isElectronic && publicUrl.isNotEmpty) {
        qrBytes = await QrEscPosBuilder.build(data: publicUrl);
      }

      final ticket = CreditNoteTicket.build(
        note: note,
        originalNcf: originalNcf,
        originalIssuedAt: originalIssuedAt,
        reason: reason,
        businessName: header.name,
        businessBranch: header.branch,
        businessAddress: header.address,
        businessPhone: header.phone,
        businessRnc: header.rnc,
        currency: currency,
        paperWidth: printer?.paperWidth ?? 80,
        isReprint: isReprint,
        cashierName: session.userName,
        qrBytes: qrBytes,
      );

      if (printerless || printer == null) {
        if (!context.mounted) return false;
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: 'Nota de crédito ${note.ncfNumber}',
          subtitle: 'Anula $originalNcf',
          fileNamePrefix: 'nota-credito',
        );
        return true;
      }

      await repo.printEscPos(
        printer: printer,
        data: ticket.escPosCommands,
        kind: 'credit_note',
        areaCode: 'cashier',
        // La reimpresión lleva sufijo propio: con la misma clave que el
        // original, la cola la descarta por idempotente y el cajero se queda
        // esperando un papel que nunca sale.
        idempotencyKey: isReprint
            ? 'nota-credito-${note.id}-reprint-'
                  '${DateTime.now().millisecondsSinceEpoch}'
            : 'nota-credito-${note.id}',
      );
      return true;
    } catch (e) {
      messenger?.showAppSnackBar(
        SnackBar(content: Text('La nota de crédito no se pudo imprimir: $e')),
      );
      return false;
    }
  }

  static Future<_NoteHeader> _header(WidgetRef ref) async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    final sessionName = (session.activeBusinessName ?? '').trim();

    if (businessId == null || businessId.isEmpty) {
      return _NoteHeader(name: sessionName);
    }
    try {
      final profile = await BusinessProfileRepository(
        Supabase.instance.client,
      ).getProfile(businessId);
      if (profile == null) return _NoteHeader(name: sessionName);

      final commercial = (profile.businessName ?? '').trim();
      return _NoteHeader(
        name: commercial.isNotEmpty ? commercial : sessionName,
        branch: (profile.branchName ?? '').trim(),
        address: profile.address,
        phone: profile.phone,
        rnc: profile.fiscalRnc,
      );
    } catch (_) {
      // La nota vale con el nombre del negocio: no se deja de imprimir porque
      // el perfil no cargue.
      return _NoteHeader(name: sessionName);
    }
  }
}

class _NoteHeader {
  final String name;
  final String branch;
  final String? address;
  final String? phone;
  final String? rnc;

  const _NoteHeader({
    required this.name,
    this.branch = '',
    this.address,
    this.phone,
    this.rnc,
  });
}
