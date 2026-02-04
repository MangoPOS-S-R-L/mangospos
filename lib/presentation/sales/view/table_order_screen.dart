import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/payments/widgets/payment_modal.dart';

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
const double _salesRadiusButton = 20; // botones pill
const double _salesRadiusField = 14;
const double _salesRadiusTab = 12;

const List<BoxShadow> _salesSoftShadow = [
  BoxShadow(
    color: Color(0x10000000),
    blurRadius: 6,
    offset: Offset(0, 2),
  ),
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
            final isWide = width >= 1200;
            final isMedium = width >= 900 && width < 1200;
            final isStacked = width < 900;

            final cartWidth = isWide
                ? 400.0
                : isMedium
                    ? 360.0
                    : 320.0;

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
                    .addItem(menuItemId: product.id);
              },
            );

            if (isStacked) {
              return Column(
                children: [
                  // Mobile: cart primero, luego catálogo
                  Expanded(child: cart),
                  Container(height: 1, color: _salesDivider),
                  Expanded(child: catalog),
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SalesToolsRail(
                  onBack: () => _handleBack(context),
                  onAction: (action) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Accion: $action')),
                    );
                  },
                ),
                SizedBox(
                  width: cartWidth,
                  child: cart,
                ),
                Container(width: 1, color: _salesDivider),
                Expanded(child: catalog),
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
  const _CartView({required this.tableCode});

  void _openPaymentModal(BuildContext context, WidgetRef ref, Order order) {
    final parentContext = context;
    showDialog(
      context: parentContext,
      builder: (context) => PaymentModal(
        order: order,
        onPaymentSuccess: () {
          ref
              .read(currentOrderProvider.notifier)
              .refreshOrder(clearIfPaid: true);
          if (parentContext.mounted) {
            parentContext.go(AppRoutes.salesByZone);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderState = ref.watch(currentOrderProvider);
    final allItems = orderState.items;
    final itemsCount = allItems.length;
    final orderTotal = orderState.order?.total ?? 0.0;
    final orderSubtotal = orderState.order?.subtotal ?? 0.0;
    final orderTax = orderState.order?.tax ?? 0.0;
    final itemsTotal = allItems.fold<double>(
      0.0,
      (sum, item) => sum + item.total,
    );
    final total = orderTotal > 0 ? orderTotal : itemsTotal;
    final subtotal = orderSubtotal > 0 ? orderSubtotal : itemsTotal;
    final tax = orderTotal > 0 ? orderTax : 0.0;
    final currency = NumberFormat('#,##0.00', 'en_US');
    final sentItems = allItems.where((i) => i.status != 'draft').toList();
    final draftItems = allItems.where((i) => i.status == 'draft').toList();
    final hasItems = allItems.isNotEmpty;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Mesa $tableCode',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: _salesTextPrimary,
                ),
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
        Container(height: 1, color: _salesDivider),
        Expanded(
          child: allItems.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text(
                        'No hay productos en el carrito',
                        style: TextStyle(
                          fontSize: 14,
                          color: _salesTextSecondary,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Selecciona productos del menú',
                        style: TextStyle(
                          fontSize: 13,
                          color: _salesTextHint,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
      if (sentItems.isNotEmpty) ...[
        const _SectionLabel(
          label: 'ENVIADOS A COCINA',
          color: Color(0xFF22C55E),
        ),
                      const SizedBox(height: 8),
                      ...sentItems.map(
                        (item) => _CartLineItem(
                          item: item,
                          isDraft: false,
                          onDelete: null,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (draftItems.isNotEmpty) ...[
                      const _SectionLabel(
                        label: 'POR CONFIRMAR',
                        color: Color(0xFFF59E0B),
                      ),
                      const SizedBox(height: 8),
                      ...draftItems.map(
                        (item) => _CartLineItem(
                          item: item,
                          isDraft: true,
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
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              _SummaryRow(
                label: 'Subtotal',
                value: 'RD\$ ${currency.format(subtotal)}',
              ),
              const SizedBox(height: 8),
              _SummaryRow(
                label: 'ITBIS',
                value: 'RD\$ ${currency.format(tax)}',
              ),
              const SizedBox(height: 12),
              _SummaryRow(
                label: 'Total',
                value: 'RD\$ ${currency.format(total)}',
                valueColor: _salesTotalColor,
                valueWeight: FontWeight.w700,
              ),
              if (hasItems) ...[
                const SizedBox(height: 16),
                if (draftItems.isNotEmpty) ...[
                  _ActionButton(
                    label: 'Enviar a Cocina',
                    background: _salesKitchenButton,
                    onPressed: () => ref
                        .read(currentOrderProvider.notifier)
                        .confirmOrder(),
                    icon: Icons.soup_kitchen_outlined,
                  ),
                  const SizedBox(height: 12),
                  _ActionButton(
                    label: 'Pagar RD\$ ${currency.format(total)}',
                    background: _salesPayButton,
                    onPressed: orderState.order == null || total <= 0
                        ? null
                        : () => _openPaymentModal(
                            context,
                            ref,
                            orderState.order!,
                          ),
                    icon: Icons.payments_outlined,
                  ),
                ] else if (sentItems.isNotEmpty) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _SecondaryActionButton(
                          label: 'Pre-Cuenta',
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Precuenta')),
                            );
                          },
                          icon: Icons.receipt_long_outlined,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _SecondaryActionButton(
                          label: 'Dividir',
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Dividir cuenta')),
                            );
                          },
                          icon: Icons.call_split_rounded,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ActionButton(
                    label: 'Pagar RD\$ ${currency.format(total)}',
                    background: _salesPayButton,
                    onPressed: orderState.order == null || total <= 0
                        ? null
                        : () => _openPaymentModal(
                            context,
                            ref,
                            orderState.order!,
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
          _RailButton(
            icon: Icons.print_rounded,
            label: 'Imprimir',
            onTap: () => onAction('print'),
          ),
          const SizedBox(height: 16),
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
    final bg = isPrimary ? _salesTotalColor.withOpacity(0.12) : _salesSurface;

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

  const _CartLineItem({
    required this.item,
    required this.isDraft,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final name = item.productName ?? '';
    final qty = (item.quantity ?? 1).toStringAsFixed(1);
    final totalItem = (item.total ?? 0.0).toStringAsFixed(2);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          if (isDraft && onDelete != null)
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.close, color: Color(0xFFEF4444), size: 18),
              splashRadius: 16,
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
              child: Icon(Icons.check_circle, size: 16, color: Color(0xFF22C55E)),
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
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          disabledBackgroundColor: background.withOpacity(0.35),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_salesRadiusButton),
          ),
        ).copyWith(
          overlayColor: MaterialStateProperty.all(
            Colors.white.withOpacity(0.08),
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
        : _formatElapsed(DateTime.now().difference(orderState.order!.createdAt));

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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
                        borderRadius:
                            BorderRadius.circular(_salesRadiusTab - 2),
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
                constraints: const BoxConstraints(minHeight: 140, minWidth: 160),
                decoration: BoxDecoration(
                  color: _salesSurface,
                  borderRadius: BorderRadius.circular(_salesRadiusCard),
                  border: Border.all(color: _salesDivider),
                  boxShadow: _salesSoftShadow,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
            constraints:
                const BoxConstraints(minHeight: 140, minWidth: 160, maxWidth: 220),
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
            ? DecorationImage(
                image: NetworkImage(imageUrl!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: imageUrl == null
          ? const Icon(Icons.fastfood, color: _salesTextHint, size: 32)
          : null,
    );
  }
}
