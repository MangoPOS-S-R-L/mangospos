// Impresión del conduce de recepción.
//
// Un solo camino para las tres salidas del mismo documento:
//   - térmica (la impresora del POS, la que tiene el almacén a mano),
//   - pantalla (modo sin impresora),
//   - PDF carta (lo que archiva contabilidad).
//
// Vive acá y no en la vista porque la recepción se imprime desde DOS lugares
// —al recibir y al reimprimir desde el detalle de la orden— y dos copias de
// esta lógica se desincronizan en el primer cambio de formato.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/printing/printerless_mode.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/business_profile_repository.dart';
import '../../../services/printing/goods_receipt_pdf.dart';
import '../../../services/printing/goods_receipt_ticket.dart';
import '../../../services/session/session_controller.dart';
import '../../printing/widgets/ticket_preview_dialog.dart';
import '../../settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import '../state/goods_receipt.dart';

/// Encabezado del negocio para el conduce (nombre, dirección, teléfono, RNC).
class _ReceiptHeader {
  final String name;
  final String? address;
  final String? phone;
  final String? rnc;

  const _ReceiptHeader({
    required this.name,
    this.address,
    this.phone,
    this.rnc,
  });
}

class GoodsReceiptPrinting {
  const GoodsReceiptPrinting._();

  static Future<_ReceiptHeader> _header(WidgetRef ref) async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    final fallbackName =
        (session.activeBusinessName ?? 'MangoPOS').trim().isEmpty
            ? 'MangoPOS'
            : session.activeBusinessName!.trim();
    if (businessId == null || businessId.isEmpty) {
      return _ReceiptHeader(name: fallbackName);
    }
    try {
      final profile = await BusinessProfileRepository(
        Supabase.instance.client,
      ).getProfile(businessId);
      if (profile == null) return _ReceiptHeader(name: fallbackName);
      final name = (profile.fiscalName?.trim().isNotEmpty ?? false)
          ? profile.fiscalName!.trim()
          : (profile.businessName?.trim().isNotEmpty ?? false)
              ? profile.businessName!.trim()
              : fallbackName;
      return _ReceiptHeader(
        name: name,
        address: profile.address,
        phone: profile.phone,
        rnc: profile.fiscalRnc,
      );
    } catch (_) {
      // El conduce vale con el nombre del negocio: no se deja de imprimir
      // porque el perfil fiscal no cargue.
      return _ReceiptHeader(name: fallbackName);
    }
  }

  /// Imprime el conduce por la impresora del POS.
  ///
  /// En modo sin impresora lo muestra en pantalla (con opción de PDF), igual
  /// que el resto de los recibos. No lanza: una impresión fallida no puede
  /// tumbar una recepción que YA movió el stock — avisa y sigue.
  ///
  /// Devuelve `true` si el trabajo salió (o se mostró en pantalla).
  static Future<bool> printThermal(
    BuildContext context,
    WidgetRef ref, {
    required GoodsReceipt receipt,
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
      // El conduce sale por donde salen los recibos: el almacén casi siempre
      // recibe en el mismo mostrador donde está la impresora de caja.
      final printer = printerless
          ? null
          : await repo.getAssignedPrinterForType(
              businessId: businessId,
              preferredAreaCodes: const ['cashier', 'fiscal'],
              printsReceipts: true,
            );

      final ticket = GoodsReceiptTicket.build(
        receipt: receipt,
        businessName: header.name,
        businessAddress: header.address,
        businessPhone: header.phone,
        businessRnc: header.rnc,
        currency: currency,
        paperWidth: printer?.paperWidth ?? 80,
        isReprint: isReprint,
      );

      if (printerless || printer == null) {
        if (!context.mounted) return false;
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: 'Conduce ${receipt.number}',
          subtitle: receipt.supplierName,
          fileNamePrefix: 'conduce',
        );
        return true;
      }

      await repo.printEscPos(
        printer: printer,
        data: ticket.escPosCommands,
        kind: 'goods_receipt',
        areaCode: 'cashier',
        // La reimpresión lleva sufijo propio: con la misma clave que el
        // original, la cola la descarta por idempotente y el usuario se
        // queda esperando un papel que nunca sale.
        idempotencyKey: isReprint
            ? 'conduce-${receipt.id}-reprint-'
                '${DateTime.now().millisecondsSinceEpoch}'
            : 'conduce-${receipt.id}',
      );
      return true;
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('El conduce no se pudo imprimir: $e')),
      );
      return false;
    }
  }

  /// Abre el diálogo de impresión del sistema con el conduce en PDF carta.
  /// Es la ruta del contable: sale por cualquier impresora, no solo la térmica.
  static Future<void> printPdf(
    BuildContext context,
    WidgetRef ref, {
    required GoodsReceipt receipt,
    bool isReprint = false,
  }) async {
    try {
      final header = await _header(ref);
      await GoodsReceiptPdf.printDocument(
        receipt: receipt,
        businessName: header.name,
        businessAddress: header.address,
        businessPhone: header.phone,
        businessRnc: header.rnc,
        currency: currentBusinessCurrencyOrFallback(ref),
        isReprint: isReprint,
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(context, 'No se pudo generar el PDF: $e');
    }
  }

  /// Comparte/guarda el conduce como archivo PDF.
  static Future<void> sharePdf(
    BuildContext context,
    WidgetRef ref, {
    required GoodsReceipt receipt,
    bool isReprint = false,
  }) async {
    try {
      final header = await _header(ref);
      await GoodsReceiptPdf.shareDocument(
        receipt: receipt,
        businessName: header.name,
        businessAddress: header.address,
        businessPhone: header.phone,
        businessRnc: header.rnc,
        currency: currentBusinessCurrencyOrFallback(ref),
        isReprint: isReprint,
      );
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(context, 'No se pudo compartir el PDF: $e');
    }
  }
}
