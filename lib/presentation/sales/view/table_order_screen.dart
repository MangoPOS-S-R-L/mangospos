import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/split_bill/widgets/split_bill_modal.dart';
import 'package:mangopos/presentation/customers/viewmodel/customers_viewmodel.dart';

import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/widgets/pin_verification_modal.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

final _salesActionLocksProvider = StateProvider<Set<String>>(
  (ref) => <String>{},
);

const List<BoxShadow> _salesSoftShadow = [
  BoxShadow(color: Color(0x10000000), blurRadius: 6, offset: Offset(0, 2)),
];

Color _parseHexColor(String? hex, {Color fallback = _salesDivider}) {
  if (hex == null || hex.isEmpty) return fallback;
  try {
    final buffer = StringBuffer();
    if (hex.length == 6 || hex.length == 7) buffer.write('ff');
    buffer.write(hex.replaceFirst('#', ''));
    return Color(int.parse(buffer.toString(), radix: 16));
  } catch (_) {
    return fallback;
  }
}

class _BusinessReceiptProfile {
  final String name;
  final String? businessName;
  final String? legalName;
  final String? address;
  final String? phone;
  final String? rnc;

  const _BusinessReceiptProfile({
    required this.name,
    this.businessName,
    this.legalName,
    this.address,
    this.phone,
    this.rnc,
  });
}

Future<_BusinessReceiptProfile> _loadBusinessReceiptProfile(
  WidgetRef ref,
) async {
  final session = ref.read(sessionProvider);
  final businessId = session.activeBusinessId;
  final fallbackName = (session.activeBusinessName?.trim().isNotEmpty ?? false)
      ? session.activeBusinessName!.trim()
      : 'Negocio';

  if (businessId == null || businessId.isEmpty) {
    return _BusinessReceiptProfile(name: fallbackName, phone: null);
  }

  final client = Supabase.instance.client;
  String? name = fallbackName;
  String? businessName;
  String? address;
  String? phone;
  String? rnc;
  String? legalName;

  try {
    final business = await client
        .from('businesses')
        .select(
          'business_name, branch_name, address, phone, fiscal_rnc, fiscal_name',
        )
        .eq('id', businessId)
        .maybeSingle();

    final branchName = business?['branch_name']?.toString().trim();
    final businessName = business?['business_name']?.toString().trim();
    final fiscalNameVal = business?['fiscal_name']?.toString().trim();

    // Prefer fiscal_name if available for receipts
    name = fiscalNameVal?.isNotEmpty == true
        ? fiscalNameVal
        : (branchName?.isNotEmpty == true
              ? branchName
              : (businessName?.isNotEmpty == true
                    ? businessName
                    : fallbackName));

    address = business?['address']?.toString().trim();
    phone = business?['phone']?.toString().trim();
    rnc = business?['fiscal_rnc']?.toString().trim();
    legalName = fiscalNameVal;
  } catch (_) {}

  return _BusinessReceiptProfile(
    name: name ?? fallbackName,
    businessName: businessName,
    legalName: legalName,
    address: address,
    phone: phone,
    rnc: rnc,
  );
}

Future<String?> _loadWaiterName(WidgetRef ref, String orderId) async {
  final fallback = ref.read(sessionProvider).userName;

  try {
    final data = await Supabase.instance.client
        .from('orders')
        .select('table_sessions(opened_by,business_id,users(full_name))')
        .eq('id', orderId)
        .maybeSingle();

    final tableSession = data?['table_sessions'] as Map<String, dynamic>?;
    final openedBy = tableSession?['opened_by']?.toString();
    final businessId = tableSession?['business_id']?.toString();
    final user = tableSession?['users'] as Map<String, dynamic>?;
    final fullName = user?['full_name']?.toString().trim();
    if (openedBy != null &&
        openedBy.isNotEmpty &&
        businessId != null &&
        businessId.isNotEmpty) {
      final employee = await Supabase.instance.client
          .from('employees')
          .select('first_name')
          .eq('user_id', openedBy)
          .eq('business_id', businessId)
          .maybeSingle();
      final firstName = employee?['first_name']?.toString();
      if (firstName != null && firstName.trim().isNotEmpty) {
        return preferredDisplayName(firstName: firstName);
      }
    }
    if (fullName != null && fullName.isNotEmpty) {
      return preferredDisplayName(fullName: fullName);
    }
  } catch (_) {}

  return fallback;
}

Future<FiscalDocument?> _loadFiscalDocument(
  WidgetRef ref,
  String orderId,
) async {
  try {
    return await ref
        .read(salesRepositoryProvider)
        .getOrderFiscalDocument(orderId);
  } catch (_) {
    return null;
  }
}

Future<void> _showMissingKitchenPrinterDialog(
  BuildContext context,
  NoAssignedKitchenPrinterException error,
) {
  final areas = error.areaCodes.isEmpty
      ? 'cocina'
      : error.areaCodes.join(', ').replaceAll('_', ' ').toUpperCase();

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.print_disabled_outlined, color: Colors.orange),
          SizedBox(width: 10),
          Expanded(child: Text('Impresora no configurada')),
        ],
      ),
      content: Text(
        'No hay una impresora asignada para $areas.\n\nConfigura una impresora en Ajustes > Impresion de comandas antes de enviar esta orden a cocina.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cerrar'),
        ),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            context.go(AppRoutes.printingOrders);
          },
          icon: const Icon(Icons.settings_outlined, size: 18),
          label: const Text('Configurar ahora'),
        ),
      ],
    ),
  );
}

double _effectiveItemTotal(OrderItem item) {
  return _effectiveItemAmounts(item).total;
}

double _effectiveItemSubtotal(OrderItem item) {
  return _effectiveItemAmounts(item).subtotal;
}

double _catalogItemGrossAmount(OrderItem item) {
  final modifiersTotal = item.modifiers.fold<double>(
    0.0,
    (sum, modifier) => sum + (modifier.price * modifier.qty),
  );
  return double.parse(
    ((item.unitPrice * item.quantity) + modifiersTotal).toStringAsFixed(2),
  );
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
  var netTotal = (netSubtotal + netTax).clamp(0, double.infinity).toDouble();

  // En productos inclusivos el total almacenado puede traer propina incluida.
  final catalogTotal = (_catalogItemGrossAmount(item) - item.discounts).clamp(
    0,
    double.infinity,
  );
  final useCatalogTotalForFractionalInclusive =
      item.taxMode == 'inclusive' &&
      isFractionalQty &&
      item.total > 0 &&
      (item.total - catalogTotal).abs() > 0.01;
  final storedTotal = item.taxMode == 'inclusive'
      ? (useCatalogTotalForFractionalInclusive
                ? catalogTotal
                : (item.total >= catalogTotal ? item.total : catalogTotal))
            .toDouble()
      : (item.total - item.discounts).clamp(0, double.infinity).toDouble();
  if (item.taxMode == 'inclusive' &&
      item.total > 0 &&
      (storedTotal - netTotal).abs() > 0.01) {
    netTotal = storedTotal;
  }

  return (
    subtotal: double.parse(netSubtotal.toStringAsFixed(2)),
    tax: double.parse(netTax.toStringAsFixed(2)),
    total: double.parse(netTotal.toStringAsFixed(2)),
  );
}

double _uiItemDisplayAmount(OrderItem item) {
  if (item.taxMode == 'inclusive') {
    return _effectiveItemTotal(item);
  } else {
    return _effectiveItemSubtotal(item);
  }
}

enum OrderOrigin { table, manual, quick }

class OrderScreen extends ConsumerStatefulWidget {
  final OrderOrigin origin;
  final String? tableId;
  final String? tableCode;
  final String? zoneId;
  final int initialPeopleCount;

