// Reimpresión de la factura de una venta.
//
// EXTRAÍDO TAL CUAL de sales_history_view.dart (era `_reprintInvoice`). El
// cuerpo NO se tocó: resuelve el scope fiscal del documento (full-order vs
// sub-cuenta), rearma el desglose de impuestos, el QR y el estado del e-CF, y
// humaniza el error de impresora. Son ~450 líneas de reglas fiscales que no
// se pueden reescribir de memoria en una segunda copia.
//
// Vive acá porque ahora se imprime desde DOS módulos: el historial de ventas
// y Cuentas por Cobrar —donde la factura que originó la deuda es justo el
// papel que el cliente viene a reclamar—. Dos copias de esto se
// desincronizarían en el primer cambio de la DGII.
//
// El único acoplamiento que tenía con la pantalla era ninguno: no usaba
// `setState`, ni `widget`, ni estado del State. Recibe (context, ref, payment)
// y ya.
//
// FORMA DE `payment` (lo que necesita de verdad):
//   order_id             — obligatorio; sin él no hace nada
//   check_id             — NULL = factura full-order; con valor = sub-cuenta
//   fiscal_document_id   — el comprobante a reimprimir
//   ncf_number, ncf_type_name, customer_name, customer_tax_id, table_code

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/printing/print_error_humanizer.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/core/tax/tax_engine.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/business_profile_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/presentation/printing/widgets/ticket_preview_dialog.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/printing/qr_esc_pos_builder.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [permissionCode] es el permiso que se exige para reimprimir. Por defecto
/// `pagos.reimprimir_recibo`, el del historial de ventas. Cuentas por Cobrar
/// pasa `creditos.reimprimir`: quien cobra fiao no necesariamente tiene
/// acceso al historial de caja, y al revés — son dos puertas distintas al
/// mismo papel.
Future<void> reprintInvoiceFromPayment(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic> payment, {
  String permissionCode = 'pagos.reimprimir_recibo',
}) async {
  if (!ref.read(sessionProvider.notifier).hasPermission(permissionCode)) {
    AppToast.info(context, 'No tienes permiso para reimprimir recibos.');
    return;
  }
  final orderId = payment['order_id']?.toString() ?? '';
  if (orderId.isEmpty) return;

  // El scope del fd: si tiene check_id, la factura es de una sub-cuenta;
  // si es NULL, es full-order (puede ser cobro simple sin split, o el
  // remainder de una orden con sub-cuentas ya cobradas).
  final fdCheckId = payment['check_id']?.toString();
  final fdId = payment['fiscal_document_id']?.toString();

  // Pre-declarada para que el catch pueda mencionar la impresora
  // específica en el mensaje de error humano (humanizePrintError).
  PrinterConfig? assignedPrinter;
  try {
    AppToast.info(context, 'Generando impresión...');

    final salesRepo = ref.read(salesRepositoryProvider);
    final businessId = ref.read(sessionProvider).activeBusinessId;
    final bundle = await salesRepo.getOrderBundle(
      orderId,
      businessId: businessId,
    );
    if (bundle.order == null) throw Exception('No se encontró la orden.');

    // Para historial/reimpresión necesitamos TODOS los productos de la venta,
    // incluidos los ya pagados. El bundle del order detail excluye items paid
    // para no reinyectar subcuentas cerradas en la UI de la mesa.
    final allItems = await salesRepo.getOrderItems(
      orderId,
      includeModifiers: true,
      onlyOpen: false,
      businessId: businessId,
    );

    // Fetch payments for this order
    final paymentsRaw = await Supabase.instance.client
        .from('payments')
        .select('*, payment_methods(name, code)')
        .eq('order_id', orderId)
        .inFilter('status', ['completed', 'void', 'cancelled'])
        .order('created_at', ascending: false);

    final payments = List<Map<String, dynamic>>.from(paymentsRaw).map((p) {
      final map = p;
      final method = map['payment_methods'] as Map<String, dynamic>?;
      return Payment.fromMap({
        ...map,
        'payment_method_name': method?['name'],
        'payment_method_code': method?['code'],
      });
    }).toList();

    // FILTRO POR SCOPE DEL FD:
    //   - fd.check_id != NULL (sub-cuenta): items y payments del check.
    //   - fd.check_id == NULL (full-order o remainder): items con
    //     check_id IS NULL O items en sub-cuentas SIN fd propio (caso:
    //     sub-cuenta auto-cerrada por items que pasaron a paid via un
    //     cobro full-order, donde el check no emitió fd propio).
    List<OrderItem> printItems;
    List<Payment> printPayments;
    Order printOrder;

    if (fdCheckId != null && fdCheckId.isNotEmpty) {
      printItems = allItems
          .where((item) => item.checkId == fdCheckId)
          .toList(growable: false);
      printPayments = payments
          .where((payment) => payment.checkId == fdCheckId)
          .toList(growable: false);
      try {
        final check = bundle.checks.firstWhere((c) => c.id == fdCheckId);
        printOrder = check.toOrder(createdAt: bundle.order!.createdAt);
      } catch (_) {
        printOrder = bundle.order!;
      }
    } else {
      // Full-order: cargar otros fds de la orden para saber qué checks
      // ya tienen su propio fd. Items de esos checks NO pertenecen a
      // este fd full-order; el resto (check_id NULL o checks sin fd) sí.
      final allFdsRaw = await Supabase.instance.client
          .from('fiscal_documents')
          .select('check_id, status')
          .eq('order_id', orderId);
      final otherCheckFdIds = List<Map<String, dynamic>>.from(allFdsRaw)
          .where((f) => f['check_id'] != null && f['status'] == 'active')
          .map((f) => f['check_id'].toString())
          .toSet();

      printItems = allItems.where((item) {
        if (item.status == 'void') return false;
        if (item.checkId == null) return true;
        return !otherCheckFdIds.contains(item.checkId);
      }).toList(growable: false);

      printPayments = payments
          .where((payment) => payment.checkId == null)
          .toList(growable: false);

      // Construir un "printOrder" cuyos totales reflejen el fd, no la
      // orden completa. Usamos los campos del payment Map (que vienen
      // del JOIN con fiscal_documents en getGlobalSalesHistoryPaged).
      final fdSubtotal = (payment['subtotal'] as num?)?.toDouble() ?? 0;
      final fdItbis = (payment['itbis_amount'] as num?)?.toDouble() ?? 0;
      final fdServiceFee = (payment['service_fee'] as num?)?.toDouble() ?? 0;
      final fdTotal = (payment['total'] as num?)?.toDouble() ?? 0;
      printOrder = bundle.order!.copyWith(
        subtotal: fdSubtotal,
        tax: fdItbis,
        serviceFee: fdServiceFee,
        total: fdTotal,
      );
    }

    // ¿El total guardado del comprobante difiere del recomputado desde los
    // ítems? Pasa cuando la orden se cerró con un monto distinto al de sus
    // ítems (cobro que no cubrió todo, ítems editados tras emitir el NCF,
    // etc.). En ese caso el NCF manda: imprimimos los totales oficiales del
    // fiscal document (igual que el modal de detalle), no un recálculo que
    // saldría distinto a lo que registró la DGII y a lo que ve el cajero.
    final itemsSummary = summarizeOrderPricing(printOrder, printItems);
    final fdMismatch =
        printOrder.total > 0 &&
        (itemsSummary.total - printOrder.total).abs() > 1.0;

    // Anti-doble-conteo del service fee (LEY): cuando los ítems ya traen sus
    // `order_item_tax_lines` (modelo unificado), el fee YA está contado dentro
    // de ellos. Si además dejamos `order.serviceFee > 0`, summarizeOrderPricing
    // lo suma OTRA VEZ como fee legacy y el TOTAL impreso sale inflado (ej:
    // RD$6,574.57 vs RD$6,170 real). El modal de detalle no falla porque arma
    // sus totales con `order = null`; aquí lo replicamos. Para órdenes legacy
    // SIN tax_lines conservamos el serviceFee (ahí el fee solo vive a nivel de
    // orden y debe seguir imprimiéndose). Aplica a ambas ramas (full-order y
    // sub-cuenta, donde check.toOrder también copia serviceFee).
    //
    // EXCEPCIÓN: si hay desajuste con el NCF (`fdMismatch`), conservamos el
    // serviceFee del fiscal document — se imprimirá como parte de los totales
    // oficiales, no recalculado desde ítems.
    if (!fdMismatch &&
        printOrder.serviceFee != 0 &&
        printItems.any((item) => item.taxLines.isNotEmpty)) {
      printOrder = printOrder.copyWith(serviceFee: 0);
    }

    // Loading business profile (simplified, usually from a provider)
    if (businessId == null || businessId.isEmpty) {
      throw Exception('No se pudo resolver el negocio activo.');
    }

    final profileRaw = await Supabase.instance.client
        .from('businesses')
        .select()
        .eq('id', businessId)
        .maybeSingle();

    // Era el getter `_waiterNameFromPayment` del mixin de la pantalla: lee
    // exactamente el mismo campo, ahora del parámetro.
    final waiterName = payment['waiter_name']?.toString() ?? 'Servicio';

    // Modo sin impresora: la reimpresion se muestra en pantalla (con
    // compartir PDF) en vez de salir por papel.
    final printerless = await PrinterlessMode.isEnabled(businessId);

    final printRepo = ref.read(printingPrintersRepositoryProvider);
    if (!printerless) {
      // Asigna la variable outer (declarada antes del try) para que el
      // catch pueda referenciarla en el mensaje de error humano.
      assignedPrinter = await printRepo.getAssignedPrinterForType(
        businessId: businessId,
        preferredAreaCodes: const ['fiscal', 'cashier'],
        printsReceipts: true,
      );

      if (assignedPrinter == null) {
        throw Exception('No hay impresora configurada para recibos.');
      }
    }

    final receiptItemDisplayMode = await ref
        .read(posSettingsRepositoryProvider)
        .getReceiptItemDisplayMode(businessId);
    final discountDisplayMode = await ref
        .read(posSettingsRepositoryProvider)
        .getDiscountDisplayMode(businessId);
    final invoiceTpl = await ref
        .read(posSettingsRepositoryProvider)
        .getInvoiceTemplate(businessId);

    // Build per-tax breakdown for the reprint receipt
    final reprintTaxBreakdown = <({String label, double amount})>[];
    if (fdMismatch) {
      // NCF manda: desglose desde los montos OFICIALES del fiscal document,
      // consistente con el subtotal/total que imprimirá generateInvoice vía
      // `preferStoredOrderTotals`. Sin porcentaje en la etiqueta porque el fd
      // solo guarda montos agregados (itbis_amount, service_fee), no por tasa.
      if (printOrder.tax > 0.005) {
        reprintTaxBreakdown.add((label: 'ITBIS', amount: printOrder.tax));
      }
      if (printOrder.serviceFee > 0.005) {
        reprintTaxBreakdown.add((
          label: 'Servicio',
          amount: printOrder.serviceFee,
        ));
      }
    } else {
      try {
        final taxRows = await Supabase.instance.client
          .from('taxes')
          .select(
            'name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery,apply_on_takeout,include_in_ecf',
          )
          .eq('business_id', businessId)
          .eq('is_active', true);
      final taxes = (taxRows as List)
          .map((r) => TaxDef.fromMap(r as Map<String, dynamic>))
          .toList();
      final origin = parseSaleOrigin(payment['origin']?.toString());
      final printSummary = summarizeOrderPricing(printOrder, printItems);
      final base = printSummary.subtotal;
      final configuredBreakdown = <({String label, double amount})>[];
      for (final tx in taxes) {
        if (!tx.isActive || tx.rate <= 0) continue;
        if (!tx.appliesTo(origin)) continue;
        final pctLabel = tx.rate.truncateToDouble() == tx.rate
            ? '${tx.rate.toInt()}%'
            : '${tx.rate}%';
        final amount = double.parse(
          (base * tx.rateDecimal).toStringAsFixed(2),
        );
        configuredBreakdown.add((
          label: '${tx.name} ($pctLabel)',
          amount: amount,
        ));
      }
      reprintTaxBreakdown.addAll(
        buildOrderTaxBreakdown(
          printOrder,
          printItems,
          configuredBreakdown: configuredBreakdown,
        ),
      );
      } catch (_) {
        // Fallback: the ticket will use the summary-level ITBIS/SERVICIO lines
      }
    }

    // e-CF: fresh fetch del fiscal_document. Crítico en re-impresión porque
    // el estado puede haber cambiado desde el cobro original (sent → accepted
    // vía webhook DGII async). NO usamos los datos históricos del payment;
    // siempre consultamos el estado más actual antes de imprimir.
    List<int>? ecfQrBytes;
    String? ecfStatusMsg;
    bool isElectronicCf = false;
    String? ecfSecurityCode;
    DateTime? ecfSignedAt;
    try {
      // Cargar el fd EXACTO del payment, no "el último de la orden".
      // En split bill una orden tiene N fds; getOrderFiscalDocument
      // devolvería cualquiera. Usar el id del fd (el `payment['id']`
      // del listado, que es el fd.id, no payment.id).
      final fiscalDoc = fdId != null && fdId.isNotEmpty
          ? await salesRepo.getFiscalDocumentById(fdId)
          : await salesRepo.getOrderFiscalDocument(orderId);
      if (fiscalDoc != null && fiscalDoc.isElectronic) {
        isElectronicCf = true;
        ecfSecurityCode = fiscalDoc.ecfSecurityCode;
        ecfSignedAt = fiscalDoc.ecfSignedAt;
        if (fiscalDoc.hasQrData) {
          // Preferimos publicUrl si Alanube/DGII ya nos lo dio. Si aún
          // estamos en estado `sent` (publicUrl null), construimos la
          // URL DGII localmente con security_code + RNC + NCF + fecha
          // + total — el QR sigue siendo válido.
          //
          // RNC del emisor: source of truth es fiscal_settings.rnc.
          // businesses puede tener tax_id en lugar de rnc, o estar
          // vacio en setups legacy. Cascade: businesses.rnc →
          // businesses.tax_id → fiscal_settings.rnc.
          String emitterRnc = (profileRaw?['rnc'] as String?)?.trim() ?? '';
          if (emitterRnc.isEmpty) {
            emitterRnc = (profileRaw?['tax_id'] as String?)?.trim() ?? '';
          }
          if (emitterRnc.isEmpty) {
            try {
              final fs = await Supabase.instance.client
                  .from('fiscal_settings')
                  .select('rnc')
                  .eq('business_id', businessId)
                  .maybeSingle();
              emitterRnc = ((fs?['rnc'] as String?)?.trim()) ?? '';
            } catch (_) {}
          }

          final qrUrl = fiscalDoc.publicUrl?.isNotEmpty == true
              ? fiscalDoc.publicUrl!
              : (fiscalDoc.buildDgiiVerifyUrl(
                    emitterRnc: emitterRnc,
                    sandbox: true,
                  ) ??
                  '');
          if (qrUrl.isNotEmpty) {
            ecfQrBytes = await QrEscPosBuilder.build(data: qrUrl);
          } else {
            ecfStatusMsg = fiscalDoc.ecfStatusMessage;
          }
        } else {
          ecfStatusMsg = fiscalDoc.ecfStatusMessage;
        }
      }
    } catch (_) {
      // Fail-soft: si la consulta o el QR fallan, imprimimos sin ellos.
    }

    // BusinessProfile (slogan, footer, toggles) + logo pre-rasterizado.
    // Si el negocio no configuro logo o printLogoOnInvoice=false,
    // logoBytes viene null y no se imprime nada de logo.
    final businessProfileRepo = BusinessProfileRepository(
      Supabase.instance.client,
    );
    final profileForPrint =
        await businessProfileRepo.prepareForInvoicePrinting(businessId);

    final ticket = PrintTicketService.generateInvoice(
      order: printOrder,
      items: printItems,
      payments: printPayments,
      tableName: payment['table_code']?.toString() ?? 'Mesa',
      waiterName: waiterName,
      businessName: profileRaw?['name'] ?? profileRaw?['business_name'],
      legalName: profileRaw?['legal_name'],
      businessAddress: profileRaw?['address'],
      businessPhone: profileRaw?['phone'],
      businessRnc: profileRaw?['rnc'],
      fiscalNcf: payment['ncf_number']?.toString(),
      fiscalType: payment['ncf_type_name']?.toString(),
      customerName: payment['customer_name']?.toString(),
      customerTaxId: payment['customer_tax_id']?.toString(),
      title: '*** REIMPRESION ***',
      currency: currentBusinessCurrencyOrFallback(ref),
      receiptItemDisplayMode: receiptItemDisplayMode,
      taxBreakdown: reprintTaxBreakdown,
      preferStoredOrderTotals: true,
      // Branding desde BusinessProfile.
      logoBytes: profileForPrint.logoEscPosBytes,
      slogan: profileForPrint.profile?.slogan,
      branchName: profileForPrint.profile?.branchName,
      businessEmail: profileForPrint.profile?.email,
      footerMessage: profileForPrint.profile?.ticketFooterMessage,
      headerBlocks: profileForPrint.profile?.effectiveHeaderBlocks,
      footerBlocks: profileForPrint.profile?.effectiveFooterBlocks,
      preferStoredItemTotals: true,
      qrBytes: ecfQrBytes,
      ecfStatusMessage: ecfStatusMsg,
      isElectronicCf: isElectronicCf,
      ecfSecurityCode: ecfSecurityCode,
      ecfSignedAt: ecfSignedAt,
      discountDisplayMode: discountDisplayMode,
      template: invoiceTpl,
      // Layout segun el papel de la impresora destino (58 u 80mm). Sin
      // impresora (modo sin impresora) se arma a 80mm para pantalla/PDF.
      paperWidth: assignedPrinter?.paperWidth ?? 80,
    );

    if (printerless) {
      if (context.mounted) {
        await showPrintTicketOnScreen(
          context,
          ticket: ticket,
          title: 'Reimpresión de factura',
          fileNamePrefix: 'factura',
        );
      }
      return;
    }

    await printRepo.printEscPos(
      printer: assignedPrinter!,
      data: ticket.escPosCommands,
      preferRaster: ticket.preferRaster,
    );

    if (context.mounted) {
      AppToast.success(context, 'Impresión enviada correctamente.');
    }
  } catch (e) {
    if (context.mounted) {
      final friendly = humanizePrintError(
        e,
        printerName: assignedPrinter?.name,
      );
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(friendly.title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(friendly.message),
              if (friendly.hint != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFD7B0)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.lightbulb_outline,
                        size: 16,
                        color: Color(0xFFB45309),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          friendly.hint!,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF7C2D12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
    }
  }
}
