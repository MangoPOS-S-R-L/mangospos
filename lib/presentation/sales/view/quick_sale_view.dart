import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/data/models/printing.dart' show PrinterConfig;
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/printing/widgets/ticket_preview_dialog.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/presentation/payments/widgets/payment_modal.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import '../viewmodel/sales_viewmodel.dart';

class QuickSaleView extends ConsumerWidget {
  const QuickSaleView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Use .select() to only rebuild when the specific fields we need change
    final order = ref.watch(currentOrderProvider.select((s) => s.order));
    final items = ref.watch(currentOrderProvider.select((s) => s.items));
    final loading = ref.watch(currentOrderProvider.select((s) => s.loading));
    final pricingSummary = order == null
        ? null
        : summarizeOrderPricing(order, items);
    final total = pricingSummary?.total ?? 0.0;
    // `ventas_rapida.acceso` abre la pestaña; crear la orden y cobrarla son
    // permisos propios que hasta acá no se consultaban en ningún lado.
    final sessionCtrl = ref.watch(sessionProvider.notifier);
    final canCreate = sessionCtrl.hasPermission('ventas_rapida.crear_orden');
    final canCharge =
        sessionCtrl.hasPermission('ventas_rapida.cobrar_inmediato');
    final canPay = canCharge &&
        order != null &&
        items.isNotEmpty &&
        !loading &&
        total > 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Venta Rápida'),
        backgroundColor: MangoColors.primaryOrange,
      ),
      body: Column(
        children: [
          if (order == null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: ElevatedButton.icon(
                onPressed: !canCreate
                    ? null
                    : () =>
                        ref.read(currentOrderProvider.notifier).openQuick(),
                icon: const Icon(Icons.flash_on),
                label: const Text('Iniciar venta rápida'),
              ),
            ),
          if (order != null)
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final it = items[i];
                  return ListTile(
                    title: Text(it.productName),
                    subtitle: Text('Cant: ${it.quantity}'),
                    trailing: Text(
                      'RD\$ ${itemDisplayTotal(order, it).toStringAsFixed(2)}',
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      bottomNavigationBar: order == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangoColors.primaryOrange,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: !canPay
                      ? null
                      : () {
                          final paidOrder = order.copyWith(
                            subtotal:
                                pricingSummary?.subtotal ?? order.subtotal,
                            discounts:
                                pricingSummary?.discounts ?? order.discounts,
                            serviceFee:
                                pricingSummary?.serviceFee ?? order.serviceFee,
                            tax: pricingSummary?.tax ?? order.tax,
                            total: total,
                          );
                          // Capturamos los items ANTES de cobrar (el éxito
                          // refresca/limpia la orden).
                          final printItems = List<OrderItem>.from(items);
                          // El context de la vista (no el del modal, que se
                          // cierra al cobrar): lo necesita el modo sin
                          // impresora para mostrar la factura en pantalla.
                          final viewContext = context;
                          showDialog(
                            context: context,
                            builder: (context) => PaymentModal(
                              order: paidOrder,
                              // F4/venta rápida: imprime el comprobante con su
                              // NCF (del server online, o el del Hub offline).
                              // El nombre del cliente sale del modal de cobro
                              // (tecleado o picker): el fiscal_document cae a
                              // "Consumidor Final" en venta rápida porque el
                              // RPC no recibe el nombre y la sesión virtual no
                              // tiene customer_name.
                              onComprobante:
                                  (payment, fiscalDoc, modalCustomerName) =>
                                      _printQuickSaleComprobante(
                                        ref,
                                        viewContext: viewContext,
                                        order: paidOrder,
                                        items: printItems,
                                        payment: payment,
                                        fiscalNcf: fiscalDoc?.ncfNumber,
                                        fiscalType: fiscalDoc?.ncfType,
                                        customerName:
                                            (modalCustomerName?.trim().isNotEmpty ??
                                                    false)
                                                ? modalCustomerName!.trim()
                                                : fiscalDoc?.customerName,
                                        customerTaxId: fiscalDoc?.customerRnc,
                                      ),
                              onPaymentSuccess: () {
                                ref
                                    .read(currentOrderProvider.notifier)
                                    .refreshOrder(clearIfPaid: true);
                                ref
                                    .read(currentOrderProvider.notifier)
                                    .openQuick(forceRestart: true);
                              },
                            ),
                          );
                        },
                  child: Text(
                    'PAGAR RD\$ ${total.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
      floatingActionButton: order == null
          ? null
          : FloatingActionButton(
              onPressed: () async {
                final c = Supabase.instance.client;
                final first = await c
                    .from('menu_items')
                    .select('id')
                    .eq('is_active', true)
                    .limit(1)
                    .maybeSingle();
                if (first != null) {
                  await ref
                      .read(currentOrderProvider.notifier)
                      .addItem(menuItemId: first['id'] as String, qty: 1);
                }
              },
              tooltip: 'Agregar producto',
              child: const Icon(Icons.add),
            ),
    );
  }
}

/// Imprime el comprobante (factura de papel) de una venta rápida. Reusa el
/// mismo builder y despacho que el flujo de mesas. El NCF viene del
/// fiscal_document: del server (online) o el asignado offline por el Hub (F4).
/// Paper-only: sin QR e-CF (eso se difiere al sync). Best-effort: si no hay
/// impresora o falla, no truena el cobro (el caller lo llama fire-and-forget).
Future<void> _printQuickSaleComprobante(
  WidgetRef ref, {
  required Order order,
  required List<OrderItem> items,
  required Payment payment,
  BuildContext? viewContext,
  String? fiscalNcf,
  String? fiscalType,
  String? customerName,
  String? customerTaxId,
}) async {
  final session = ref.read(sessionProvider);
  final businessId = session.activeBusinessId;
  if (businessId == null || businessId.isEmpty) return;

  // Modo sin impresora: se arma la misma factura y se muestra en pantalla
  // (con compartir PDF) en vez de mandarla al papel.
  final printerless = await PrinterlessMode.isEnabled(businessId);

  final printRepo = ref.read(printingPrintersRepositoryProvider);
  PrinterConfig? printer;
  if (!printerless) {
    printer = await printRepo.getAssignedPrinterForType(
      businessId: businessId,
      preferredAreaCodes: const ['fiscal', 'cashier'],
      printsReceipts: true,
    );
    if (printer == null) return;
  }

  // Header del negocio (mismo origen que el flujo de mesas).
  var name = (session.activeBusinessName?.trim().isNotEmpty ?? false)
      ? session.activeBusinessName!.trim()
      : 'Negocio';
  String? legalName;
  String? address;
  String? phone;
  String? rnc;
  try {
    final biz = await Supabase.instance.client
        .from('businesses')
        .select(
          'business_name, branch_name, address, phone, fiscal_rnc, fiscal_name',
        )
        .eq('id', businessId)
        .maybeSingle();
    final fiscalName = biz?['fiscal_name']?.toString().trim();
    final branchName = biz?['branch_name']?.toString().trim();
    final businessName = biz?['business_name']?.toString().trim();
    name = (fiscalName?.isNotEmpty == true)
        ? fiscalName!
        : (branchName?.isNotEmpty == true
            ? branchName!
            : (businessName?.isNotEmpty == true ? businessName! : name));
    legalName = fiscalName;
    address = biz?['address']?.toString().trim();
    phone = biz?['phone']?.toString().trim();
    rnc = biz?['fiscal_rnc']?.toString().trim();
  } catch (_) {}

  var itemMode = 'grouped';
  try {
    itemMode = await ref
        .read(posSettingsRepositoryProvider)
        .getReceiptItemDisplayMode(businessId);
  } catch (_) {}

  var invoiceTpl = PosSettingsRepository.invoiceTemplateStandard;
  try {
    invoiceTpl = await ref
        .read(posSettingsRepositoryProvider)
        .getInvoiceTemplate(businessId);
  } catch (_) {}

  try {
    final ticket = PrintTicketService.generateInvoice(
      order: order,
      items: items,
      payments: [payment],
      tableName: 'Venta Rápida',
      businessName: name,
      legalName: legalName,
      businessAddress: address,
      businessPhone: phone,
      businessRnc: rnc,
      fiscalNcf: fiscalNcf,
      fiscalType: fiscalType,
      customerName: customerName,
      customerTaxId: customerTaxId,
      title: '*** FACTURA ***',
      receiptItemDisplayMode: itemMode,
      template: invoiceTpl,
      currency: currentBusinessCurrencyOrFallback(ref),
      // Layout segun el papel de la impresora destino (58 u 80mm). En modo
      // sin impresora `printer` es null y se arma a 80mm para pantalla/PDF.
      paperWidth: printer?.paperWidth ?? 80,
    );
    if (printerless) {
      if (viewContext != null && viewContext.mounted) {
        await showPrintTicketOnScreen(
          viewContext,
          ticket: ticket,
          title: 'Factura',
          fileNamePrefix: 'factura',
        );
      }
      return;
    }
    await printRepo.printEscPos(
      printer: printer!,
      data: ticket.escPosCommands,
      preferRaster: ticket.preferRaster,
    );
  } catch (e) {
    // Fire-and-forget: nunca lanzar. El comprobante se puede reimprimir
    // desde el historial (con su NCF) una vez sincronizado.
    debugPrint('Venta rápida: no se pudo imprimir el comprobante: $e');
  }
}