  const OrderScreen({
    super.key,
    this.origin = OrderOrigin.table,
    this.tableId,
    this.tableCode,
    this.zoneId,
    this.initialPeopleCount = 1,
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
    final order = orderState.order;
    if (order != null && orderState.items.isEmpty) {
      final salesRepo = ref.read(salesRepositoryProvider);
      final businessId = ref.read(sessionProvider).activeBusinessId;
      try {
        await salesRepo.releaseEmptyTableIfNeeded(
          order.id,
          businessId: businessId,
        );
      } catch (_) {
        await ref.read(currentOrderProvider.notifier).cancelCurrentOrder();
      }
      final zoneVm = ref.read(byZoneVmProvider.notifier);
      if (widget.zoneId != null && widget.zoneId!.isNotEmpty) {
        await zoneVm.loadZoneStatus(widget.zoneId!, emitError: false);
      } else if (businessId != null && businessId.isNotEmpty) {
        await zoneVm.load(businessId);
      }
    }
    if (context.mounted) {
      context.go(AppRoutes.salesByZone);
    }
  }

  Future<void> _handleReleaseTable(BuildContext context) async {
    await _handleVoidCurrentOrder(
      context,
      title: 'Liberar mesa',
      content:
          'Esto anulará la orden actual y liberará la mesa. ¿Deseas continuar?',
      confirmLabel: 'Liberar',
      goToZonesOnSuccess: true,
    );
  }

  Future<void> _handleVoidCurrentOrder(
    BuildContext context, {
    required String title,
    required String content,
    required String confirmLabel,
    bool goToZonesOnSuccess = false,
  }) async {
    final orderState = ref.read(currentOrderProvider);
    if (orderState.order == null) return;

    final sessionCtrl = ref.read(sessionProvider.notifier);
    final hasDirectPermission = sessionCtrl.hasPermission(
      'ventas.orden.anular',
    );
    if (!hasDirectPermission) {
      final authorized = await showPinVerificationModal(
        context,
        ref,
        level: PinAccessLevel.supervisor,
        title: 'Autorización para anular',
        subtitle:
            'Se requiere PIN de Supervisor o Administrador para anular esta orden.',
      );
      if (!authorized) return;
      if (!context.mounted) return;
    }

    final openItems = orderState.items
        .where(_isOpenItem)
        .toList(growable: false);
    final dialogResult = await showDialog<_VoidOrderDialogResult>(
      context: context,
      builder: (dialogContext) => _VoidOrderDialog(
        title: title,
        content: content,
        confirmLabel: confirmLabel,
        openItemsCount: openItems.length,
        openItemsQty: openItems.fold<double>(
          0,
          (sum, item) => sum + item.quantity,
        ),
        totalAmount: openItems.fold<double>(0, (sum, item) => sum + item.total),
      ),
    );

    if (dialogResult == null) return;

    await ref
        .read(currentOrderProvider.notifier)
        .cancelCurrentOrder(reason: dialogResult.reason);
    if (!context.mounted) return;

    final reasonText = dialogResult.reason.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          reasonText.isEmpty
              ? 'Orden anulada correctamente.'
              : 'Orden anulada. Motivo: $reasonText',
        ),
      ),
    );

    if (goToZonesOnSuccess) {
      context.go(AppRoutes.salesByZone);
    }
  }

  String? _parseLegalName(String? notes) {
    if (notes == null) return null;
    final parts = notes.split(' | ');
    for (final part in parts) {
      if (part.trim().startsWith('business_name: ')) {
        return part.substring('business_name: '.length).trim();
      }
    }
    return null;
  }

  Future<void> _handleProductTap(
    BuildContext context,
    MenuProduct product,
  ) async {
    final vm = ref.read(currentOrderProvider.notifier);

    List<SelectedModifierInput> selectedModifiers = const [];
    if (product.itemType == 'combo') {
      final comboGroups = await vm.getMenuItemComboGroups(product.id);
      if (!context.mounted) return;
      final comboResult = await showDialog<List<SelectedModifierInput>>(
        context: context,
        builder: (_) =>
            _ComboSelectionDialog(product: product, groups: comboGroups),
      );
      if (!context.mounted || comboResult == null) return;
      selectedModifiers = comboResult;
    }

    final groups = await vm.getMenuItemModifierGroups(product.id);
    if (!context.mounted) return;
    if (groups.isNotEmpty) {
      final result = await showDialog<List<SelectedModifierInput>>(
        context: context,
        builder: (_) =>
            _ModifiersSelectionDialog(product: product, groups: groups),
      );
      if (!context.mounted || result == null) return;
      selectedModifiers = [...selectedModifiers, ...result];
    }

    await vm.addItem(
      menuItemId: product.id,
      productName: product.name,
      productPrice: product.price,
      productTaxMode: product.taxMode,
      productTaxRate: product.taxRate,
      selectedModifiers: selectedModifiers,
    );
  }

  Future<void> _handleAssignClient(BuildContext context) async {
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _AssignCustomerDialog(),
    );

    if (selected == null) return;

    final customerId = selected['id'] as String?;
    final customerName = (selected['name'] as String?)?.trim();
    final customerTaxId = selected['tax_id'] as String?;
    final notes = selected['notes'] as String?;
    final customerLegalName = _parseLegalName(notes);

    if (customerId == null || customerId.isEmpty) return;
    if (customerName == null || customerName.isEmpty) return;

    await ref
        .read(currentOrderProvider.notifier)
        .assignCustomerToCurrentOrder(
          customerId: customerId,
          customerName: customerName,
          customerLegalName: customerLegalName,
          customerTaxId: customerTaxId,
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
      notifier.openTable(
        widget.tableId!,
        peopleCount: widget.initialPeopleCount,
      );
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
                  final errorMsg =
                      orderState.error ?? 'No hay una orden activa.';
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Error: $errorMsg\nPor favor envíame una captura de este mensaje.',
                        maxLines: 4,
                      ),
                    ),
                  );
                  return;
                }
                _handleProductTap(context, product);
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
                  onVoidOrder: () => _handleVoidCurrentOrder(
                    context,
                    title: 'Anular orden',
                    content:
                        'Esta acción anulará la orden actual. Si la mesa no tiene más órdenes activas, también quedará liberada. ¿Deseas continuar?',
                    confirmLabel: 'Anular',
                  ),
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

class _VoidOrderDialogResult {
  final String reason;

  const _VoidOrderDialogResult({required this.reason});
}

class _VoidOrderDialog extends StatefulWidget {
  final String title;
  final String content;
  final String confirmLabel;
  final int openItemsCount;
  final double openItemsQty;
  final double totalAmount;

  const _VoidOrderDialog({
    required this.title,
    required this.content,
    required this.confirmLabel,
    required this.openItemsCount,
    required this.openItemsQty,
    required this.totalAmount,
  });

  @override
  State<_VoidOrderDialog> createState() => _VoidOrderDialogState();
}

class _VoidOrderDialogState extends State<_VoidOrderDialog> {
  final TextEditingController _reasonCtrl = TextEditingController();

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat('#,##0.00', 'en_US');

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.content),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFED7AA)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Impacto de la anulación',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text('Líneas abiertas: ${widget.openItemsCount}'),
                  Text(
                    'Cantidad abierta: ${widget.openItemsQty.toStringAsFixed(widget.openItemsQty % 1 == 0 ? 0 : 2)}',
                  ),
                  Text(
                    'Total abierto: RD\$ ${currency.format(widget.totalAmount)}',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _reasonCtrl,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Motivo de anulación *',
                hintText:
                    'Ej: cliente desistió, error de captura, duplicada...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'El motivo se guardará en la nota de la sesión para dejar rastro operativo.',
              style: TextStyle(fontSize: 12, color: _salesTextSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final reason = _reasonCtrl.text.trim();
            if (reason.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Indica el motivo de la anulación.'),
                ),
              );
              return;
            }
            Navigator.pop(context, _VoidOrderDialogResult(reason: reason));
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

String? _extractLatestVoidAudit(String? note) {
  if (note == null || note.trim().isEmpty) return null;
  final lines = note
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('[ANULACION]'))
      .toList(growable: false);
  if (lines.isEmpty) return null;
  return lines.last;
}

// -----------------------------------------------------------------------------
// 2. VISTA DE CARRITO
// -----------------------------------------------------------------------------
class _CartView extends ConsumerWidget {
  final OrderOrigin origin;
  final String tableCode;
  final bool isStacked;
  final Future<void> Function() onAssignClient;
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

  String _sendKitchenActionKey(String? orderId) {
    return 'send_kitchen:${orderId ?? 'none'}';
  }

  String _printActionKey(String type, {String? orderId, String? checkId}) {
    return 'print:$type:${orderId ?? 'none'}:${checkId ?? 'all'}';
  }

  String _reprintActionKey(String orderId, List<OrderItem> items) {
    final itemIds = items.map((item) => item.id).toList()..sort();
    return 'reprint:$orderId:${itemIds.join(",")}';
  }

  bool _isActionLocked(WidgetRef ref, String key) {
    return ref.watch(
      _salesActionLocksProvider.select(
        (activeLocks) => activeLocks.contains(key),
      ),
    );
  }

  Future<void> _runLockedAction(
    WidgetRef ref,
    String key,
    Future<void> Function() action,
  ) async {
    final activeLocks = ref.read(_salesActionLocksProvider);
    if (activeLocks.contains(key)) return;

    final notifier = ref.read(_salesActionLocksProvider.notifier);
    notifier.state = {...activeLocks, key};

    try {
      await action();
    } finally {
      final nextLocks = {...ref.read(_salesActionLocksProvider)};
      nextLocks.remove(key);
      notifier.state = nextLocks;
    }
  }

  void _openPaymentModal(
    BuildContext context,
    WidgetRef ref,
    Order order,
    double total, {
    String? checkId,
    String? customerId,
    String? customerName,
  }) async {
    var currentOrderState = ref.read(currentOrderProvider);
    final isFiscal =
        currentOrderState.fiscalType == 'B01' ||
        currentOrderState.fiscalType == '01' ||
        currentOrderState.fiscalType == 'B14' ||
        currentOrderState.fiscalType == '14' ||
        currentOrderState.fiscalType == 'B15' ||
        currentOrderState.fiscalType == '15' ||
        currentOrderState.fiscalType == 'E31' ||
        currentOrderState.fiscalType == '31';

    if (isFiscal) {
      // Usamos los valores del estado para la validación inicial
      if (currentOrderState.customerId == null ||
          currentOrderState.customerId!.isEmpty ||
          currentOrderState.customerTaxId == null ||
          currentOrderState.customerTaxId!.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Para comprobante fiscal se requiere un cliente con RNC/Cédula.',
            ),
            backgroundColor: Colors.orange,
          ),
        );

        await onAssignClient();

