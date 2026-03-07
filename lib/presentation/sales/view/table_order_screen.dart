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
import 'package:mangopos/presentation/customers/viewmodel/customers_viewmodel.dart';

import 'package:mangopos/presentation/sales/widgets/precheck/pre_check_dialog.dart';
import 'package:mangopos/presentation/sales/widgets/printer_selection_dialog.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/data/models/table_status.dart';

import 'package:mangopos/presentation/sales/view/widgets/product_detail_modal.dart';
import 'payment_split_screen.dart';

const Color _salesSurface = Color(0xFFFFFFFF);
const Color _salesDivider = Color(0xFFE9E6E2);
const Color _salesTextPrimary = Color(0xFF2C2C2C);
const Color _salesTextSecondary = Color(0xFF7A7A7A);
const Color _salesTextHint = Color(0xFF9A9A9A);
const Color _salesKitchenButton = Color(0xFFFB8A3C); // naranja cocina sólido
const Color _salesPayButton = Color(0xFF22C55E); // verde puro (success)
const Color _salesTotalColor = Color(0xFFF97316); // mango fuerte
const Color _salesTabActiveBg = Color(0xFFF3F0ED);

const double _salesRadiusCard = 14;
const double _salesRadiusButton = 12; // botones pill
const double _salesRadiusField = 14;
const double _salesRadiusTab = 12;

const List<BoxShadow> _salesSoftShadow = [
  BoxShadow(color: Color(0x10000000), blurRadius: 6, offset: Offset(0, 2)),
];

double _effectiveItemTotal(OrderItem item) {
  return _effectiveItemAmounts(item).total;
}

double _effectiveItemSubtotal(OrderItem item) {
  return _effectiveItemAmounts(item).subtotal;
}

double _effectiveItemTax(OrderItem item) {
  return _effectiveItemAmounts(item).tax;
}

({double subtotal, double tax, double total}) _effectiveItemAmounts(
  OrderItem item,
) {
  final expectedSubtotal = item.unitPrice * item.quantity;
  final dbSubtotal = item.subtotal;
  final isFractionalQty =
      (item.quantity - item.quantity.roundToDouble()).abs() > 0.001;
  final useExpectedSubtotal =
      isFractionalQty &&
      dbSubtotal > 0 &&
      (dbSubtotal - expectedSubtotal).abs() > 0.01;

  final baseSubtotal = useExpectedSubtotal
      ? expectedSubtotal
      : (dbSubtotal > 0 ? dbSubtotal : expectedSubtotal);

  final dbTax = item.tax;
  final baseTax = (useExpectedSubtotal && dbSubtotal > 0)
      ? (dbTax * (baseSubtotal / dbSubtotal))
      : dbTax;

  final discount = item.discounts.clamp(0, double.infinity).toDouble();
  final discountOnSubtotal = discount > baseSubtotal ? baseSubtotal : discount;
  final discountOnTax = discount - discountOnSubtotal;

  final netSubtotal = (baseSubtotal - discountOnSubtotal)
      .clamp(0, double.infinity)
      .toDouble();
  final netTax = (baseTax - discountOnTax).clamp(0, double.infinity).toDouble();
  final netTotal = (netSubtotal + netTax).clamp(0, double.infinity).toDouble();

  return (
    subtotal: double.parse(netSubtotal.toStringAsFixed(2)),
    tax: double.parse(netTax.toStringAsFixed(2)),
    total: double.parse(netTotal.toStringAsFixed(2)),
  );
}

enum OrderOrigin { table, manual, quick }

class OrderScreen extends ConsumerStatefulWidget {
  final OrderOrigin origin;
  final String? tableId;
  final String? tableCode;
  final String? zoneId;

  const OrderScreen({
    super.key,
    this.origin = OrderOrigin.table,
    this.tableId,
    this.tableCode,
    this.zoneId,
  });

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  String? _currentTableCode;

  bool _isOpenItem(OrderItem item) {
    return item.status != 'paid' && item.status != 'void';
  }

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

