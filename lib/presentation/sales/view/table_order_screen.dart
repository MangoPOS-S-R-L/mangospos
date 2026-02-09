import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/sales/view/invoice_modal.dart';
import 'package:mangopos/presentation/split_bill/widgets/split_bill_modal.dart';

import 'package:mangopos/presentation/sales/widgets/precheck/pre_check_dialog.dart';
import 'package:mangopos/presentation/sales/widgets/printer_selection_dialog.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

import 'package:mangopos/presentation/sales/view/widgets/product_detail_modal.dart';
import 'payment_split_screen.dart';

const Color _salesSurface = Color(0xFFFFFFFF);
const Color _salesDivider = Color(0xFFE9E6E2);
const Color _salesTextPrimary = Color(0xFF2C2C2C);
const Color _salesTextSecondary = Color(0xFF7A7A7A);
const Color _salesTextHint = Color(0xFF9A9A9A);
const Color _salesKitchenButton = Color(0xFFFB8A3C); // naranja cocina sólido
const Color _salesPayButton = Color(0xFF22C55E); // verde puro (success)
const Color _salesTotalColor = Color(0xFFFB7116); // mango fuerte
const Color _salesTabActiveBg = Color(0xFFF3F0ED);

const double _salesRadiusCard = 14;
const double _salesRadiusButton = 12; // botones pill
const double _salesRadiusField = 14;
const double _salesRadiusTab = 12;

const List<BoxShadow> _salesSoftShadow = [
  BoxShadow(color: Color(0x10000000), blurRadius: 6, offset: Offset(0, 2)),
];

class TableOrderScreen extends ConsumerStatefulWidget {
  final String tableId;
  final String tableCode;
  final String zoneId;

  const TableOrderScreen({
    super.key,
    required this.tableId,
    required this.tableCode,
    required this.zoneId,
  });

  @override
  ConsumerState<TableOrderScreen> createState() => _TableOrderScreenState();
}

class _TableOrderScreenState extends ConsumerState<TableOrderScreen> {
  Future<void> _handleBack(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    if (!orderState.loading &&
        orderState.order != null &&
        orderState.items.isEmpty) {
      await ref.read(currentOrderProvider.notifier).cancelCurrentOrder();
    }
    if (context.mounted) {
      context.go(AppRoutes.salesByZone);
    }
  }

  @override
  void didUpdateWidget(TableOrderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tableId != oldWidget.tableId) {
      ref.read(currentOrderProvider.notifier).openTable(widget.tableId);
      ref.read(menuBrowserVmProvider.notifier).loadAll();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(currentOrderProvider.notifier).openTable(widget.tableId);
      ref.read(menuBrowserVmProvider.notifier).loadAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _salesSurface,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final isDesktop = width >= 1200;
            final isMobile = width < 600;

            double cartWidth = 320.0;
            if (isDesktop) {
              cartWidth = 400.0;
            }

            final cart = _CartView(tableCode: widget.tableCode);
            final catalog = _CatalogArea(
              tableCode: widget.tableCode,
              onBack: () => _handleBack(context),
              onAssignClient: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Asignar cliente')),
                );
              },
              onProductTap: (product) {
                final orderState = ref.read(currentOrderProvider);
                if (orderState.loading) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cargando orden. Intenta de nuevo.'),
                    ),
                  );
                  return;
                }
                if (orderState.order == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('No hay una orden activa.')),
                  );
                  return;
                }
                ref
                    .read(currentOrderProvider.notifier)
                    .addItem(
                      menuItemId: product.id,
                      productName: product.name,
                      productPrice: product.price,
                    );
              },
            );

            if (isMobile) {
              return Column(
                children: [
                  // Mobile: cart primero (40%), luego catálogo (60%)
                  Expanded(
                    flex: 4,
                    child: _CartView(
                      tableCode: widget.tableCode,
                      isStacked: true,
                    ),
                  ),
                  Container(height: 1, color: _salesDivider),
                  Expanded(flex: 6, child: catalog),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SalesToolsRail(
                  onBack: () => _handleBack(context),
                  onAction: (action) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Accion: $action')));
                  },
                ),
                // Usamos ancho fijo según especificación (400px o 320px)
                SizedBox(width: cartWidth, child: cart),
                Container(width: 1, color: _salesDivider),
                Expanded(child: catalog), // Resto disponible
              ],
            );
          },
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 2. VISTA DE CARRITO
// -----------------------------------------------------------------------------
class _CartView extends ConsumerWidget {
  final String tableCode;
  final bool isStacked;
  const _CartView({required this.tableCode, this.isStacked = false});

  bool _isOpenItem(OrderItem item) {
    return item.status != 'paid' && item.status != 'void';
  }