        // RE-LEER estado después de la asignación
        currentOrderState = ref.read(currentOrderProvider);
        if (currentOrderState.customerId == null ||
            currentOrderState.customerId!.isEmpty ||
            currentOrderState.customerTaxId == null ||
            currentOrderState.customerTaxId!.trim().isEmpty) {
          return; // Sigue sin cliente o sin RNC válido
        }
      }
    }

    // Sincronizar estas variables con el estado más reciente
    final finalCustomerId = currentOrderState.customerId;
    final finalCustomerName = currentOrderState.customerName;
    final finalFiscalType = currentOrderState.fiscalType;
    final finalCustomerTaxId = currentOrderState.customerTaxId;
    final finalCustomerLegalName = currentOrderState.customerLegalName;
    final prePaymentItems = checkId == null
        ? List<OrderItem>.from(currentOrderState.items)
        : currentOrderState.items.where((i) => i.checkId == checkId).toList();
    var prePaymentOrder = order;
    if (checkId != null) {
      try {
        final check = currentOrderState.checks.firstWhere(
          (c) => c.id == checkId,
        );
        prePaymentOrder = check.toOrder(createdAt: order.createdAt);
      } catch (_) {
        prePaymentOrder = order;
      }
    }

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
        customerId: finalCustomerId,
        customerName: finalCustomerName,
        fiscalType: finalFiscalType,
      ),
    ).then((result) async {
      if (result is List<Payment>) {
        if (!context.mounted) return;

        // INSTANT LOAD: Use data from result + local state
        final payments = result;
        final items = List<OrderItem>.from(prePaymentItems);
        final printOrder = prePaymentOrder;

        final businessProfile = await _loadBusinessReceiptProfile(ref);
        final fiscalDoc = await _loadFiscalDocument(ref, order.id);
        final waiterName =
            await _loadWaiterName(ref, order.id) ??
            ref.read(sessionProvider).userName;
        final issuedAt =
            fiscalDoc?.issuedAt ??
            (payments.isNotEmpty
                ? payments
                      .map((payment) => payment.createdAt)
                      .reduce((a, b) => a.isAfter(b) ? a : b)
                : order.createdAt);
        // Optional: Filter items if paying a specific check (though strictly we show all items on invoice or filter inside modal)

        final ncfFromPayment = payments.isNotEmpty
            ? payments.last.reference
            : null;
        final printedFiscalType = fiscalDoc?.ncfType ?? finalFiscalType;

        if (context.mounted) {
          final invoicePrintLockKey = _printActionKey(
            'invoice',
            orderId: printOrder.id,
            checkId: checkId,
          );
          final invoiceData = {
            'title': '*** FACTURA ***',
            'restaurantName': businessProfile.name,
            'legalName': businessProfile.legalName,
            'rnc': businessProfile.rnc,
            'phone': businessProfile.phone,
            'address': businessProfile.address,
            'ncf': ncfFromPayment ?? fiscalDoc?.ncfNumber,
            'fiscalType': printedFiscalType,
            'customerName': finalCustomerName,
            'customerLegalName': finalCustomerLegalName,
            'customerTaxId': finalCustomerTaxId,
            'issuedAt': issuedAt.toIso8601String(),
            'tableName': tableName,
            'waiterName': waiterName,
            'items': items
                .map(
                  (i) => {
                    'quantity': i.quantity,
                    'name': i.productName,
                    'price': itemDisplayTotal(printOrder, i),
                  },
                )
                .toList(),
            'subtotal': printOrder.subtotal,
            'tax': printOrder.tax,
            'serviceFee': printOrder.serviceFee,
            'total': printOrder.total,
          };

          // Define completion logic
          void onFinish() {
            if (checkId == null) {
              if (context.mounted) context.go(AppRoutes.salesByZone);
            } else {
              ref.read(currentOrderProvider.notifier).refreshOrder();
            }
          }

          try {
            await _runLockedAction(ref, invoicePrintLockKey, () async {
              await _handlePrintFlow(
                context,
                ref,
                'invoice',
                invoiceData,
                orderObj: printOrder,
                orderItems: items,
                payments: payments,
                tableName: tableName,
                waiterName: waiterName,
                showSnackBar: true,
              );
            });
            onFinish();
          } catch (e) {
            if (context.mounted) {
              _showReimpresionDialog(
                context: context,
                ref: ref,
                type: 'invoice',
                data: invoiceData,
                orderObj: order,
                orderItems: items,
                payments: payments,
                tableName: tableName,
                waiterName: waiterName,
                errorMsg: e.toString(),
                onFinish: onFinish,
              );
            }
          }
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
    OrderItem item, {
    List<OrderItem>? groupedItems,
  }) {
    showDialog(
      context: context,
      builder: (context) => ProductDetailModal(
        item: item,
        groupedItems: groupedItems,
        loadModifierGroups: (menuItemId) => ref
            .read(currentOrderProvider.notifier)
            .getMenuItemModifierGroups(menuItemId),
        onReplaceModifiers: (itemId, selectedModifiers) => ref
            .read(currentOrderProvider.notifier)
            .replaceItemModifiers(
              itemId: itemId,
              selectedModifiers: selectedModifiers,
            ),
        onSave: (updatedItem) async {
          await ref
              .read(currentOrderProvider.notifier)
              .updateItem(item.id, updatedItem);
        },
        onSaveBatch: (items, updatedItem, reductionReason) async {
          final salesRepo = ref.read(salesRepositoryProvider);
          final orderNotifier = ref.read(currentOrderProvider.notifier);
          final totalBase = items.fold<double>(
            0,
            (sum, current) => sum + (current.subtotal + current.tax),
          );
          final originalTotalQty = items.fold<double>(
            0,
            (sum, current) => sum + current.quantity,
          );
          final targetTotalQty = updatedItem.quantity <= 0
              ? 1.0
              : updatedItem.quantity;
          var qtyToDistribute = targetTotalQty;

          for (var index = 0; index < items.length; index++) {
            final current = items[index];
            final isLast = index == items.length - 1;
            double nextQty;

            if (targetTotalQty >= originalTotalQty) {
              nextQty = isLast ? qtyToDistribute : current.quantity;
            } else {
              final remainingAfterCurrent = qtyToDistribute - current.quantity;
              if (remainingAfterCurrent >= 0) {
                nextQty = current.quantity;
              } else {
                nextQty = qtyToDistribute.clamp(0, current.quantity).toDouble();
              }
            }

            if (isLast) {
              nextQty = qtyToDistribute.clamp(0, double.infinity).toDouble();
            }

            final base = current.subtotal + current.tax;
            final discountShare = totalBase > 0
                ? (updatedItem.discounts * (base / totalBase))
                : 0.0;
            final trimmedNotes = updatedItem.notes?.trim();
            final mergedNotes = <String>[];
            if (trimmedNotes != null && trimmedNotes.isNotEmpty) {
              mergedNotes.add(trimmedNotes);
            }
            if (reductionReason != null && reductionReason.trim().isNotEmpty) {
              mergedNotes.add('[REDUCCION:${reductionReason.trim()}]');
            }

            if (nextQty <= 0.0001) {
              await orderNotifier.deleteItem(
                current.id,
                reason: reductionReason ?? 'Reducción de cantidad',
              );
            } else {
              await salesRepo.updateItemDetails(
                itemId: current.id,
                productName: updatedItem.productName,
                quantity: nextQty,
                isTakeout: updatedItem.isTakeout,
                discounts: discountShare,
                notes: mergedNotes.isEmpty ? null : mergedNotes.join('\n'),
              );
            }

            qtyToDistribute -= nextQty;
          }

          await ref.read(currentOrderProvider.notifier).refreshOrder();
        },
        onDelete: (reason) async {
          await ref
              .read(currentOrderProvider.notifier)
              .deleteItem(item.id, reason: reason);
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
        onReprint: (item.status != 'draft')
            ? () {
                final order = ref.read(currentOrderProvider).order;
                final itemsToReprint = groupedItems?.isNotEmpty == true
                    ? groupedItems!
                    : [item];
                if (order == null) return;

                final reprintLockKey = _reprintActionKey(
                  order.id,
                  itemsToReprint,
                );
                if (ref
                    .read(_salesActionLocksProvider)
                    .contains(reprintLockKey)) {
                  return;
                }

                unawaited(
                  _runLockedAction(ref, reprintLockKey, () async {
                    await ref
                        .read(currentOrderProvider.notifier)
                        .reprintKitchenTicket(
                          orderId: order.id,
                          items: itemsToReprint,
                        );
                  }),
                );
              }
            : null,
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
    OrderCheck? selectedCheck;
    if (selectedCheckId != null) {
      for (final check in allChecks) {
        if (check.id == selectedCheckId) {
          selectedCheck = check;
          break;
        }
      }
    }
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
    final pricingSummary = summarizeOrderPricing(
      orderState.order,
      displayedItems,
    );
    final displayDiscounts = pricingSummary.discounts;
    // Show Gross Subtotal to justify the Discount line below it
    final displaySubtotal = pricingSummary.subtotal;
    final displayTax = pricingSummary.tax;
    final displayServiceFee =
        selectedCheck?.serviceFee ??
        (pricingSummary.serviceFee > 0
            ? pricingSummary.serviceFee
            : (orderState.order?.serviceFee ?? 0.0));
    final displayTotal = pricingSummary.total;

    final pendingOrderItems = openItems.where((i) {
      final checkIsClosed = allChecks.any(
        (c) => c.id == i.checkId && c.isClosed,
      );
      return !checkIsClosed;
    }).toList();

    final pendingOrderTotal = summarizeOrderPricing(
      orderState.order,
      pendingOrderItems,
    ).total;

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
      final totalItem = _uiItemDisplayAmount(item);
      final groupKey = '${name.toLowerCase().trim()}|${item.isTakeout}';
      if (groupedSent.containsKey(groupKey)) {
        groupedSent[groupKey] = groupedSent[groupKey]!.copyWith(
          qty: groupedSent[groupKey]!.qty + qty,
          total: groupedSent[groupKey]!.total + totalItem,
          items: [...groupedSent[groupKey]!.items, item],
        );
      } else {
        groupedSent[groupKey] = _GroupedSentItem(
          name: name,
          qty: qty,
          total: totalItem,
          isTakeout: item.isTakeout,
          items: [item],
        );
      }
    }
    final groupedSentItems = groupedSent.values.toList();
    final latestVoidAudit = _extractLatestVoidAudit(orderState.sessionNote);
    final currentOrderId = orderState.order?.id;
    final sendKitchenLockKey = _sendKitchenActionKey(currentOrderId);
    final precheckLockKey = _printActionKey(
      'precheck',
      orderId: currentOrderId,
      checkId: selectedCheckId,
    );
    final sendKitchenLocked =
        orderState.loading || _isActionLocked(ref, sendKitchenLockKey);
    final precheckLocked = _isActionLocked(ref, precheckLockKey);

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
                                ? (tableCode.toLowerCase().startsWith('mesa')
                                      ? tableCode
                                      : 'Mesa $tableCode')
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
                            '${_formatQtyBadge(itemsCount)} ${itemsCount == 1 ? "producto" : "productos"}',
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
                        if (orderState.isOfflineMode ||
                            orderState.syncInFlight ||
                            orderState.pendingOfflineActions > 0)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _OrderSyncStatusChip(orderState: orderState),
                          ),
                        OutlinedButton.icon(
                          onPressed: onAssignClient,
                          icon: const Icon(Icons.person_outline, size: 16),
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 148),
                            child: Text(
                              orderState.customerName?.trim().isNotEmpty == true
                                  ? orderState.customerName!
                                  : 'Cliente',
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
                        const SizedBox(height: 12),
                        // Dropdown de Comprobante
                        Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: _salesDivider),
                            borderRadius: BorderRadius.circular(
                              _salesRadiusButton,
                            ),
                          ),
                          child: PopupMenuButton<String>(
                            initialValue: orderState.fiscalType,
                            onSelected: (String newValue) {
                              ref
                                  .read(currentOrderProvider.notifier)
                                  .updateFiscalType(newValue);
                            },
                            tooltip: 'Tipo de comprobante',
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            offset: const Offset(0, 40),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${_getNcfLabel(orderState.fiscalType)} (${orderState.fiscalType})',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: _salesTextPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.arrow_drop_down,
                                    color: _salesTotalColor,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                            itemBuilder: (BuildContext context) {
                              final sequences =
                                  orderState.fiscalSequences.isNotEmpty
                                  ? orderState.fiscalSequences
                                  : [
                                      FiscalNcfSequence(
                                        tipo: 'B02',
                                        serie: 'B',
                                        ultimoSeq: 0,
                                        maximoSeq: 0,
                                      ),
                                      FiscalNcfSequence(
                                        tipo: 'B01',
                                        serie: 'B',
                                        ultimoSeq: 0,
                                        maximoSeq: 0,
                                      ),
                                      FiscalNcfSequence(
                                        tipo: 'B14',
                                        serie: 'B',
                                        ultimoSeq: 0,
                                        maximoSeq: 0,
                                      ),
                                      FiscalNcfSequence(
                                        tipo: 'B15',
                                        serie: 'B',
                                        ultimoSeq: 0,
                                        maximoSeq: 0,
                                      ),
                                    ];

                              return sequences.map((seq) {
                                return PopupMenuItem<String>(
                                  value: seq.tipo,
                                  child: Text(
                                    '${_getNcfLabel(seq.tipo)} (${seq.tipo})',
                                  ),
                                );
                              }).toList();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

        if (orderState.order != null ||
            (orderState.sessionNote?.trim().isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              children: [
                if (orderState.order != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (orderState.order!.closedAt != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: const Color(0xFFBFDBFE),
                              ),
                            ),
                            child: Text(
                              'Cerrada ${DateFormat('dd/MM HH:mm').format(orderState.order!.closedAt!.toLocal())}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1D4ED8),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (latestVoidAudit != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.history_toggle_off,
                          color: Color(0xFFDC2626),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Última anulación registrada',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF991B1B),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                latestVoidAudit,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF7F1D1D),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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
                              isTakeout: groupedSentItems[i].isTakeout,
                              onTap: () => _openProductDetailModal(
                                context,
                                ref,
                                groupedSentItems[i].items.first,
                                groupedItems: groupedSentItems[i].items,
                              ),
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
              if (displayServiceFee > 0) ...[
                const SizedBox(height: 8),
                _SummaryRow(
                  label: 'Propina Ley (10%)',
                  value: 'RD\$ ${currency.format(displayServiceFee)}',
                ),
              ],
              if (displayDiscounts > 0) ...[
                const SizedBox(height: 8),
                _SummaryRow(
                  label: 'Descuento',
                  value: '- RD\$ ${currency.format(displayDiscounts)}',
                  valueColor: const Color(0xFF16A34A),
                  valueWeight: FontWeight.w700,
                ),
              ],
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
                    onPressed: sendKitchenLocked
                        ? null
                        : () async {
                            await _runLockedAction(
                              ref,
                              sendKitchenLockKey,
                              () async {
                                try {
                                  final waiterName =
                                      await _loadWaiterName(
                                        ref,
                                        orderState.order!.id,
                                      ) ??
                                      ref.read(sessionProvider).userName;
                                  if (!context.mounted) return;
                                  await ref
                                      .read(currentOrderProvider.notifier)
                                      .confirmOrder(
                                        tableName: tableCode,
                                        waiterName: waiterName,
                                      );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Orden enviada a cocina'),
                                    ),
                                  );
                                } on NoAssignedKitchenPrinterException catch (
                                  e
                                ) {
                                  if (!context.mounted) return;
                                  await _showMissingKitchenPrinterDialog(
                                    context,
                                    e,
                                  );
                                } catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Error al enviar a cocina: ${e.toString()}',
                                      ),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              },
                            );
                          },
                    icon: Icons.soup_kitchen_outlined,
                  ),
                  const SizedBox(height: 12),
                  // Pagar solo visible si no hay drafts? Or always?
                  // Usually you can pay what is sent.
                  // Existing code only showed Pay if drafts exist alongside Send?
                  // It seems draft items replace payment flow until sent?
                  // Let's keep existing logic: if drafts, show Pay AND Send? No, usually Send first.
                  // Original code showed BOTH.
                  if (selectedCheckId != null && hasChecks) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar esta cuenta RD\$ ${currency.format(displayTotal)}',
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
                                    customerId:
                                        selectedCheck?.customerId ??
                                        orderState.customerId,
                                    customerName:
                                        selectedCheck?.customerName ??
                                        orderState.customerName,
                                  ),
                            icon: Icons.payments_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar todo lo pendiente RD\$ ${currency.format(pendingOrderTotal)}',
                            background: _salesPayButton,
                            onPressed:
                                !canCharge ||
                                    orderState.order == null ||
                                    pendingOrderTotal <= 0
                                ? null
                                : () => _openPaymentModal(
                                    context,
                                    ref,
                                    orderState.order!,
                                    pendingOrderTotal,
                                    checkId: null,
                                    customerId: orderState.customerId,
                                    customerName: orderState.customerName,
                                  ),
                            icon: Icons.point_of_sale_rounded,
                          ),
                        ),
                      ],
                    ),
                  ] else
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
                          onPressed: precheckLocked
                              ? null
                              : () async {
                                  await _runLockedAction(
                                    ref,
                                    precheckLockKey,
                                    () async {
                                      if (orderState.order != null) {
                                        final businessProfile =
                                            await _loadBusinessReceiptProfile(
                                              ref,
                                            );
                                        final waiterName =
                                            await _loadWaiterName(
                                              ref,
                                              orderState.order!.id,
                                            ) ??
                                            ref.read(sessionProvider).userName;
                                        if (!context.mounted) return;
                                        final preCheckData = {
                                          'restaurantName':
                                              businessProfile.name,
                                          'businessName':
                                              businessProfile.businessName,
                                          'legalName':
                                              businessProfile.legalName,
                                          'rnc': businessProfile.rnc,
                                          'phone': businessProfile.phone,
                                          'address': businessProfile.address,
                                          'tableName':
                                              '$tableCode ${selectedCheckId != null ? "(Cuentas Separadas)" : ""}',
                                          'waiterName': waiterName,
                                          'items': displayedItems
                                              .map(
                                                (i) => {
                                                  'quantity': i.quantity,
                                                  'name': i.productName,
                                                  'price': _effectiveItemTotal(
                                                    i,
                                                  ),
                                                },
                                              )
                                              .toList(),
                                          'subtotal': displaySubtotal,
                                          'tax': displayTax,
                                          'total': displayTotal,
                                        };

                                        try {
                                          await _handlePrintFlow(
                                            context,
                                            ref,
                                            'precheck',
                                            preCheckData,
                                            orderObj: orderState.order!,
                                            orderItems: displayedItems,
                                            tableName:
                                                preCheckData['tableName']
                                                    as String?,
                                            waiterName:
                                                preCheckData['waiterName']
                                                    as String?,
                                          );
                                        } catch (e) {
                                          if (context.mounted) {
                                            _showReimpresionDialog(
                                              context: context,
                                              ref: ref,
                                              type: 'precheck',
                                              data: preCheckData,
                                              orderObj: orderState.order!,
                                              orderItems: displayedItems,
                                              tableName:
                                                  preCheckData['tableName']
                                                      as String?,
                                              waiterName:
                                                  preCheckData['waiterName']
                                                      as String?,
                                              errorMsg: e.toString(),
                                            );
                                          }
                                        }
                                      }
                                    },
                                  );
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
                  if (selectedCheckId != null && hasChecks) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar esta cuenta RD\$ ${currency.format(displayTotal)}',
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
                                    customerId:
                                        selectedCheck?.customerId ??
                                        orderState.customerId,
                                    customerName:
                                        selectedCheck?.customerName ??
                                        orderState.customerName,
                                  ),
                            icon: Icons.payments_rounded,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ActionButton(
                            label:
                                'Pagar todo lo pendiente RD\$ ${currency.format(pendingOrderTotal)}',
                            background: _salesPayButton,
                            onPressed:
                                !canCharge ||
                                    orderState.order == null ||
                                    pendingOrderTotal <= 0
                                ? null
                                : () => _openPaymentModal(
                                    context,
                                    ref,
                                    orderState.order!,
                                    pendingOrderTotal,
                                    checkId: null,
                                    customerId: orderState.customerId,
                                    customerName: orderState.customerName,
                                  ),
                            icon: Icons.point_of_sale_rounded,
                          ),
                        ),
                      ],
                    ),
                  ] else
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
    bool showSnackBar = true,
  }) async {
    try {
      final printRepo = ref.read(printingPrintersRepositoryProvider);
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        throw Exception('Negocio no resuelto.');
      }

      final assignedPrinterFuture = printRepo.getAssignedPrinterForType(
        businessId: businessId,
        preferredAreaCodes: type == 'invoice'
            ? const ['fiscal', 'cashier']
            : const ['cashier', 'fiscal'],
        printsPrebills: type == 'precheck',
        printsReceipts: type == 'invoice',
      );
      final receiptItemDisplayModeFuture = ref
          .read(posSettingsRepositoryProvider)
          .getReceiptItemDisplayMode(businessId);

      final assignedPrinter = await assignedPrinterFuture;

      if (assignedPrinter == null) {
        throw Exception('Impresora no configurada.');
      }

      final receiptItemDisplayMode = await receiptItemDisplayModeFuture;

      // Preparación de datos (fuera del timeout para no penalizar generación)
      dynamic ticket;
      if ((type == 'precheck' || type == 'invoice') &&
          orderObj != null &&
          orderItems != null) {
        final title =
            data['title'] as String? ??
            (type == 'invoice' ? 'FACTURA' : 'PRECUENTA');

        ticket = type == 'invoice'
            ? PrintTicketService.generateInvoice(
                order: orderObj,
                items: orderItems,
                payments: payments ?? [],
                tableName: tableName ?? 'Mesa',
                waiterName: waiterName,
                businessName: data['restaurantName'] as String?,
                legalName: data['legalName'] as String?,
                businessAddress: data['address'] as String?,
                businessPhone: data['phone'] as String?,
                businessRnc: data['rnc'] as String?,
                fiscalNcf: data['ncf'] as String?,
                fiscalType: data['fiscalType'] as String?,
                customerName: data['customerName'] as String?,
                customerLegalName: data['customerLegalName'] as String?,
                customerTaxId: data['customerTaxId'] as String?,
                issuedAt: data['issuedAt'] == null
                    ? null
                    : DateTime.tryParse(data['issuedAt'].toString()),
                title: title,
                receiptItemDisplayMode: receiptItemDisplayMode,
              )
            : PrintTicketService.generatePrecheck(
                order: orderObj,
                items: orderItems,
                tableName: tableName ?? 'Mesa',
                waiterName: waiterName,
                businessName:
                    (data['businessName'] as String?) ??
                    (data['restaurantName'] as String?),
                legalName: data['legalName'] as String?,
                businessAddress: data['address'] as String?,
                businessPhone: data['phone'] as String?,
                businessRnc: data['rnc'] as String?,
                title: title,
                receiptItemDisplayMode: receiptItemDisplayMode,
              );
      }

      final printTimeout = const Duration(seconds: 3);
      final isUsbPrinter = assignedPrinter.printerType == PrinterType.usb;

      final printFuture = Future(() async {
        if (ticket != null) {
          await printRepo.printEscPos(
            printer: assignedPrinter,
            data: ticket.escPosCommands,
          );
        } else {
          if (!assignedPrinter.isNetwork) {
            throw Exception(
              'La impresión ${assignedPrinter.type} requiere generar el ticket ESC/POS antes de enviarlo.',
            );
          }
          final ip = assignedPrinter.ipAddress?.trim();
          if (ip == null || ip.isEmpty) {
            throw Exception('La impresora de red no tiene IP configurada.');
          }
          await printRepo.printJobViaAgent({
            'id':
                '${type.toUpperCase()}-${DateTime.now().millisecondsSinceEpoch}',
            'printer': {
              'type': 'network',
              'ip': ip,
              'port': assignedPrinter.port ?? 9100,
            },
            'content': {'type': type, 'data': data},
          });
        }
      });

      unawaited(
        printFuture.catchError((error, stackTrace) {
          debugPrint(
            'Impresión en ${assignedPrinter.name} falló después del timeout: $error',
          );
        }),
      );

      try {
        await printFuture.timeout(
          printTimeout,
          onTimeout: () => throw TimeoutException('Timeout'),
        );
      } on TimeoutException {
        if (!isUsbPrinter) {
          throw Exception('Timeout');
        }
        debugPrint(
          'La impresora USB ${assignedPrinter.name} sigue procesando el ticket tras $printTimeout. Ignoramos el timeout.',
        );
      }

      if (showSnackBar && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Imprimiendo en ${assignedPrinter.name}...'),
            backgroundColor: const Color(0xFF22C55E),
          ),
        );
      }
    } catch (e) {
      rethrow;
    }
  }

  String _getNcfLabel(String tipo) {
    switch (tipo) {
      case 'B01':
      case '01':
        return 'Crédito Fiscal';
      case 'B02':
      case '02':
        return 'Consumo';
      case 'B14':
      case '14':
        return 'Reg. Espec.';
      case 'B15':
      case '15':
        return 'Gubernamental';
      case 'E31':
      case '31':
        return 'Elect. Crédito Fiscal';
      case 'E32':
      case '32':
        return 'Elect. Consumidor';
      default:
        return tipo;
    }
  }

  void _showReimpresionDialog({
    required BuildContext context,
    required WidgetRef ref,
    required String type,
    required Map<String, dynamic> data,
    Order? orderObj,
    List<OrderItem>? orderItems,
    List<Payment>? payments,
    String? tableName,
    String? waiterName,
    required String errorMsg,
    VoidCallback? onFinish,
  }) {
    final retryPrintLockKey = _printActionKey(
      type,
      orderId: orderObj?.id,
      checkId: data['checkId']?.toString(),
    );
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon Container
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFFEE2E2), width: 2),
                ),
                child: const Icon(
                  Icons.print_disabled_rounded,
                  color: Color(0xFFEF4444),
                  size: 48,
                ),
              ),
              const SizedBox(height: 24),

              // Title
              const Text(
                'Fallo de Impresión',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: _salesTextPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),

              // Message
              const Text(
                'No pudimos procesar la impresión. ¿Deseas intentar enviar el trabajo nuevamente?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: _salesTextSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),

              const SizedBox(height: 32),

              // Actions
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        onFinish?.call();
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(
                          color: _salesTextSecondary,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        if (ref
                            .read(_salesActionLocksProvider)
                            .contains(retryPrintLockKey)) {
                          return;
                        }
                        Navigator.pop(ctx);
                        await _runLockedAction(
                          ref,
                          retryPrintLockKey,
                          () async {
                            try {
                              await _handlePrintFlow(
                                context,
                                ref,
                                type,
                                data,
                                orderObj: orderObj,
                                orderItems: orderItems,
                                payments: payments,
                                tableName: tableName,
                                waiterName: waiterName,
                                showSnackBar: true,
                              );
                              onFinish?.call();
                            } catch (e) {
                              _showReimpresionDialog(
                                context: context,
                                ref: ref,
                                type: type,
                                data: data,
                                orderObj: orderObj,
                                orderItems: orderItems,
                                payments: payments,
                                tableName: tableName,
                                waiterName: waiterName,
                                errorMsg: e.toString(),
                                onFinish: onFinish,
                              );
                            }
                          },
                        );
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: _salesTotalColor,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Reintentar',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
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
  final VoidCallback onVoidOrder;
  final VoidCallback onApplyDiscount;
  final VoidCallback onApplyCourtesy;

  const _SalesToolsRail({
    required this.onBack,
    required this.showTableActions,
    required this.onReleaseTable,
    required this.onVoidOrder,
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
                    icon: Icons.block_rounded,
                    label: 'Anular\norden',
                    onTap: onVoidOrder,
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
    final totalItem = _uiItemDisplayAmount(item).toStringAsFixed(2);
    final modifiers = item.modifiers;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: Colors.black.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  qty,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _salesTextPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (!isDraft)
                const Padding(
                  padding: EdgeInsets.only(right: 6, top: 2),
                  child: Icon(
                    Icons.check_circle,
                    size: 16,
                    color: Color(0xFF22C55E),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Container(
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
              ),
              if (item.isTakeout) ...[
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E8),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.shopping_bag_outlined,
                      size: 13,
                      color: Color(0xFFF97316),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: _salesTextPrimary,
                      ),
                    ),
                    if (modifiers.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: modifiers
                            .map((modifier) {
                              final hasExtraCost = modifier.price > 0.009;
                              final qtyLabel = modifier.qty > 1
                                  ? '${modifier.qty.toStringAsFixed(modifier.qty % 1 == 0 ? 0 : 1)}x '
                                  : '';
                              final isComboChoice = modifier.name.contains(
                                ': ',
                              );
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isComboChoice
                                      ? const Color(0xFFFFF7ED)
                                      : const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: isComboChoice
                                        ? const Color(0xFFFED7AA)
                                        : const Color(0xFFE2E8F0),
                                  ),
                                ),
                                child: Text(
                                  hasExtraCost
                                      ? '$qtyLabel${modifier.name} (+RD\$ ${modifier.price.toStringAsFixed(2)})'
                                      : '$qtyLabel${modifier.name}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isComboChoice
                                        ? const Color(0xFF9A3412)
                                        : const Color(0xFF475569),
                                  ),
                                ),
                              );
                            })
                            .toList(growable: false),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'RD\$ $totalItem',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _salesTotalColor,
                  ),
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
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(
        minHeight: 54,
      ), // Altura mínima para consistencia
      child: ElevatedButton(
        onPressed: onPressed,
        style:
            ElevatedButton.styleFrom(
              backgroundColor: background,
              disabledBackgroundColor: background.withValues(alpha: 0.35),
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ), // Padding interno para multi-línea
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_salesRadiusButton),
              ),
            ).copyWith(
              overlayColor: WidgetStateProperty.all(
                Colors.white.withValues(alpha: 0.08),
              ),
            ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: Colors.white),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center, // Texto centrado
                style: const TextStyle(
                  fontSize:
                      14, // Ligeramente más pequeño para optimizar espacio
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.1, // Altura de línea compacta
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecondaryActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  const _SecondaryActionButton({
    required this.label,
    required this.onPressed,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 54),
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: onPressed == null
              ? _salesTabActiveBg.withValues(alpha: 0.45)
              : _salesTabActiveBg,
          side: BorderSide(
            color: onPressed == null
                ? _salesDivider.withValues(alpha: 0.55)
                : _salesDivider,
          ),
          disabledForegroundColor: _salesTextPrimary.withValues(alpha: 0.45),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_salesRadiusButton),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: onPressed == null
                  ? _salesTextPrimary.withValues(alpha: 0.45)
                  : _salesTextPrimary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: onPressed == null
                      ? _salesTextPrimary.withValues(alpha: 0.45)
                      : _salesTextPrimary,
                  height: 1.1,
                ),
              ),
            ),
          ],
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
  final bool isTakeout;
  final VoidCallback? onTap;

  const _SentLineItem({
    required this.name,
    required this.qty,
    required this.total,
    required this.isTakeout,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            // Cantidad
            // Cantidad: Centrada en 52px y más compacta
            SizedBox(
              width: 52,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
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
            if (isTakeout) ...[
              const SizedBox(width: 6),
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E8),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(
                  Icons.shopping_bag_outlined,
                  size: 14,
                  color: Color(0xFFF97316),
                ),
              ),
            ],
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
      ),
    );
  }
}