  Future<void> _handleReleaseTable(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    if (orderState.order == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Liberar mesa'),
        content: const Text(
          'Esto anulará la orden actual y liberará la mesa. ¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Liberar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await ref.read(currentOrderProvider.notifier).cancelCurrentOrder();
    if (!context.mounted) return;
    context.go(AppRoutes.salesByZone);
  }

  Future<void> _handleAssignClient(BuildContext context) async {
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _AssignCustomerDialog(),
    );

    if (selected == null) return;

    final customerId = selected['id'] as String?;
    final customerName = (selected['name'] as String?)?.trim();
    if (customerId == null || customerId.isEmpty) return;
    if (customerName == null || customerName.isEmpty) return;

    await ref
        .read(currentOrderProvider.notifier)
        .assignCustomerToCurrentOrder(
          customerId: customerId,
          customerName: customerName,
        );

    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Cliente asignado: $customerName')));
  }

  Future<void> _handleApplyDiscount(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    final openItems = orderState.items
        .where(_isOpenItem)
        .toList(growable: false);
    if (orderState.order == null || openItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay productos abiertos para descontar.'),
        ),
      );
      return;
    }

    final result = await showDialog<_DiscountDialogResult>(
      context: context,
      builder: (_) => _DiscountDialog(items: openItems),
    );
    if (result == null) return;