  // --- 🪄 UI HELPERS ----------------------------------------------------

  void _openPaymentModal(
    BuildContext context,
    WidgetRef ref,
    Order order,
    double total, {
    String? checkId,
  }) {
    // Usamos el tableCode disponible en la vista
    final tableName = tableCode;

    _showSmoothDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PaymentSplitDialog(
        orderId: order.id,
        totalAmount: total,
        tableName: tableName,
        checkId: checkId,
      ),
    ).then((result) async {
      if (result is List<Payment>) {
        if (!context.mounted) return;

        // INSTANT LOAD: Use data from result + local state
        final payments = result;
        final items = ref.read(currentOrderProvider).items;
        // Optional: Filter items if paying a specific check (though strictly we show all items on invoice or filter inside modal)

        double totalChange = 0;
        for (final p in payments) {
          totalChange += p.changeAmount;
        }

        if (context.mounted) {
          _showSmoothDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => InvoiceModal(
              order:
                  order, // Nota: idealmente refrescar la orden para estado 'paid'
              items: items,
              payments: payments,
              tableName: tableName,
              checkId: checkId,
              change: totalChange,
              onNewSale: () {
                Navigator.of(ctx).pop();
                if (checkId == null) {
                  context.go(AppRoutes.salesByZone);
                } else {
                  // Si solo se pagó una subcuenta, refrescamos y nos quedamos
                  ref.read(currentOrderProvider.notifier).refreshOrder();
                }
              },
              onPrint: () {
                final invoiceData = {
                  'title': '*** FACTURA ***',
                  'restaurantName': 'MANGO POS RESTAURANT',
                  'rnc': '101-00000-1',
                  'phone': '809-555-0101',
                  'tableName': tableName,
                  'waiterName': 'Juan Pérez',
                  'items': items
                      .map(
                        (i) => {
                          'quantity': i.quantity,
                          'name': i.productName,
                          'price': i.total,
                        },
                      )
                      .toList(),
                  'subtotal': order.subtotal,
                  'tax': order.tax,
                  'total': order.total,
                };

                _handlePrintFlow(
                  context,
                  ref,
                  'invoice',
                  invoiceData,
                  orderObj: order, // Use the order passed to the method
                  orderItems: items,
                  payments: payments,
                  tableName: tableName,
                  waiterName: 'Juan Pérez',
                );
              },
            ),
          );
        }
      }
    }); // Close then and _showSmoothDialog
  }

  void _openSplitBillModal(BuildContext context, WidgetRef ref, Order order) {
    _showSmoothDialog(
      context: context,
      builder: (context) => SplitBillModal(
        order: order,
        onSplitApplied: () {
          // Refrescar la orden actual
          ref.read(currentOrderProvider.notifier).refreshOrder();
        },
      ),
    );
  }

  void _openProductDetailModal(
    BuildContext context,
    WidgetRef ref,
    OrderItem item,
  ) {
    showDialog(
      context: context,
      builder: (context) => ProductDetailModal(
        item: item,
        onSave: (updatedItem) {
          ref
              .read(currentOrderProvider.notifier)
              .updateItem(item.id, updatedItem);
        },
        onDelete: () {
          ref.read(currentOrderProvider.notifier).deleteItem(item.id);
        },
      ),
    );
  }

  /// Helper para transiciones suaves
  Future<T?> _showSmoothDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black54, // Fondo oscuro estándar
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, anim1, anim2) => builder(ctx),
      transitionBuilder: (ctx, anim1, anim2, child) {
        // Combinación de Fade y Scale para un efecto "Pop" suave
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: CurvedAnimation(
              parent: anim1,
              curve: Curves.easeOutBack, // Rebote muy sutil
            ),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderState = ref.watch(currentOrderProvider); // RESTORED
    final allItems = orderState.items; // RESTORED
    final openItems = allItems.where(_isOpenItem).toList();

    final selectedCheckId = orderState.selectedCheckId;
    final allChecks = orderState.checks;
    final activeChecks = allChecks.where((c) => !c.isClosed).toList();
    final hasChecks =
        activeChecks.length > 1 ||
        (activeChecks.length == 1 && activeChecks.first.position > 1);

    // Filter Items
    final List<OrderItem> displayedItems;
    if (selectedCheckId != null) {
      displayedItems = openItems
          .where((i) => i.checkId == selectedCheckId)
          .toList();
    } else {
      // Global View (TODAS)
      // Filter out items from closed checks (paid subcuentas)
      displayedItems = openItems.where((i) {
        final checkIsClosed = allChecks.any(
          (c) => c.id == i.checkId && c.isClosed,
        );
        return !checkIsClosed;
      }).toList();
    }

    // Calculate Totals based on View
    double displayTotal = 0.0;
    double displaySubtotal = 0.0;
    double displayTax = 0.0;

    if (selectedCheckId != null) {
      displayTotal = displayedItems.fold(0.0, (sum, i) => sum + i.total);
      displaySubtotal = displayedItems.fold(0.0, (sum, i) => sum + i.subtotal);
      displayTax = displayedItems.fold(0.0, (sum, i) => sum + i.tax);
    } else {
      // Global View (TODAS)
      // Calculate totals from displayed items only (excluding closed checks)
      // This ensures the total matches what is seen on screen
      displayTotal = displayedItems.fold(0.0, (sum, i) => sum + i.total);
      displaySubtotal = displayedItems.fold(0.0, (sum, i) => sum + i.subtotal);
      displayTax = displayedItems.fold(0.0, (sum, i) => sum + i.tax);
    }

    final currency = NumberFormat('#,##0.00', 'en_US');

    // Group items for display
    final sentItems = displayedItems.where((i) => i.status != 'draft').toList();
    final draftItems = displayedItems
        .where((i) => i.status == 'draft')
        .toList();
    final itemsCount = displayedItems.length; // Count of visible items

    final Map<String, _GroupedSentItem> groupedSent = {};
    for (final item in sentItems) {
      final name = item.productName ?? 'Producto';
      final qty = (item.quantity ?? 1).toDouble();
      final totalItem = (item.total ?? 0.0).toDouble();
      final key = name.toLowerCase().trim();
      if (groupedSent.containsKey(key)) {
        groupedSent[key] = groupedSent[key]!.copyWith(
          qty: groupedSent[key]!.qty + qty,
          total: groupedSent[key]!.total + totalItem,
        );
      } else {
        groupedSent[key] = _GroupedSentItem(
          name: name,
          qty: qty,
          total: totalItem,
        );
      }
    }
    final groupedSentItems = groupedSent.values.toList();

    return Column(
      children: [
        if (!isStacked)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Mesa $tableCode',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: _salesTextPrimary,
                      ),
                    ),
                    if (selectedCheckId != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Subcuenta',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$itemsCount productos',
                  style: const TextStyle(
                    fontSize: 14,
                    color: _salesTextSecondary,
                  ),
                ),
              ],
            ),
          ),

        // CHECK SELECTOR (TABS)
        if (hasChecks)
          Container(
            height: 110,
            width: double.infinity,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _salesDivider)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  _BigCheckSelector(
                    label: 'TODAS',
                    isSelected: selectedCheckId == null,
                    onTap: () => ref
                        .read(currentOrderProvider.notifier)
                        .selectCheck(null),
                    itemCount: openItems.length,
                    isGlobal: true,
                  ),
                  const SizedBox(width: 8),
                  ...activeChecks
                      .where(
                        (c) => !hasChecks || c.position > 1,
                      ) // Ocultar cuenta principal si esta dividida
                      .map((check) {
                        final isSelected = check.id == selectedCheckId;
                        final checkItemsCount = openItems
                            .where((i) => i.checkId == check.id)
                            .length;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _BigCheckSelector(
                            label: check.label.isEmpty
                                ? 'C${check.position}'
                                : check.label,
                            isSelected: isSelected,
                            itemCount: checkItemsCount,
                            onTap: () => ref
                                .read(currentOrderProvider.notifier)
                                .selectCheck(check.id),
                          ),
                        );
                      }),
                ],
              ),
            ),
          ),

        if (!isStacked && !hasChecks)
          Container(height: 1, color: _salesDivider),

        Expanded(
          child: displayedItems.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'No hay productos',
                        style: TextStyle(
                          fontSize: 14,
                          color: _salesTextSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        selectedCheckId != null
                            ? 'Esta subcuenta está vacía'
                            : 'Selecciona productos del menú',
                        style: const TextStyle(
                          fontSize: 13,
                          color: _salesTextHint,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: EdgeInsets.all(isStacked ? 12 : 24),
                  children: [
                    if (groupedSentItems.isNotEmpty) ...[
                      const _SectionLabel(
                        label: 'ENVIADOS A COCINA',
                        color: Color(0xFF22C55E),
                      ),
                      const SizedBox(height: 6),
                      // Encabezado de columnas
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: _salesDivider),
                          ),
                        ),
                        child: Row(
                          children: const [
                            SizedBox(
                              width: 52,
                              child: Text(
                                'Cant.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Producto',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Precio',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _salesTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Column(
                        children: [
                          for (int i = 0; i < groupedSentItems.length; i++) ...[
                            _SentLineItem(
                              name: groupedSentItems[i].name,
                              qty: groupedSentItems[i].qty,
                              total: groupedSentItems[i].total,
                            ),
                            if (i < groupedSentItems.length - 1)
                              const Divider(
                                height: 12,
                                color: _salesDivider,
                                thickness: 0.8,
                              ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (draftItems.isNotEmpty) ...[
                      const _SectionLabel(
                        label: 'POR CONFIRMAR',
                        color: Color(0xFFF59E0B),
                      ),
                      const SizedBox(height: 8),
                      // Encabezado
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: _salesDivider),
                          ),
                        ),
                        child: Row(
                          children: const [
                            SizedBox(
                              width: 52,
                              child: Text(
                                'Cant.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Producto',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: _salesTextSecondary,
                                ),
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Precio',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _salesTextSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      ...draftItems.map(
                        (item) => _CartLineItem(
                          item: item,
                          isDraft: true,
                          onTap: () =>
                              _openProductDetailModal(context, ref, item),
                          onDelete: () {
                            ref
                                .read(currentOrderProvider.notifier)
                                .deleteItem(item.id);
                          },
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        Container(height: 1, color: _salesDivider),
        Padding(
          padding: EdgeInsets.all(isStacked ? 12 : 24),
          child: Column(
            children: [
              _SummaryRow(
                label: 'Subtotal',
                value: 'RD\$ ${currency.format(displaySubtotal)}',
              ),
              const SizedBox(height: 8),
              _SummaryRow(
                label: 'ITBIS',
                value: 'RD\$ ${currency.format(displayTax)}',
              ),
              const SizedBox(height: 12),
              _SummaryRow(
                label: 'Total',
                value: 'RD\$ ${currency.format(displayTotal)}',
                valueColor: _salesTotalColor,
                valueWeight: FontWeight.w700,
              ),

              // REMOVED OLD SPLIT PREVIEW PANEL
              if (allItems.isNotEmpty) ...[
                // Use allItems check to keep buttons visible even if view is empty? No prefer items check.
                const SizedBox(height: 16),
                if (draftItems.isNotEmpty) ...[
                  // BOTON ENVIAR A COCINA (Show if there are DRAFT items in CURRENT view? Or global?
                  // Spec says: "Enviar a Cocina: Comportamiento NO cambia. Envía productos pendientes."
                  // So we should probably allow sending order if there are drafts, regardless of filters.
                  // But usually we interact with what we see.
                  // Let's stick to showing buttons if current view has drafts.
                  _ActionButton(
                    label: 'Enviar a Cocina',
                    background: _salesKitchenButton,
                    onPressed: () =>
                        ref.read(currentOrderProvider.notifier).confirmOrder(),
                    icon: Icons.soup_kitchen_outlined,
                  ),
                  const SizedBox(height: 12),
                  // Pagar solo visible si no hay drafts? Or always?
                  // Usually you can pay what is sent.
                  // Existing code only showed Pay if drafts exist alongside Send?
                  // It seems draft items replace payment flow until sent?
                  // Let's keep existing logic: if drafts, show Pay AND Send? No, usually Send first.
                  // Original code showed BOTH.
                  _ActionButton(
                    label: 'Pagar RD\$ ${currency.format(displayTotal)}',
                    background: _salesPayButton,
                    onPressed: orderState.order == null || displayTotal <= 0
                        ? null
                        : () => _openPaymentModal(
                            context,
                            ref,
                            orderState.order!,
                            displayTotal,
                            checkId: selectedCheckId, // Pass Checks ID!
                          ),
                    icon: Icons.payments_outlined,
                  ),
                ] else if (sentItems.isNotEmpty ||
                    (selectedCheckId != null && displayedItems.isNotEmpty)) ...[
                  // If items are sent, show Pre-Check, Split/Edit, Pay
                  // Also if filtered by check and has items (even if sent status is diff?)
                  Row(
                    children: [
                      Expanded(
                        child: _SecondaryActionButton(
                          label: 'Pre-Cuenta',
                          onPressed: () {
                            if (orderState.order != null) {
                              final preCheckData = {
                                'restaurantName': 'MANGO POS RESTAURANT',
                                'rnc': '101-00000-1',
                                'phone': '809-555-0101',
                                'tableName':
                                    '$tableCode ${selectedCheckId != null ? "(Cuentas Separadas)" : ""}',
                                'waiterName': 'Juan Pérez',
                                'items': displayedItems
                                    .map(
                                      (i) => {
                                        'quantity': i.quantity,
                                        'name': i.productName,
                                        'price': i.total,
                                      },
                                    )
                                    .toList(),
                                'subtotal': displaySubtotal,
                                'tax': displayTax,
                                'total': displayTotal,
                              };

                              showDialog(
                                context: context,
                                barrierDismissible: true,
                                builder: (ctx) => PreCheckDialog(
                                  data: preCheckData,
                                  onPrint: () async {
                                    Navigator.pop(ctx);
                                    await _handlePrintFlow(
                                      context,
                                      ref,
                                      'precheck',
                                      preCheckData,
                                      orderObj: orderState.order!,
                                      orderItems: displayedItems,
                                      tableName:
                                          preCheckData['tableName'] as String?,
                                      waiterName:
                                          preCheckData['waiterName'] as String?,
                                    );
                                  },
                                  onCancel: () => Navigator.pop(ctx),
                                ),
                              );
                            }
                          },
                          icon: Icons.receipt_long_outlined,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _SecondaryActionButton(
                          label: hasChecks ? 'Editar cuentas' : 'Dividir',
                          onPressed: () => _openSplitBillModal(
                            context,
                            ref,
                            orderState.order!,
                          ),
                          icon: hasChecks
                              ? Icons.edit_note
                              : Icons.call_split_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ActionButton(
                    label: 'Pagar RD\$ ${currency.format(displayTotal)}',
                    background: _salesPayButton,
                    onPressed: orderState.order == null || displayTotal <= 0
                        ? null
                        : () => _openPaymentModal(
                            context,
                            ref,
                            orderState.order!,
                            displayTotal,
                            checkId: selectedCheckId,
                          ),
                    icon: Icons.payments_rounded,
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _handlePrintFlow(
    BuildContext context,
    WidgetRef ref,
    String type,
    Map<String, dynamic> data, {
    Order? orderObj,
    List<OrderItem>? orderItems,
    List<Payment>? payments,
    String? tableName,
    String? waiterName,
  }) async {
    try {
      // 1. Obtener repositorio
      final printRepo = ref.read(printingPrintersRepositoryProvider);

      // 2. Cargar impresoras disponibles
      final printersVm = ref.read(printingPrintersViewModelProvider.notifier);
      var printers = ref.read(printingPrintersViewModelProvider).items;

      if (printers.isEmpty) {
        await printersVm.load(businessId: '');
        printers = ref.read(printingPrintersViewModelProvider).items;
      }

      // Filtrar impresoras válidas con IP
      final validPrinters = printers
          .where((p) => (p.ip?.isNotEmpty ?? false))
          .toList();

      if (validPrinters.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No hay impresoras configuradas'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // 3. Mostrar diálogo de selección
      if (!context.mounted) return;

      final PrinterDevice? selected = await showDialog<PrinterDevice>(
        context: context,
        builder: (context) => PrinterSelectionDialog(printers: validPrinters),
      );

      if (selected == null) return; // Cancelado por usuario

      // 4. Enviar al Agente Local
      final ip = selected.ip?.split('/').first;
      if (ip == null || ip.isEmpty) {
        throw Exception('La impresora seleccionada no tiene IP configurada.');
      }
      const fallbackPort = 9100;

      // Si es precuenta y tenemos los objetos, generamos los bytes en Flutter
      if ((type == 'precheck' || type == 'invoice') &&
          orderObj != null &&
          orderItems != null) {
        final title =
            data['title'] as String? ??
            (type == 'invoice' ? 'FACTURA' : 'PRECUENTA');

        final ticket = type == 'invoice'
            ? PrintTicketService.generateInvoice(
                order: orderObj,
                items: orderItems,
                payments: payments ?? [],
                tableName: tableName ?? 'Mesa',
                waiterName: waiterName,
                businessName: data['restaurantName'] as String?,
                businessAddress: data['address'] as String?,
                businessPhone: data['phone'] as String?,
                title: title,
              )
            : PrintTicketService.generatePrecheck(
                order: orderObj,
                items: orderItems,
                tableName: tableName ?? 'Mesa',
                waiterName: waiterName,
                businessName: data['restaurantName'] as String?,
                businessAddress: data['address'] as String?,
                businessPhone: data['phone'] as String?,
                title: title,
              );
        if (kIsWeb) {
          final up = await printRepo.isAgentUp();
          if (!up) {
            throw Exception(
              'Para imprimir desde la Web necesitas el Agente LAN activo en tu PC.',
            );
          }
          await printRepo.printRawViaAgent(
            ip: ip,
            port: fallbackPort,
            data: ticket.escPosCommands,
          );
        } else {
          // En nativo: imprimir directo por TCP
          await printRepo.printRawDirectTcp(
            ip: ip,
            port: fallbackPort,
            data: ticket.escPosCommands,
          );
        }
      } else {
        // Fallback: payload clásico
        final jobPayload = {
          'id':
              '${type.toUpperCase()}-${DateTime.now().millisecondsSinceEpoch}',
          'printer': {'type': 'network', 'ip': ip, 'port': fallbackPort},
          'content': {
            'type': type, // 'precheck' o 'invoice'
            'data': data,
          },
        };
        await printRepo.printJobViaAgent(jobPayload);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imprimiendo en ${selected.name}...'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al imprimir: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

class _BigCheckSelector extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final int itemCount;
  final bool isGlobal;

  const _BigCheckSelector({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.itemCount = 0,
    this.isGlobal = false,
  });

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFFFB7116);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        height: 90,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: isSelected
              ? null
              : Border.all(color: const Color(0xFFE5E7EB), width: 1.5),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: primaryColor.withOpacity(0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icons Row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: isGlobal
                  ? [
                      _buildIconBox(isSelected),
                      const SizedBox(width: 4),
                      _buildIconBox(isSelected),
                      const SizedBox(width: 4),
                      _buildIconBox(isSelected),
                    ]
                  : [_buildIconBox(isSelected)],
            ),
            const SizedBox(height: 8),
            // Label
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFF374151),
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 4),
            // Items Count
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$itemCount',
                  style: TextStyle(
                    color: isSelected
                        ? Colors.white.withOpacity(0.9)
                        : const Color(0xFF6B7280),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.shopping_cart_outlined,
                  size: 14,
                  color: isSelected
                      ? Colors.white.withOpacity(0.9)
                      : const Color(0xFF6B7280),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconBox(bool isSelected) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: isSelected
            ? Colors.white.withOpacity(0.2)
            : const Color(0xFFFFF7ED), // Orange 50
        borderRadius: BorderRadius.circular(4),
        border: isSelected
            ? Border.all(color: Colors.white.withOpacity(0.4), width: 1)
            : Border.all(color: const Color(0xFFFFEDD5), width: 1),
      ),
      child: Center(
        child: Text(
          '\$',
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFFFB7116),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _SalesToolsRail extends StatelessWidget {
  final VoidCallback onBack;
  final Function(String) onAction;

  const _SalesToolsRail({required this.onBack, required this.onAction});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      decoration: const BoxDecoration(
        color: _salesSurface,
        border: Border(right: BorderSide(color: _salesDivider)),
      ),
      child: CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Column(
              children: [
                const SizedBox(height: 16),
                _RailButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  label: 'Regresar',
                  isPrimary: true,
                  onTap: onBack,
                ),
                const SizedBox(height: 16),
                const Divider(height: 1, color: _salesDivider),
                const SizedBox(height: 12),
                const Text(
                  'OPCIONES',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _salesTextSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                _RailButton(
                  icon: Icons.edit_note_rounded,
                  label: 'Editar\nmesa',
                  onTap: () => onAction('edit_table'),
                ),
                _RailButton(
                  icon: Icons.logout_rounded,
                  label: 'Liberar\nmesa',
                  onTap: () => onAction('release_table'),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Divider(height: 1, color: _salesDivider),
                ),
                _RailButton(
                  icon: Icons.call_split_rounded,
                  label: 'Dividir\ncuentas',
                  onTap: () => onAction('split'),
                ),
                _RailButton(
                  icon: Icons.merge_type_rounded,
                  label: 'Unir\nmesas',
                  onTap: () => onAction('merge'),
                ),
                _RailButton(
                  icon: Icons.move_up_rounded,
                  label: 'Mover\npedidos',
                  onTap: () => onAction('move'),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Divider(height: 1, color: _salesDivider),
                ),
                _RailButton(
                  icon: Icons.percent_rounded,
                  label: 'Desc.',
                  onTap: () => onAction('discount'),
                ),
                _RailButton(
                  icon: Icons.receipt_long_rounded,
                  label: 'Vale\npago',
                  onTap: () => onAction('voucher'),
                ),
                const Spacer(),
                const SizedBox(height: 16),
                _RailButton(
                  icon: Icons.print_rounded,
                  label: 'Imprimir',
                  onTap: () => onAction('print'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  const _RailButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isPrimary ? _salesTotalColor : _salesTextPrimary;
    final bg = isPrimary
        ? _salesTotalColor.withValues(alpha: 0.12)
        : _salesSurface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 72,
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w500,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final FontWeight? valueWeight;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.valueWeight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: _salesTextPrimary,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: valueWeight ?? FontWeight.w600,
            color: valueColor ?? _salesTextPrimary,
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final Color color;

  const _SectionLabel({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _CartLineItem extends StatelessWidget {
  final dynamic item;
  final bool isDraft;
  final VoidCallback? onDelete;
  final bool dense;
  final VoidCallback? onTap;

  const _CartLineItem({
    required this.item,
    required this.isDraft,
    required this.onDelete,
    this.dense = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = item.productName ?? '';
    final qty = (item.quantity ?? 1).toStringAsFixed(1);
    final totalItem = (item.total ?? 0.0).toStringAsFixed(2);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: Colors.black.withOpacity(0.04), // Subtle hover effect
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: dense ? 4 : 6),
          child: Row(
            children: [
              if (isDraft && onDelete != null)
                SizedBox(
                  width: 36,
                  child: IconButton(
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.close,
                      color: Color(0xFFEF4444),
                      size: 18,
                    ),
                    splashRadius: 16,
                  ),
                )
              else
                const SizedBox(width: 36),
              Text(
                qty,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _salesTextPrimary,
                ),
              ),
              const SizedBox(width: 10),
              if (!isDraft)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.check_circle,
                    size: 16,
                    color: Color(0xFF22C55E),
                  ),
                ),
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F0FF),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'P',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF3B82F6),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: _salesTextPrimary,
                  ),
                ),
              ),
              Text(
                'RD\$ $totalItem',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _salesTotalColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color background;
  final VoidCallback? onPressed;
  final IconData icon;

  const _ActionButton({
    required this.label,
    required this.background,
    required this.onPressed,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20, color: Colors.white),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        style:
            ElevatedButton.styleFrom(
              backgroundColor: background,
              disabledBackgroundColor: background.withValues(alpha: 0.35),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_salesRadiusButton),
              ),
            ).copyWith(
              overlayColor: WidgetStateProperty.all(
                Colors.white.withValues(alpha: 0.08),
              ),
            ),
      ),
    );
  }
}

class _SecondaryActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final IconData icon;

  const _SecondaryActionButton({
    required this.label,
    required this.onPressed,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: _salesTextPrimary),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _salesTextPrimary,
          ),
        ),
        style: OutlinedButton.styleFrom(
          backgroundColor: _salesTabActiveBg,
          side: const BorderSide(color: _salesDivider),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_salesRadiusButton),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pre-Cuenta Dialog
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Selector de impresora
// ---------------------------------------------------------------------------

class _SentLineItem extends StatelessWidget {
  final String name;
  final double qty;
  final double total;

  const _SentLineItem({
    required this.name,
    required this.qty,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          // Cantidad
          // Cantidad: Centrada en 52px y más compacta
          SizedBox(
            width: 52,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _salesDivider),
                ),
                child: Text(
                  qty.toStringAsFixed(qty % 1 == 0 ? 0 : 1),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: _salesTextPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Iconos de estado
          const Icon(Icons.check_circle, size: 18, color: Color(0xFF22C55E)),
          const SizedBox(width: 6),
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFE6F0FF),
              borderRadius: BorderRadius.circular(7),
            ),
            child: const Text(
              'P',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF3B82F6),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Nombre
          Expanded(
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _salesTextPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Precio
          Text(
            'RD\$ ${total.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: _salesTotalColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupedSentItem {
  final String name;
  final double qty;
  final double total;

  const _GroupedSentItem({
    required this.name,
    required this.qty,
    required this.total,
  });

  _GroupedSentItem copyWith({String? name, double? qty, double? total}) {
    return _GroupedSentItem(
      name: name ?? this.name,
      qty: qty ?? this.qty,
      total: total ?? this.total,
    );
  }
}

// -----------------------------------------------------------------------------
// 3. CATALOG AREA
// -----------------------------------------------------------------------------
class _CatalogArea extends ConsumerStatefulWidget {
  final String tableCode;
  final VoidCallback onBack;
  final VoidCallback onAssignClient;
  final Function(dynamic) onProductTap;
  const _CatalogArea({
    required this.tableCode,
    required this.onBack,
    required this.onAssignClient,
    required this.onProductTap,
  });

  @override
  ConsumerState<_CatalogArea> createState() => _CatalogAreaState();
}

class _CatalogAreaState extends ConsumerState<_CatalogArea>
    with TickerProviderStateMixin {
  late TabController _mainTabController;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Tabs: Categorias, Menu, Favoritos
    _mainTabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _mainTabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final orderState = ref.watch(currentOrderProvider);
    final elapsed = orderState.order == null
        ? '--:--'
        : _formatElapsed(
            DateTime.now().difference(orderState.order!.createdAt),
          );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                color: _salesTextPrimary,
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mesa ${widget.tableCode}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: _salesTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Pedido activo • $elapsed',
                    style: const TextStyle(
                      fontSize: 13,
                      color: _salesTextSecondary,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: widget.onAssignClient,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _salesSurface,
                  elevation: 0,
                  side: const BorderSide(color: _salesDivider),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(_salesRadiusButton),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                child: const Text(
                  'Asignar cliente',
                  style: TextStyle(
                    color: _salesTextPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _SearchField(
            controller: _searchController,
            onChanged: (value) {},
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _SegmentedTabs(
            controller: _mainTabController,
            labels: const ['Categorias', 'Menu', 'Favoritos'],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Container(
            color: _salesSurface,
            child: TabBarView(
              controller: _mainTabController,
              children: [
                // 1. Grid Categorias
                _CategoriesGrid(
                  onCategoryTap: (catId) {
                    // Switch to Menu tab and load products
                    ref
                        .read(menuBrowserVmProvider.notifier)
                        .loadProductsByCategory(catId);
                    _mainTabController.animateTo(1);
                  },
                ),
                // 2. Grid Productos
                _ProductsGrid(onProductTap: widget.onProductTap),
                // 3. Favoritos
                const Center(
                  child: Text(
                    'Sin favoritos',
                    style: TextStyle(color: _salesTextSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatElapsed(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Buscar productos',
          hintStyle: const TextStyle(color: _salesTextHint, fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 18),
          filled: true,
          fillColor: _salesSurface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_salesRadiusField),
            borderSide: const BorderSide(color: _salesDivider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(_salesRadiusField),
            borderSide: const BorderSide(color: _salesDivider),
          ),
        ),
      ),
    );
  }
}

class _SegmentedTabs extends StatelessWidget {
  final TabController controller;
  final List<String> labels;

  const _SegmentedTabs({required this.controller, required this.labels});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          height: 40,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _salesTabActiveBg,
            borderRadius: BorderRadius.circular(_salesRadiusTab),
            border: Border.all(color: _salesDivider),
          ),
          child: Row(
            children: [
              for (int i = 0; i < labels.length; i++) ...[
                Expanded(
                  child: InkWell(
                    onTap: () => controller.animateTo(i),
                    borderRadius: BorderRadius.circular(_salesRadiusTab - 2),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: controller.index == i
                            ? _salesSurface
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          _salesRadiusTab - 2,
                        ),
                      ),
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: controller.index == i
                              ? _salesTextPrimary
                              : _salesTextSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
                if (i < labels.length - 1) const SizedBox(width: 6),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CategoriesGrid extends ConsumerWidget {
  final Function(String) onCategoryTap;
  const _CategoriesGrid({required this.onCategoryTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final categories = state.categories;

    if (state.loading) return const Center(child: CircularProgressIndicator());

    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220, // cards pequeñas
            mainAxisExtent: 190,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final cat = categories[index];
            return InkWell(
              onTap: () => onCategoryTap(cat.id),
              borderRadius: BorderRadius.circular(_salesRadiusCard),
              child: Container(
                constraints: const BoxConstraints(
                  minHeight: 140,
                  minWidth: 160,
                ),
                decoration: BoxDecoration(
                  color: _salesSurface,
                  borderRadius: BorderRadius.circular(_salesRadiusCard),
                  border: Border.all(color: _salesDivider),
                  boxShadow: _salesSoftShadow,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        cat.name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color: _salesTextPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Ver items',
                        style: TextStyle(
                          fontSize: 13,
                          color: _salesTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _ProductsGrid extends ConsumerWidget {
  final Function(dynamic) onProductTap;
  const _ProductsGrid({required this.onProductTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final products = state.products;

    if (state.loading) {
      return const Center(
        child: CircularProgressIndicator(color: _salesTotalColor),
      );
    }
    if (products.isEmpty) {
      return const Center(
        child: Text('Selecciona una categoria o busca productos'),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220, // mismo ancho que categorías
        mainAxisExtent: 190, // mismo alto que categorías
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: products.length,
      itemBuilder: (context, index) {
        final product = products[index];
        return GestureDetector(
          onTap: () => onProductTap(product),
          child: Container(
            constraints: const BoxConstraints(
              minHeight: 140,
              minWidth: 160,
              maxWidth: 220,
            ),
            decoration: BoxDecoration(
              color: _salesSurface,
              borderRadius: BorderRadius.circular(_salesRadiusCard),
              border: Border.all(color: _salesDivider),
              boxShadow: _salesSoftShadow,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _ProductAvatar(imageUrl: product.imageUrl),
                const SizedBox(height: 10),
                Text(
                  product.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: _salesTextPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'RD\$ ${product.price.toStringAsFixed(0)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _salesTotalColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProductAvatar extends StatelessWidget {
  final String? imageUrl;
  const _ProductAvatar({this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: _salesTabActiveBg,
        shape: BoxShape.circle,
        image: imageUrl != null
            ? DecorationImage(image: NetworkImage(imageUrl!), fit: BoxFit.cover)
            : null,
      ),
      child: imageUrl == null
          ? const Icon(Icons.fastfood, color: _salesTextHint, size: 32)
          : null,
    );
  }
}