class _OrderSyncStatusChip extends ConsumerWidget {
  final CurrentOrderState orderState;

  const _OrderSyncStatusChip({required this.orderState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Color color = orderState.isOfflineMode
        ? const Color(0xFFF59E0B)
        : orderState.syncInFlight
        ? const Color(0xFF2563EB)
        : const Color(0xFF10B981);
    final IconData icon = orderState.isOfflineMode
        ? Icons.cloud_off_rounded
        : orderState.syncInFlight
        ? Icons.sync
        : Icons.cloud_done_rounded;
    final String text = orderState.isOfflineMode
        ? 'Offline'
        : orderState.syncInFlight
        ? 'Sincronizando'
        : orderState.pendingOfflineActions > 0
        ? 'Pendiente sync'
        : 'Al día';

    final lastSyncLabel = orderState.lastSyncAt == null
        ? null
        : '${orderState.lastSyncAt!.hour.toString().padLeft(2, '0')}:${orderState.lastSyncAt!.minute.toString().padLeft(2, '0')}';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.30)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                orderState.pendingOfflineActions > 0
                    ? '$text • ${orderState.pendingOfflineActions}'
                    : text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (lastSyncLabel != null) ...[
                const SizedBox(width: 6),
                Text(
                  '• $lastSyncLabel',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: orderState.syncInFlight
              ? null
              : () async {
                  await ref
                      .read(currentOrderProvider.notifier)
                      .syncPendingOfflineActions(force: true);
                },
          icon: const Icon(Icons.sync_rounded, size: 15),
          label: const Text('Sync'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        ),
      ],
    );
  }
}