    final targetIds = result.scope == _DiscountScope.table
        ? openItems.map((e) => e.id).toList(growable: false)
        : result.selectedItemIds;
    if (targetIds.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecciona al menos un producto.')),
      );
      return;
    }

    try {
      await ref
          .read(currentOrderProvider.notifier)
          .applyDiscountPercentToItems(
            itemIds: targetIds,
            percent: result.percent,
          );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Descuento ${result.percent.toStringAsFixed(0)}% aplicado.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo aplicar descuento: $e')),
      );
    }
  }

  Future<void> _handleCourtesyByProduct(BuildContext context) async {
    final orderState = ref.read(currentOrderProvider);
    final openItems = orderState.items
        .where(_isOpenItem)
        .toList(growable: false);
    if (orderState.order == null || openItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay productos abiertos para cortesía.'),
        ),
      );
      return;
    }

    final result = await showDialog<_CourtesyDialogResult>(
      context: context,
      builder: (_) => _CourtesyDialog(items: openItems),
    );
    if (result == null || result.selectedItemIds.isEmpty) return;

    try {
      await ref
          .read(currentOrderProvider.notifier)
          .applyCourtesyToItems(
            itemIds: result.selectedItemIds,
            reason: result.reason,
          );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.reason.trim().isEmpty
                ? 'Cortesía aplicada.'
                : 'Cortesía aplicada: ${result.reason.trim()}',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo aplicar cortesía: $e')),
      );
    }
  }

  void _initializeOrder() {
    final notifier = ref.read(currentOrderProvider.notifier);
    if (widget.origin == OrderOrigin.table && widget.tableId != null) {
      notifier.openTable(widget.tableId!);
    } else if (widget.origin == OrderOrigin.manual) {
      notifier.ensureManualOrder();
    } else if (widget.origin == OrderOrigin.quick) {
      notifier.ensureQuickOrder();
    }
  }

  @override
  void didUpdateWidget(OrderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.origin != oldWidget.origin ||
        widget.tableId != oldWidget.tableId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _initializeOrder();
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _currentTableCode = widget.tableCode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeOrder();
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

            final cart = _CartView(
              origin: widget.origin,
              tableCode: _currentTableCode ?? '',
              onAssignClient: () => _handleAssignClient(context),
            );
            final catalog = _CatalogArea(
              origin: widget.origin,
              tableCode: _currentTableCode ?? 'Venta Libre',
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
                      origin: widget.origin,
                      tableCode: widget.tableCode ?? 'Venta Local',
                      isStacked: true,
                      onAssignClient: () => _handleAssignClient(context),
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
                  showTableActions: widget.origin == OrderOrigin.table,
                  onReleaseTable: () => _handleReleaseTable(context),
                  onApplyDiscount: () => _handleApplyDiscount(context),
                  onApplyCourtesy: () => _handleCourtesyByProduct(context),
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
  final OrderOrigin origin;
  final String tableCode;
  final bool isStacked;
  final VoidCallback onAssignClient;
  const _CartView({
    required this.origin,
    required this.tableCode,
    required this.onAssignClient,
    this.isStacked = false,
  });

  bool _isOpenItem(OrderItem item) {
    return item.status != 'paid' && item.status != 'void';
  }

  double _sumItemQty(Iterable<OrderItem> items) {
    return items.fold<double>(0, (sum, item) => sum + item.quantity);
  }

  String _formatQtyBadge(double qty) {
    final normalized = double.parse(qty.toStringAsFixed(2));
    if ((normalized - normalized.roundToDouble()).abs() < 0.001) {
      return normalized.toStringAsFixed(0);
    }
    return normalized.toStringAsFixed(2);
  }

  // --- 🪄 UI HELPERS ----------------------------------------------------

  void _openPaymentModal(
    BuildContext context,
    WidgetRef ref,
    Order order,
    double total, {
    String? checkId,
    String? customerId,
    String? customerName,
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
        customerId: customerId,
        customerName: customerName,
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
        onSave: (updatedItem) async {
          await ref
              .read(currentOrderProvider.notifier)
              .updateItem(item.id, updatedItem);
        },
        onDelete: () {
          ref.read(currentOrderProvider.notifier).deleteItem(item.id);
        },
        onMarkSoldOut: item.productId == null
            ? null
            : () async {
                await ref
                    .read(salesRepositoryProvider)
                    .setMenuItemAvailability(
                      menuItemId: item.productId!,
                      isActive: false,
                    );
                await ref
                    .read(menuBrowserVmProvider.notifier)
                    .loadAll(
                      preselectCategoryId: ref
                          .read(menuBrowserVmProvider)
                          .selectedCategoryId,
                    );
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '${item.productName} quedó marcado como agotado',
                    ),
                  ),
                );
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
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final canCharge = sessionCtrl.hasAnyPermission([
      'pagos.acceso',
      'pagos.cobrar_efectivo',
      'pagos.cobrar_tarjeta',
      'pagos.cobrar_transferencia',
    ]);
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
      displayTotal = displayedItems.fold(0.0, (sum, i) {
        return sum + _effectiveItemTotal(i);
      });
      displaySubtotal = displayedItems.fold(0.0, (sum, i) {
        return sum + _effectiveItemSubtotal(i);
      });
      displayTax = displayedItems.fold(0.0, (sum, i) {
        return sum + _effectiveItemTax(i);
      });
    } else {
      // Global View (TODAS)
      // Calculate totals from displayed items only (excluding closed checks)
      // This ensures the total matches what is seen on screen
      displayTotal = displayedItems.fold(
        0.0,
        (sum, i) => sum + _effectiveItemTotal(i),
      );
      displaySubtotal = displayedItems.fold(0.0, (sum, i) {
        return sum + _effectiveItemSubtotal(i);
      });
      displayTax = displayedItems.fold(0.0, (sum, i) {
        return sum + _effectiveItemTax(i);
      });
    }

    final currency = NumberFormat('#,##0.00', 'en_US');

    // Group items for display
    final sentItems = displayedItems.where((i) => i.status != 'draft').toList();
    final draftItems = displayedItems
        .where((i) => i.status == 'draft')
        .toList();
    final itemsCount = _sumItemQty(
      displayedItems,
    ); // Cantidad real, no cantidad de líneas

    final Map<String, _GroupedSentItem> groupedSent = {};
    for (final item in sentItems) {
      final name = item.productName;
      final qty = item.quantity.toDouble();
      final totalItem = _effectiveItemTotal(item);
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            origin == OrderOrigin.table
                                ? 'Mesa $tableCode'
                                : origin == OrderOrigin.manual
                                ? 'Venta Manual ${tableCode.isNotEmpty ? " • $tableCode" : ""}'
                                : 'Venta Rápida',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: _salesTextPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_formatQtyBadge(itemsCount)} productos',
                            style: const TextStyle(
                              fontSize: 14,
                              color: _salesTextSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (selectedCheckId != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.1),
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
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: onAssignClient,
                          icon: const Icon(Icons.person_outline, size: 16),
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 148),
                            child: Text(
                              orderState.customerName?.trim().isNotEmpty == true
                                  ? orderState.customerName!
                                  : 'Asignar cliente',
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _salesTotalColor,
                            side: const BorderSide(color: _salesDivider),
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                _salesRadiusButton,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

        // CHECK SELECTOR (TABS)
        if (hasChecks)
          Container(
            height: 98,
            width: double.infinity,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _salesDivider)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                children: [
                  _BigCheckSelector(
                    label: 'TODAS',
                    isSelected: selectedCheckId == null,
                    onTap: () => ref
                        .read(currentOrderProvider.notifier)
                        .selectCheck(null),
                    itemCount: _sumItemQty(openItems),
                    isGlobal: true,
                  ),
                  const SizedBox(width: 8),
                  ...activeChecks
                      .where(
                        (c) => !hasChecks || c.position > 1,
                      ) // Ocultar cuenta principal si esta dividida
                      .map((check) {
                        final isSelected = check.id == selectedCheckId;
                        final checkItemsCount = _sumItemQty(
                          openItems.where((i) => i.checkId == check.id),
                        );
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
                    onPressed:
                        !canCharge ||
                            orderState.order == null ||
                            displayTotal <= 0
                        ? null
                        : () => _openPaymentModal(
                            context,
                            ref,
                            orderState.order!,
                            displayTotal,
                            checkId: selectedCheckId, // Pass Checks ID!
                            customerId: orderState.customerId,
                            customerName: orderState.customerName,
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
                                        'price': _effectiveItemTotal(i),
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
                    onPressed:
                        !canCharge ||
                            orderState.order == null ||
                            displayTotal <= 0
                        ? null
                        : () => _openPaymentModal(
                            context,
                            ref,
                            orderState.order!,
                            displayTotal,
                            checkId: selectedCheckId,
                            customerId: orderState.customerId,
                            customerName: orderState.customerName,
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
            backgroundColor: const Color(0xFF22C55E),
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
  final double itemCount;
  final bool isGlobal;

  const _BigCheckSelector({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.itemCount = 0,
    this.isGlobal = false,
  });

  String _formatQty(double qty) {
    final normalized = double.parse(qty.toStringAsFixed(2));
    if ((normalized - normalized.roundToDouble()).abs() < 0.001) {
      return normalized.toStringAsFixed(0);
    }
    return normalized.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFFF97316);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 92,
        height: 82,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: isSelected
              ? null
              : Border.all(color: const Color(0xFFE5E7EB), width: 1.5),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.4),
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
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 3),
            // Items Count
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _formatQty(itemCount),
                  style: TextStyle(
                    color: isSelected
                        ? Colors.white.withValues(alpha: 0.9)
                        : const Color(0xFF6B7280),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.shopping_cart_outlined,
                  size: 13,
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.9)
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
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: isSelected
            ? Colors.white.withValues(alpha: 0.2)
            : const Color(0xFFFFF7ED), // Orange 50
        borderRadius: BorderRadius.circular(4),
        border: isSelected
            ? Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1)
            : Border.all(color: const Color(0xFFFFEDD5), width: 1),
      ),
      child: Center(
        child: Text(
          '\$',
          style: TextStyle(
            color: isSelected ? Colors.white : const Color(0xFFF97316),
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _SalesToolsRail extends StatelessWidget {
  final VoidCallback onBack;
  final bool showTableActions;
  final VoidCallback onReleaseTable;
  final VoidCallback onApplyDiscount;
  final VoidCallback onApplyCourtesy;

  const _SalesToolsRail({
    required this.onBack,
    required this.showTableActions,
    required this.onReleaseTable,
    required this.onApplyDiscount,
    required this.onApplyCourtesy,
  });

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
                if (showTableActions) ...[
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
                    icon: Icons.logout_rounded,
                    label: 'Liberar\nmesa',
                    onTap: onReleaseTable,
                  ),
                  _RailButton(
                    icon: Icons.percent_rounded,
                    label: 'Aplicar\ndescuento',
                    onTap: onApplyDiscount,
                  ),
                  _RailButton(
                    icon: Icons.card_giftcard_rounded,
                    label: 'Cortesía\nproducto',
                    onTap: onApplyCourtesy,
                  ),
                ],
                const Spacer(),
                const SizedBox(height: 16),
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
  final OrderItem item;
  final bool isDraft;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const _CartLineItem({
    required this.item,
    required this.isDraft,
    required this.onDelete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = item.productName;
    final qty = item.quantity.toStringAsFixed(1);
    final totalItem = _effectiveItemTotal(item).toStringAsFixed(2);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: Colors.black.withValues(alpha: 0.04), // Subtle hover effect
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
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
  final OrderOrigin origin;
  final String tableCode;
  final Function(dynamic) onProductTap;
  const _CatalogArea({
    required this.origin,
    required this.tableCode,
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
    _mainTabController.addListener(_handleTabChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(menuBrowserVmProvider.notifier).loadAll();
    });
  }

  void _handleTabChange() {
    if (_mainTabController.indexIsChanging) return;

    final menuState = ref.read(menuBrowserVmProvider);
    final notifier = ref.read(menuBrowserVmProvider.notifier);
    final selectedCategoryId = menuState.selectedCategoryId;
    final searchText = _searchController.text.trim();
    switch (_mainTabController.index) {
      case 0:
        if (menuState.categories.isEmpty) {
          notifier.loadAll();
        }
        break;
      case 1:
        if (searchText.isNotEmpty) {
          if (menuState.productsMode != MenuProductsMode.search ||
              menuState.search != searchText ||
              menuState.products.isEmpty) {
            notifier.searchProducts(searchText);
          }
        } else {
          if (selectedCategoryId != null && selectedCategoryId.isNotEmpty) {
            if (menuState.productsMode != MenuProductsMode.category ||
                menuState.loadedCategoryId != selectedCategoryId ||
                menuState.products.isEmpty) {
              notifier.loadProductsByCategory(selectedCategoryId);
            }
          } else {
            if (menuState.productsMode != MenuProductsMode.all ||
                menuState.products.isEmpty) {
              notifier.loadAllProducts();
            }
          }
        }
        break;
      case 2:
        if (menuState.productsMode != MenuProductsMode.favorites ||
            menuState.products.isEmpty) {
          notifier.loadFavoriteProducts();
        }
        break;
    }
  }

  @override
  void dispose() {
    _mainTabController.removeListener(_handleTabChange);
    _mainTabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: _SearchField(
            controller: _searchController,
            onChanged: (value) {
              final menuState = ref.read(menuBrowserVmProvider);
              final notifier = ref.read(menuBrowserVmProvider.notifier);
              if (value.trim().isEmpty) {
                if (_mainTabController.index == 2) {
                  if (menuState.productsMode != MenuProductsMode.favorites ||
                      menuState.products.isEmpty) {
                    notifier.loadFavoriteProducts();
                  }
                } else if (_mainTabController.index == 0) {
                  if (menuState.categories.isEmpty) {
                    notifier.loadAll();
                  }
                } else {
                  final selectedCategoryId = menuState.selectedCategoryId;
                  if (selectedCategoryId != null &&
                      selectedCategoryId.isNotEmpty) {
                    if (menuState.productsMode != MenuProductsMode.category ||
                        menuState.loadedCategoryId != selectedCategoryId ||
                        menuState.products.isEmpty) {
                      notifier.loadProductsByCategory(selectedCategoryId);
                    }
                  } else {
                    if (menuState.productsMode != MenuProductsMode.all ||
                        menuState.products.isEmpty) {
                      notifier.loadAllProducts();
                    }
                  }
                }
                return;
              }

              final q = value.trim();
              if (menuState.productsMode != MenuProductsMode.search ||
                  menuState.search != q) {
                notifier.searchProducts(q);
              }
              if (_mainTabController.index != 1) {
                _mainTabController.animateTo(1);
              }
            },
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
                _ProductsGrid(
                  onProductTap: widget.onProductTap,
                  emptyText: 'Todavía no hay productos frecuentes',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AssignCustomerDialog extends ConsumerStatefulWidget {
  const _AssignCustomerDialog();

  @override
  ConsumerState<_AssignCustomerDialog> createState() =>
      _AssignCustomerDialogState();
}

class _AssignCustomerDialogState extends ConsumerState<_AssignCustomerDialog> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(customersViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(customersViewModelProvider);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 520,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Asignar cliente',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _searchController,
                onChanged: (value) =>
                    ref.read(customersViewModelProvider).search(value),
                decoration: InputDecoration(
                  hintText: 'Buscar por nombre, teléfono o correo',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: vm.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : vm.customers.isEmpty
                    ? const Center(child: Text('No se encontraron clientes'))
                    : ListView.separated(
                        itemCount: vm.customers.length,
                        separatorBuilder: (_, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final customer = vm.customers[index];
                          final name =
                              customer['name']?.toString() ?? 'Cliente';
                          final phone = customer['phone']?.toString();
                          final email = customer['email']?.toString();
                          final subtitleParts = [phone, email]
                              .where(
                                (value) =>
                                    value != null && value.trim().isNotEmpty,
                              )
                              .cast<String>()
                              .toList();

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: _salesTabActiveBg,
                              child: Text(
                                name.isNotEmpty ? name[0].toUpperCase() : 'C',
                                style: const TextStyle(
                                  color: _salesTextPrimary,
                                ),
                              ),
                            ),
                            title: Text(name),
                            subtitle: subtitleParts.isEmpty
                                ? null
                                : Text(subtitleParts.join(' • ')),
                            onTap: () => Navigator.of(context).pop(customer),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

    if (categories.isEmpty && state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (categories.isEmpty) {
      return const Center(
        child: Text(
          'No hay categorías activas',
          style: TextStyle(color: _salesTextSecondary),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final categoryCardExtent = (190 + ((textScale - 1) * 24)).clamp(
          190,
          214,
        );
        return Stack(
          children: [
            GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220, // cards pequeñas
                mainAxisExtent: categoryCardExtent.toDouble(),
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
            ),
            if (state.loading)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  minHeight: 2,
                  color: _salesTotalColor,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ProductsGrid extends ConsumerWidget {
  final Function(dynamic) onProductTap;
  final String emptyText;
  const _ProductsGrid({
    required this.onProductTap,
    this.emptyText = 'Selecciona una categoria o busca productos',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final products = state.products;

    if (products.isEmpty && state.loading) {
      return const Center(
        child: CircularProgressIndicator(color: _salesTotalColor),
      );
    }
    if (products.isEmpty) {
      return Center(child: Text(emptyText));
    }

    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final productCardExtent = (206 + ((textScale - 1) * 32)).clamp(206, 238);

    return Stack(
      children: [
        GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220, // mismo ancho que categorías
            mainAxisExtent: productCardExtent.toDouble(),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
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
        ),
        if (state.loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              color: _salesTotalColor,
            ),
          ),
      ],
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

// -----------------------------------------------------------------------------
// 4. DIALOGO DE SELECCIÓN DE MESAS (MANUAL SALE)
// -----------------------------------------------------------------------------
class _SelectTableDialog extends ConsumerStatefulWidget {
  const _SelectTableDialog();

  @override
  ConsumerState<_SelectTableDialog> createState() => _SelectTableDialogState();
}

class _SelectTableDialogState extends ConsumerState<_SelectTableDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = ref.read(sessionProvider);
      ref.read(byZoneVmProvider.notifier).load(session.activeBusinessId ?? '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(byZoneVmProvider);

    if (state.loading && state.zones.isEmpty) {
      return const Dialog(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Cargando mesas...'),
            ],
          ),
        ),
      );
    }

    // Aplanar mesas disponibles
    final availableTables = <TableStatus>[];
    for (final zone in state.zones) {
      final tablesInZone = state.statusByZone[zone.id] ?? [];
      for (final t in tablesInZone) {
        if (t.sessionId == null) {
          availableTables.add(t);
        }
      }
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 600,
        height: 500,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Asignar a Mesa',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: availableTables.isEmpty
                  ? const Center(child: Text('No hay mesas disponibles'))
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 1.1,
                          ),
                      itemCount: availableTables.length,
                      itemBuilder: (context, index) {
                        final t = availableTables[index];
                        return InkWell(
                          onTap: () {
                            Navigator.pop(context, t);
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: _salesDivider),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.table_bar,
                                  color: _salesTextSecondary,
                                  size: 36,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  t.code,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                    color: _salesTextPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _DiscountScope { table, products }

class _DiscountDialogResult {
  final _DiscountScope scope;
  final double percent;
  final List<String> selectedItemIds;

  const _DiscountDialogResult({
    required this.scope,
    required this.percent,
    required this.selectedItemIds,
  });
}

class _DiscountDialog extends StatefulWidget {
  final List<OrderItem> items;

  const _DiscountDialog({required this.items});

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  _DiscountScope _scope = _DiscountScope.table;
  final TextEditingController _percentController = TextEditingController(
    text: '10',
  );
  final Set<String> _selectedItemIds = <String>{};
  String? _error;

  @override
  void dispose() {
    _percentController.dispose();
    super.dispose();
  }

  String _formatQty(double qty) {
    if ((qty - qty.roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(0);
    }
    return qty.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _salesSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Aplicar descuento',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              SegmentedButton<_DiscountScope>(
                segments: const [
                  ButtonSegment<_DiscountScope>(
                    value: _DiscountScope.table,
                    label: Text('Toda la mesa'),
                  ),
                  ButtonSegment<_DiscountScope>(
                    value: _DiscountScope.products,
                    label: Text('Productos'),
                  ),
                ],
                selected: <_DiscountScope>{_scope},
                onSelectionChanged: (selection) {
                  if (selection.isEmpty) return;
                  setState(() {
                    _scope = selection.first;
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _percentController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Porcentaje (%)',
                  hintText: 'Ejemplo: 10',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              if (_scope == _DiscountScope.products) ...[
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    border: Border.all(color: _salesDivider),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: widget.items.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = widget.items[index];
                      final checked = _selectedItemIds.contains(item.id);
                      return CheckboxListTile(
                        value: checked,
                        title: Text(item.productName),
                        subtitle: Text(
                          'Cant: ${_formatQty(item.quantity)} • RD\$${_effectiveItemTotal(item).toStringAsFixed(2)}',
                        ),
                        onChanged: (_) {
                          setState(() {
                            if (checked) {
                              _selectedItemIds.remove(item.id);
                            } else {
                              _selectedItemIds.add(item.id);
                            }
                            _error = null;
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _salesTotalColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      final percent = double.tryParse(
                        _percentController.text.trim().replaceAll(',', '.'),
                      );
                      if (percent == null || percent <= 0 || percent > 100) {
                        setState(() {
                          _error = 'Ingresa un porcentaje válido (0.01 - 100).';
                        });
                        return;
                      }

                      if (_scope == _DiscountScope.products &&
                          _selectedItemIds.isEmpty) {
                        setState(() {
                          _error = 'Selecciona al menos un producto.';
                        });
                        return;
                      }

                      Navigator.pop(
                        context,
                        _DiscountDialogResult(
                          scope: _scope,
                          percent: percent,
                          selectedItemIds: _selectedItemIds.toList(
                            growable: false,
                          ),
                        ),
                      );
                    },
                    child: const Text('Aplicar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CourtesyDialogResult {
  final List<String> selectedItemIds;
  final String reason;

  const _CourtesyDialogResult({
    required this.selectedItemIds,
    required this.reason,
  });
}

class _CourtesyDialog extends StatefulWidget {
  final List<OrderItem> items;

  const _CourtesyDialog({required this.items});

  @override
  State<_CourtesyDialog> createState() => _CourtesyDialogState();
}

class _CourtesyDialogState extends State<_CourtesyDialog> {
  final Set<String> _selectedItemIds = <String>{};
  final TextEditingController _reasonController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  String _formatQty(double qty) {
    if ((qty - qty.roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(0);
    }
    return qty.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _salesSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 620,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cortesía por producto',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: _salesTextPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Selecciona productos y opcionalmente agrega el motivo.',
                style: TextStyle(fontSize: 13, color: _salesTextSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: 'Motivo de cortesía (opcional)',
                  hintText: 'Ejemplo: atención de la casa',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                decoration: BoxDecoration(
                  border: Border.all(color: _salesDivider),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.items.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = widget.items[index];
                    final checked = _selectedItemIds.contains(item.id);
                    return CheckboxListTile(
                      value: checked,
                      title: Text(item.productName),
                      subtitle: Text(
                        'Cant: ${_formatQty(item.quantity)} • RD\$${_effectiveItemTotal(item).toStringAsFixed(2)}',
                      ),
                      onChanged: (_) {
                        setState(() {
                          if (checked) {
                            _selectedItemIds.remove(item.id);
                          } else {
                            _selectedItemIds.add(item.id);
                          }
                          _error = null;
                        });
                      },
                    );
                  },
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _salesTotalColor,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      if (_selectedItemIds.isEmpty) {
                        setState(() {
                          _error = 'Selecciona al menos un producto.';
                        });
                        return;
                      }
                      Navigator.pop(
                        context,
                        _CourtesyDialogResult(
                          selectedItemIds: _selectedItemIds.toList(
                            growable: false,
                          ),
                          reason: _reasonController.text.trim(),
                        ),
                      );
                    },
                    child: const Text('Aplicar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
