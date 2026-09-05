// Impresión del papel de la compra: orden de compra y conduce de recepción.
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
import 'package:mangopos/core/utils/app_snackbar.dart';

/// Qué nombre va en el encabezado del conduce.
///
/// Regla del dueño: **siempre el del NEGOCIO, nunca el de la empresa**. El
/// conduce circula dentro del almacén y se firma contra el camión; tiene que
/// decir el nombre con el que la gente conoce el local, no la razón social que
/// aparece en las facturas ni —peor— el nombre del sistema que lo imprimió.
///
/// Por eso [fiscalName] no participa: está en la firma solo para dejar
/// constancia de que se descarta a propósito y que nadie lo "arregle" después
/// creyendo que fue un olvido.
String resolveGoodsReceiptBusinessName({
  required String? businessName,
  required String? fiscalName,
  String? sessionName,
}) {
  final business = (businessName ?? '').trim();
  if (business.isNotEmpty) return business;
  // Último recurso: el nombre que la sesión tiene cargado. Si tampoco hay,
  // se devuelve vacío y el ticket omite el bloque — mejor sin encabezado que
  // con el nombre de alguien que no recibió nada.
  return (sessionName ?? '').trim();
}

/// Encabezado del negocio para el conduce (nombre, dirección, teléfono, RNC).
class _ReceiptHeader {
  final String name;

  /// Sucursal. Identifica CUÁL local recibió cuando el negocio tiene varios.
  final String branch;

  final String? address;
  final String? phone;
  final String? rnc;

  const _ReceiptHeader({
    required this.name,
    this.branch = '',
    this.address,
    this.phone,
    this.rnc,
  });
}

class GoodsReceiptPrinting {
  const GoodsReceiptPrinting._();

  /// Encabezado del conduce: SIEMPRE los datos del NEGOCIO que recibe.
  ///
  /// Nunca la razón social (`fiscal_name`) ni el nombre del sistema. Este
  /// papel circula dentro del almacén y se firma contra el camión: tiene que
  /// decir el nombre con el que la gente conoce el local, no el de la empresa
  /// que factura ni el del software que lo imprimió. La versión anterior
  /// priorizaba `fiscal_name` y caía a "MangoPOS" cuando faltaba — dos formas
  /// de poner en el papel a alguien que no recibió nada.
  static Future<_ReceiptHeader> _header(WidgetRef ref) async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    final sessionName = (session.activeBusinessName ?? '').trim();

    if (businessId == null || businessId.isEmpty) {
      return _ReceiptHeader(name: sessionName);
    }
    try {
      final profile = await BusinessProfileRepository(
        Supabase.instance.client,
      ).getProfile(businessId);
      if (profile == null) return _ReceiptHeader(name: sessionName);

      final branch = (profile.branchName ?? '').trim();
      return _ReceiptHeader(
        name: resolveGoodsReceiptBusinessName(
          businessName: profile.businessName,
          fiscalName: profile.fiscalName,
          sessionName: sessionName,
        ),
        branch: branch,
        address: profile.address,
        phone: profile.phone,
        rnc: profile.fiscalRnc,
      );
    } catch (_) {
      // El conduce vale con el nombre del negocio: no se deja de imprimir
      // porque el perfil no cargue.
      return _ReceiptHeader(name: sessionName);
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
    /// En modo sin impresora, ¿mostrar el ticket en pantalla? Se apaga cuando
    /// el llamador ya va a abrir el documento en un diálogo: dos ventanas
    /// seguidas con el mismo papel solo estorban.
    bool fallbackOnScreen = true,
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
        businessBranch: header.branch,
        businessAddress: header.address,
        businessPhone: header.phone,
        businessRnc: header.rnc,
        currency: currency,
        paperWidth: printer?.paperWidth ?? 80,
        isReprint: isReprint,
      );

      final slug = receipt.isOrder ? 'orden' : 'conduce';

      if (printerless || printer == null) {
        if (!fallbackOnScreen) return false;
        if (!context.mounted) return false;
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: '${receipt.isOrder ? "Orden" : "Conduce"} ${receipt.number}',
          subtitle: receipt.supplierName,
          fileNamePrefix: slug,
        );
        return true;
      }

      await repo.printEscPos(
        printer: printer,
        data: ticket.escPosCommands,
        kind: receipt.isOrder ? 'purchase_order' : 'goods_receipt',
        areaCode: 'cashier',
        // La reimpresión lleva sufijo propio: con la misma clave que el
        // original, la cola la descarta por idempotente y el usuario se
        // queda esperando un papel que nunca sale.
        idempotencyKey: isReprint
            ? '$slug-${receipt.id}-reprint-'
                '${DateTime.now().millisecondsSinceEpoch}'
            : '$slug-${receipt.id}',
      );
      return true;
    } catch (e) {
      messenger?.showAppSnackBar(
        SnackBar(
          content: Text(
            'El ${receipt.isOrder ? "documento de compra" : "conduce"} no se '
            'pudo imprimir: $e',
          ),
        ),
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
        businessBranch: header.branch,
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
        businessBranch: header.branch,
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