class _GroupedSentItem {
  final String name;
  final double qty;
  final double total;
  final bool isTakeout;
  final List<OrderItem> items;

  const _GroupedSentItem({
    required this.name,
    required this.qty,
    required this.total,
    required this.isTakeout,
    required this.items,
  });

  _GroupedSentItem copyWith({
    String? name,
    double? qty,
    double? total,
    bool? isTakeout,
    List<OrderItem>? items,
  }) {
    return _GroupedSentItem(
      name: name ?? this.name,
      qty: qty ?? this.qty,
      total: total ?? this.total,
      isTakeout: isTakeout ?? this.isTakeout,
      items: items ?? this.items,
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
  final ScrollController _customersScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(customersViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _customersScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openCreateCustomerFlow() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CreateCustomerDialog(),
    );

    if (!mounted || created == null) return;
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(customersViewModelProvider);
    final media = MediaQuery.of(context);
    final dialogWidth = media.size.width < 980 ? media.size.width - 32 : 920.0;
    final dialogHeight = media.size.height < 760
        ? media.size.height - 32
        : 680.0;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _salesTabActiveBg,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.person_search_rounded,
                      color: _salesTotalColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cliente de la venta',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: _salesTextPrimary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Busca y asigna un cliente. Si no existe, créalo con el botón + sin salir del flujo.',
                          style: TextStyle(
                            fontSize: 13,
                            color: _salesTextSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: _salesSurface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: _salesDivider),
                    boxShadow: _salesSoftShadow,
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Clientes guardados',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: _salesTextPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Vista limpia para ventas rápidas: buscador, lista y alta en un paso.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _salesTextSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextField(
                                    controller: _searchController,
                                    onChanged: (value) => ref
                                        .read(customersViewModelProvider)
                                        .search(value),
                                    decoration: InputDecoration(
                                      hintText:
                                          'Buscar por nombre, teléfono o correo',
                                      prefixIcon: const Icon(Icons.search),
                                      filled: true,
                                      fillColor: _salesSurface,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          _salesRadiusField,
                                        ),
                                        borderSide: const BorderSide(
                                          color: _salesDivider,
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          _salesRadiusField,
                                        ),
                                        borderSide: const BorderSide(
                                          color: _salesDivider,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          _salesRadiusField,
                                        ),
                                        borderSide: const BorderSide(
                                          color: _salesTotalColor,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            Tooltip(
                              message: 'Crear cliente',
                              child: SizedBox(
                                width: 54,
                                height: 54,
                                child: FilledButton(
                                  onPressed: _openCreateCustomerFlow,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _salesTotalColor,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: const Icon(
                                    Icons.add_rounded,
                                    size: 28,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: _salesDivider),
                      Expanded(
                        child: vm.isLoading
                            ? const Center(
                                child: CircularProgressIndicator(
                                  color: _salesTotalColor,
                                ),
                              )
                            : vm.customers.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        width: 72,
                                        height: 72,
                                        decoration: BoxDecoration(
                                          color: _salesTabActiveBg,
                                          borderRadius: BorderRadius.circular(
                                            22,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.people_alt_outlined,
                                          color: _salesTotalColor,
                                          size: 34,
                                        ),
                                      ),
                                      const SizedBox(height: 14),
                                      const Text(
                                        'No se encontraron clientes',
                                        style: TextStyle(
                                          color: _salesTextPrimary,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Prueba con otra búsqueda o crea uno nuevo con el botón +.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: _salesTextSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : Scrollbar(
                                controller: _customersScrollController,
                                child: ListView.separated(
                                  controller: _customersScrollController,
                                  padding: const EdgeInsets.all(14),
                                  itemCount: vm.customers.length,
                                  separatorBuilder: (context, index) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (context, index) {
                                    final customer = vm.customers[index];
                                    final name =
                                        customer['name']?.toString() ??
                                        'Cliente';
                                    final phone = customer['phone']?.toString();
                                    final email = customer['email']?.toString();
                                    final address = customer['address']
                                        ?.toString();
                                    final subtitleParts =
                                        [phone, email, address]
                                            .where(
                                              (value) =>
                                                  value != null &&
                                                  value.trim().isNotEmpty,
                                            )
                                            .cast<String>()
                                            .toList();

                                    return InkWell(
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: () =>
                                          Navigator.of(context).pop(customer),
                                      child: Container(
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFFFBF6),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          border: Border.all(
                                            color: _salesDivider,
                                          ),
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            CircleAvatar(
                                              radius: 22,
                                              backgroundColor:
                                                  _salesTabActiveBg,
                                              child: Text(
                                                name.isNotEmpty
                                                    ? name[0].toUpperCase()
                                                    : 'C',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  color: _salesTextPrimary,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    name,
                                                    style: const TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: _salesTextPrimary,
                                                    ),
                                                  ),
                                                  if (subtitleParts
                                                      .isNotEmpty) ...[
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      subtitleParts.join(' • '),
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color:
                                                            _salesTextSecondary,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: _salesTabActiveBg,
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: const Text(
                                                'Seleccionar',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: _salesTextPrimary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateCustomerDialog extends ConsumerStatefulWidget {
  const _CreateCustomerDialog();

  @override
  ConsumerState<_CreateCustomerDialog> createState() =>
      _CreateCustomerDialogState();
}

class _CreateCustomerDialogState extends ConsumerState<_CreateCustomerDialog> {
  final TextEditingController _firstNameController = TextEditingController();
  final TextEditingController _lastNameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _companyController = TextEditingController();
  final TextEditingController _creditLimitController = TextEditingController();
  final TextEditingController _maxCreditController = TextEditingController();
  final TextEditingController _taxIdController = TextEditingController();
  final ScrollController _formScrollController = ScrollController();

  bool _isSaving = false;
  bool _isAdvancedMode = false;
  String _customerType = 'General';
  String _documentType = 'Cédula';
  DateTime? _birthDate;

  @override
  void dispose() {
    _formScrollController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _companyController.dispose();
    _creditLimitController.dispose();
    _maxCreditController.dispose();
    _taxIdController.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(1995),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );

    if (picked != null) {
      setState(() => _birthDate = picked);
    }
  }

  Widget _buildCreateField({
    required String label,
    required String hint,
    required TextEditingController controller,
    TextInputType? keyboardType,
    int maxLines = 1,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _salesTextPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: _salesTextHint, fontSize: 13),
            filled: true,
            fillColor: _salesSurface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesDivider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesTotalColor),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _salesTextPrimary,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: value,
          items: items
              .map(
                (item) =>
                    DropdownMenuItem<String>(value: item, child: Text(item)),
              )
              .toList(),
          onChanged: onChanged,
          decoration: InputDecoration(
            filled: true,
            fillColor: _salesSurface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesDivider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_salesRadiusField),
              borderSide: const BorderSide(color: _salesTotalColor),
            ),
          ),
        ),
      ],
    );
  }

  Map<String, dynamic> _buildPayload() {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final fullName = [
      firstName,
      lastName,
    ].where((value) => value.isNotEmpty).join(' ').trim();

    final advancedNotes = <String, dynamic>{
      'first_name': firstName,
      'last_name': lastName,
      'customer_type': _customerType,
      'document_type': _documentType,
      'business_name': _companyController.text.trim(),
      'birth_date': _birthDate == null
          ? null
          : DateFormat('yyyy-MM-dd').format(_birthDate!),
      'credit_limit': _creditLimitController.text.trim(),
      'max_credit': _maxCreditController.text.trim(),
      'mode': _isAdvancedMode ? 'advanced' : 'normal',
    };

    advancedNotes.removeWhere(
      (key, value) => value == null || value.toString().trim().isEmpty,
    );

    return {
      'name': fullName,
      'phone': _phoneController.text.trim(),
      'email': _emailController.text.trim(),
      'address': _addressController.text.trim(),
      'tax_id': _taxIdController.text.trim(),
      'notes': advancedNotes.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .join(' | '),
    };
  }

  Future<void> _createCustomer() async {
    final payload = _buildPayload();
    if ((payload['name'] as String).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El nombre y apellido del cliente son obligatorios.'),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final created = await ref
          .read(customersViewModelProvider)
          .addCustomer(payload);
      if (!mounted || created == null) return;
      Navigator.of(context).pop(created);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo crear el cliente: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dialogWidth = media.size.width < 900 ? media.size.width - 32 : 820.0;
    final dialogHeight = media.size.height < 860
        ? media.size.height - 32
        : 760.0;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEDD5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.person_add_alt_1_rounded,
                      color: _salesTotalColor,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nuevo cliente',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: _salesTextPrimary,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Crea el cliente sin salir de ventas. Puedes usar modo normal o avanzado.',
                          style: TextStyle(
                            fontSize: 13,
                            color: _salesTextSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _salesTabActiveBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _salesDivider),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: _isSaving
                            ? null
                            : () => setState(() => _isAdvancedMode = false),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: !_isAdvancedMode
                                ? _salesSurface
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Normal',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: !_isAdvancedMode
                                  ? _salesTextPrimary
                                  : _salesTextSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: InkWell(
                        onTap: _isSaving
                            ? null
                            : () => setState(() => _isAdvancedMode = true),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: _isAdvancedMode
                                ? _salesSurface
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Avanzado',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: _isAdvancedMode
                                  ? _salesTextPrimary
                                  : _salesTextSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBF6),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _salesDivider),
                  ),
                  child: Scrollbar(
                    controller: _formScrollController,
                    child: SingleChildScrollView(
                      controller: _formScrollController,
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _buildCreateField(
                                  label: 'Nombre',
                                  hint: 'Ej. María',
                                  controller: _firstNameController,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _buildCreateField(
                                  label: 'Apellido',
                                  hint: 'Ej. Pérez',
                                  controller: _lastNameController,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          _buildCreateField(
                            label: 'Teléfono',
                            hint: '809...',
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 14),
                          _buildCreateField(
                            label: 'RNC / Cédula',
                            hint: 'Ej. 131234567',
                            controller: _taxIdController,
                            keyboardType: TextInputType.number,
                          ),
                          if (_isAdvancedMode) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildDropdownField(
                                    label: 'Tipo de cliente',
                                    value: _customerType,
                                    items: const [
                                      'General',
                                      'Frecuente',
                                      'Empresa',
                                      'Crédito',
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        setState(() => _customerType = value);
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _buildDropdownField(
                                    label: 'Tipo de documento',
                                    value: _documentType,
                                    items: const [
                                      'Cédula',
                                      'RNC',
                                      'Pasaporte',
                                      'Otro',
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        setState(() => _documentType = value);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _buildCreateField(
                              label: 'Razón social',
                              hint: 'Nombre comercial o empresa',
                              controller: _companyController,
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Fecha de nacimiento',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: _salesTextPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        onPressed: _pickBirthDate,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: _salesTextPrimary,
                                          backgroundColor: _salesSurface,
                                          side: const BorderSide(
                                            color: _salesDivider,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 16,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              _salesRadiusField,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(Icons.cake_outlined),
                                        label: Text(
                                          _birthDate == null
                                              ? 'Seleccionar fecha (opcional)'
                                              : DateFormat(
                                                  'dd/MM/yyyy',
                                                ).format(_birthDate!),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _buildCreateField(
                                    label: 'Correo',
                                    hint: 'cliente@correo.com',
                                    controller: _emailController,
                                    keyboardType: TextInputType.emailAddress,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _buildCreateField(
                              label: 'Dirección',
                              hint: 'Dirección del cliente',
                              controller: _addressController,
                              maxLines: 2,
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: _buildCreateField(
                                    label: 'Límite de crédito',
                                    hint: '0.00',
                                    controller: _creditLimitController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _buildCreateField(
                                    label: 'Máximo de crédito',
                                    hint: '0.00',
                                    controller: _maxCreditController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ] else ...[
                            const SizedBox(height: 14),
                            const Text(
                              'Modo normal: alta rápida con los datos mínimos para seguir la venta sin fricción.',
                              style: TextStyle(
                                fontSize: 12,
                                color: _salesTextSecondary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSaving
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _salesTextPrimary,
                        side: const BorderSide(color: _salesDivider),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            _salesRadiusButton,
                          ),
                        ),
                      ),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _createCustomer,
                      style: FilledButton.styleFrom(
                        backgroundColor: _salesTotalColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            _salesRadiusButton,
                          ),
                        ),
                      ),
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        _isSaving ? 'Guardando...' : 'Crear y asignar cliente',
                      ),
                    ),
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
                      border: Border.all(
                        color: _parseHexColor(cat.color),
                        width: cat.color != null ? 2.5 : 1,
                      ),
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

class _ComboSelectionDialog extends StatefulWidget {
  final MenuProduct product;
  final List<Map<String, dynamic>> groups;

  const _ComboSelectionDialog({required this.product, required this.groups});

  @override
  State<_ComboSelectionDialog> createState() => _ComboSelectionDialogState();
}

class _ComboSelectionDialogState extends State<_ComboSelectionDialog> {
  final Map<String, String> _selectedByGroup = <String, String>{};

  @override
  void initState() {
    super.initState();
    for (final group in widget.groups) {
      final items = ((group['combo_group_items'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      final defaultItem = items.cast<Map<String, dynamic>?>().firstWhere(
        (item) => item?['is_default'] == true,
        orElse: () => items.isEmpty ? null : items.first,
      );
      if (defaultItem != null) {
        final menuItemId = defaultItem['menu_item_id']?.toString();
        if (menuItemId != null && menuItemId.isNotEmpty) {
          _selectedByGroup[group['id']?.toString() ?? ''] = menuItemId;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Armar combo · ${widget.product.name}'),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.groups
                .map((group) {
                  final groupId = group['id']?.toString() ?? '';
                  final items =
                      ((group['combo_group_items'] as List?) ?? const [])
                          .map((e) => Map<String, dynamic>.from(e as Map))
                          .toList(growable: false)
                        ..sort(
                          (a, b) => ((a['sort_order'] as num?)?.toInt() ?? 0)
                              .compareTo(
                                (b['sort_order'] as num?)?.toInt() ?? 0,
                              ),
                        );
                  return Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group['name']?.toString() ?? 'Grupo',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        ...items.map((item) {
                          final product = Map<String, dynamic>.from(
                            (item['menu_items'] as Map?) ?? const {},
                          );
                          final menuItemId =
                              item['menu_item_id']?.toString() ?? '';
                          final priceDelta =
                              (item['price_delta'] as num?)?.toDouble() ?? 0.0;
                          return RadioListTile<String>(
                            value: menuItemId,
                            groupValue: _selectedByGroup[groupId],
                            title: Text(
                              product['name']?.toString() ?? 'Opción',
                            ),
                            subtitle: priceDelta > 0
                                ? Text(
                                    'Extra RD\$ ${priceDelta.toStringAsFixed(2)}',
                                  )
                                : null,
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => _selectedByGroup[groupId] = value);
                            },
                          );
                        }),
                      ],
                    ),
                  );
                })
                .toList(growable: false),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final result = <SelectedModifierInput>[];
            for (final group in widget.groups) {
              final groupId = group['id']?.toString() ?? '';
              final selectedId = _selectedByGroup[groupId];
              if (selectedId == null || selectedId.isEmpty) continue;
              final items = ((group['combo_group_items'] as List?) ?? const [])
                  .map((e) => Map<String, dynamic>.from(e as Map));
              Map<String, dynamic>? selected;
              for (final item in items) {
                if (item['menu_item_id']?.toString() == selectedId) {
                  selected = item;
                  break;
                }
              }
              if (selected == null) continue;
              final product = Map<String, dynamic>.from(
                (selected['menu_items'] as Map?) ?? const {},
              );
              final groupName = group['name']?.toString() ?? 'Grupo';
              result.add(
                SelectedModifierInput(
                  name: '$groupName: ${product['name'] ?? 'Opción'}',
                  qty: 1,
                  price: (selected['price_delta'] as num?)?.toDouble() ?? 0.0,
                ),
              );
            }
            Navigator.of(context).pop(result);
          },
          child: const Text('Agregar combo'),
        ),
      ],
    );
  }
}

class _ModifiersSelectionDialog extends StatefulWidget {
  final MenuProduct product;
  final List<Map<String, dynamic>> groups;

  const _ModifiersSelectionDialog({
    required this.product,
    required this.groups,
  });

  @override
  State<_ModifiersSelectionDialog> createState() =>
      _ModifiersSelectionDialogState();
}

class _ModifiersSelectionDialogState extends State<_ModifiersSelectionDialog> {
  final Map<String, Set<String>> _selectedByGroup = <String, Set<String>>{};

  @override
  void initState() {
    super.initState();
    for (final row in widget.groups) {
      final group = Map<String, dynamic>.from(row['modifier_groups'] as Map);
      final groupId = group['id']?.toString() ?? '';
      final modifiers = ((group['modifiers'] as List?) ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((item) => item['is_active'] != false)
          .toList(growable: false);
      final defaults = modifiers
          .where((item) => item['default_selected'] == true)
          .map((item) => item['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      _selectedByGroup[groupId] = defaults;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'es_DO',
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    return Dialog(
      backgroundColor: _salesSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SalesModifierDialogHeader(
                title: widget.product.name,
                subtitle:
                    'Personaliza el producto antes de agregarlo a la orden.',
              ),
              const SizedBox(height: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...widget.groups.map((row) {
                        final group = Map<String, dynamic>.from(
                          row['modifier_groups'] as Map,
                        );
                        final groupId = group['id']?.toString() ?? '';
                        final groupName = group['name']?.toString() ?? 'Grupo';
                        final displayType =
                            group['display_type']?.toString() ?? 'multiple';
                        final minSelect =
                            (group['min_select'] as num?)?.toInt() ?? 0;
                        final maxSelect =
                            (group['max_select'] as num?)?.toInt() ?? 0;
                        final selected =
                            _selectedByGroup[groupId] ?? <String>{};
                        final modifiers =
                            ((group['modifiers'] as List?) ?? const [])
                                .map(
                                  (item) =>
                                      Map<String, dynamic>.from(item as Map),
                                )
                                .where((item) => item['is_active'] != false)
                                .toList(growable: false)
                              ..sort(
                                (a, b) =>
                                    ((a['sort_order'] as num?)?.toInt() ?? 0)
                                        .compareTo(
                                          (b['sort_order'] as num?)?.toInt() ??
                                              0,
                                        ),
                              );

                        return Container(
                          margin: const EdgeInsets.only(bottom: 14),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _salesSurface,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: _salesDivider),
                            boxShadow: _salesSoftShadow,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      groupName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                        color: _salesTextPrimary,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF3F0ED),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      displayType == 'single'
                                          ? '1 opción'
                                          : 'Múltiple',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: _salesTextSecondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _groupHint(
                                  displayType: displayType,
                                  minSelect: minSelect,
                                  maxSelect: maxSelect,
                                ),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: _salesTextSecondary,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: modifiers
                                    .map((modifier) {
                                      final modifierId =
                                          modifier['id']?.toString() ?? '';
                                      final price =
                                          (modifier['price_delta'] as num?)
                                              ?.toDouble() ??
                                          0.0;
                                      final isSelected = selected.contains(
                                        modifierId,
                                      );
                                      return FilterChip(
                                        selected: isSelected,
                                        showCheckmark: false,
                                        selectedColor: const Color(0xFFFFEDD5),
                                        backgroundColor: const Color(
                                          0xFFF8FAFC,
                                        ),
                                        side: BorderSide(
                                          color: isSelected
                                              ? _salesTotalColor
                                              : _salesDivider,
                                          width: isSelected ? 1.5 : 1,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 10,
                                        ),
                                        labelStyle: TextStyle(
                                          color: isSelected
                                              ? const Color(0xFF9A3412)
                                              : _salesTextPrimary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        avatar: Icon(
                                          isSelected
                                              ? Icons.check_circle_rounded
                                              : Icons
                                                    .add_circle_outline_rounded,
                                          size: 18,
                                          color: isSelected
                                              ? _salesTotalColor
                                              : _salesTextHint,
                                        ),
                                        label: Text(
                                          price > 0
                                              ? '${modifier['name']} (+${currency.format(price)})'
                                              : '${modifier['name']}',
                                        ),
                                        onSelected: (_) => _toggleModifier(
                                          groupId: groupId,
                                          modifierId: modifierId,
                                          displayType: displayType,
                                          maxSelect: maxSelect,
                                        ),
                                      );
                                    })
                                    .toList(growable: false),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(
                      Icons.add_shopping_cart_outlined,
                      size: 18,
                    ),
                    label: const Text('Agregar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _groupHint({
    required String displayType,
    required int minSelect,
    required int maxSelect,
  }) {
    if (displayType == 'single') {
      return minSelect > 0 ? 'Selecciona 1 opción' : 'Selecciona una opción';
    }
    if (maxSelect > 0) {
      return minSelect > 0
          ? 'Selecciona entre $minSelect y $maxSelect opciones'
          : 'Máximo $maxSelect opciones';
    }
    return minSelect > 0
        ? 'Selecciona al menos $minSelect opciones'
        : 'Opcional';
  }

  void _toggleModifier({
    required String groupId,
    required String modifierId,
    required String displayType,
    required int maxSelect,
  }) {
    setState(() {
      final selected = _selectedByGroup.putIfAbsent(groupId, () => <String>{});
      if (displayType == 'single') {
        if (selected.contains(modifierId)) {
          selected.clear();
        } else {
          selected
            ..clear()
            ..add(modifierId);
        }
        return;
      }

      if (selected.contains(modifierId)) {
        selected.remove(modifierId);
        return;
      }

      if (maxSelect > 0 && selected.length >= maxSelect) {
        return;
      }
      selected.add(modifierId);
    });
  }

  void _submit() {
    final result = <SelectedModifierInput>[];

    for (final row in widget.groups) {
      final group = Map<String, dynamic>.from(row['modifier_groups'] as Map);
      final groupId = group['id']?.toString() ?? '';
      final minSelect = (group['min_select'] as num?)?.toInt() ?? 0;
      final selected = _selectedByGroup[groupId] ?? <String>{};
      if (selected.length < minSelect) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Debes completar: ${group['name']}')),
        );
        return;
      }
      final modifiers = ((group['modifiers'] as List?) ?? const [])
          .map((item) => Map<String, dynamic>.from(item as Map))
          .where((item) => selected.contains(item['id']?.toString() ?? ''));
      for (final modifier in modifiers) {
        result.add(
          SelectedModifierInput(
            name: modifier['name']?.toString() ?? 'Modificador',
            qty: 1,
            price: (modifier['price_delta'] as num?)?.toDouble() ?? 0.0,
          ),
        );
      }
    }

    Navigator.of(context).pop(result);
  }
}

enum _DiscountScope { table, products }

class _SalesModifierDialogHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SalesModifierDialogHeader({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: _salesTotalColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.tune_rounded, color: _salesTotalColor),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: _salesTextPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 13,
                  color: _salesTextSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

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
