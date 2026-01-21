import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';
import 'package:mangopos/presentation/payments/widgets/payment_modal.dart';
import 'package:mangopos/presentation/split_bill/widgets/split_bill_modal.dart';

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
      backgroundColor: SalesTheme.background,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. RAIL DE HERRAMIENTAS (Izquierda extrema - ~80px)
            _ToolsRail(
              onBack: () => _handleBack(context),
              onAction: (action) => _handleToolAction(context, action),
            ),

            // 2. COLUMNA DE ORDEN / CARRITO (380px)
            Container(
              width: 380,
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(right: BorderSide(color: SalesTheme.border)),
              ),
              child: _CartView(tableCode: widget.tableCode),
            ),

            // 3. AREA PRINCIPAL (CATALOGO)
            Expanded(
              child: _CatalogArea(
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleToolAction(BuildContext context, String action) {
    if (action == 'split') {
      final order = ref.read(currentOrderProvider).order;
      if (order == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay una orden activa')),
        );
        return;
      }
      showDialog(
        context: context,
        builder: (context) => SplitBillModal(
          order: order,
          onSplitApplied: () {
            ref.read(currentOrderProvider.notifier).refreshOrder();
          },
        ),
      );
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Accion: $action')));
  }
}

// -----------------------------------------------------------------------------
// 1. RAIL DE HERRAMIENTAS
// -----------------------------------------------------------------------------
class _ToolsRail extends StatelessWidget {
  final VoidCallback onBack;
  final Function(String) onAction;

  const _ToolsRail({required this.onBack, required this.onAction});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      color: Colors.white, // O SalesTheme.cardBackground
      child: Column(
        children: [
          // Boton Regresar destacado
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: _ToolButton(
              icon: Icons.arrow_back_ios_new_rounded,
              label: 'Regresar',
              isBack: true,
              onTap: onBack,
            ),
          ),
          const Divider(height: 1, color: SalesTheme.border),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  // Opciones de pago (en el diseno es un header pequeno)
                  Text(
                    'OPCIONES',
                    style: TextStyle(
                      fontSize: 10,
                      color: SalesTheme.mutedForeground,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),

                  _ToolButton(
                    icon: Icons.edit_note_rounded,
                    label: 'Editar\nmesa',
                    onTap: () => onAction('edit_table'),
                  ),
                  _ToolButton(
                    icon: Icons.logout_rounded,
                    label: 'Liberar\nmesa',
                    onTap: () => onAction('release_table'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Divider(height: 1),
                  ),
                  _ToolButton(
                    icon: Icons.call_split_rounded,
                    label: 'Dividir\ncuentas',
                    onTap: () => onAction('split'),
                  ),
                  _ToolButton(
                    icon: Icons.merge_type_rounded,
                    label: 'Unir\nmesas',
                    onTap: () => onAction('merge'),
                  ),
                  _ToolButton(
                    icon: Icons.move_up_rounded,
                    label: 'Mover\npedidos',
                    onTap: () => onAction('move'),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Divider(height: 1),
                  ),
                  _ToolButton(
                    icon: Icons.percent_rounded,
                    label: 'Desc.',
                    onTap: () => onAction('discount'),
                  ),
                  _ToolButton(
                    icon: Icons.receipt_long_rounded,
                    label: 'Vale\npago',
                    onTap: () => onAction('voucher'),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // Botones inferiores fijos
          _ToolButton(
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

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isBack;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isBack = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isBack ? SalesTheme.primary : SalesTheme.foreground;
    final bg = isBack
        ? SalesTheme.primary.withOpacity(0.1)
        : Colors.transparent;

    return InkWell(
      onTap: onTap,
      child: Container(
        width: 70,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: isBack ? FontWeight.w700 : FontWeight.w500,
                height: 1.1,
              ),
            ),
          ],
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
    final orderTotal = orderState.order?.total ?? 0.0;
    final itemsTotal = allItems.fold<double>(
      0.0,
      (sum, item) => sum + item.total,
    );
    final total = orderTotal > 0 ? orderTotal : itemsTotal;

    // Filter items
    final sentItems = allItems.where((i) => i.status != 'draft').toList();
    final draftItems = allItems.where((i) => i.status == 'draft').toList();

    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (orderState.error != null) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    orderState.error!,
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.table_restaurant_rounded,
                    color: SalesTheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Mesa $tableCode',
                    style: SalesTheme.textTheme.titleLarge?.copyWith(
                      fontSize: 16,
                      color: SalesTheme.primary,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Activa',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.person_outline,
                    size: 14,
                    color: SalesTheme.mutedForeground,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Mozo: Jhon Peralta',
                    style: SalesTheme.textTheme.bodySmall,
                  ), // Placeholder logic
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  const Icon(
                    Icons.groups_outlined,
                    size: 14,
                    color: SalesTheme.mutedForeground,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Cant. Personas: 1',
                    style: SalesTheme.textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Select Client
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: SalesTheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.person_add_alt_1_rounded,
                size: 18,
                color: SalesTheme.primary,
              ),
              const SizedBox(width: 8),
              const Text(
                'Selecciona un cliente',
                style: TextStyle(
                  color: SalesTheme.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Column Headers
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: SalesTheme.background,
          child: Row(
            children: const [
              SizedBox(
                width: 40,
                child: Text(
                  'Cant.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: SalesTheme.mutedForeground,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  'Producto',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: SalesTheme.mutedForeground,
                  ),
                ),
              ),
              Text(
                'Precio',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: SalesTheme.mutedForeground,
                ),
              ),
            ],
          ),
        ),

        // List
        Expanded(
          child: allItems.isEmpty
              ? const Center(
                  child: Text(
                    'Sin productos',
                    style: TextStyle(color: Colors.black26),
                  ),
                )
              : ListView(
                  children: [
                    // Sent Items (Fixed)
                    if (sentItems.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          'ENVIADOS A COCINA',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                      ),
                      ...sentItems.map(
                        (item) =>
                            _CartItemSimpleRow(item: item, isDraft: false),
                      ),
                      const Divider(),
                    ],

                    // Draft Items (Editable)
                    if (draftItems.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          'POR CONFIRMAR (Nuevos)',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                      ),
                      ...draftItems.map(
                        (item) => _CartItemSimpleRow(item: item, isDraft: true),
                      ),
                    ],
                  ],
                ),
        ),

        // Total Bottom
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: SalesTheme.border)),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Total',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'RD\$ ${total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: SalesTheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Action Buttons
              Row(
                children: [
                  // Cancel / Void (Only logic for now)
                  // If we have drafts, we can just clear drafts

                  // Send to Kitchen (Only if drafts exist)
                  if (draftItems.isNotEmpty)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          ref
                              .read(currentOrderProvider.notifier)
                              .confirmOrder();
                        },
                        icon: const Icon(Icons.soup_kitchen, size: 18),
                        label: const Text('ENVIAR COCINA'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    )
                  else
                    // Charge Button (If nothing new to add)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: orderState.order == null
                            ? null
                            : () => _openPaymentModal(
                                context,
                                ref,
                                orderState.order!,
                              ),
                        icon: const Icon(Icons.payments_outlined, size: 18),
                        label: const Text('COBRAR'),
                        style: FilledButton.styleFrom(
                          backgroundColor: SalesTheme.success,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CartItemSimpleRow extends ConsumerWidget {
  final dynamic item;
  final bool isDraft;
  const _CartItemSimpleRow({required this.item, required this.isDraft});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = item.productName ?? '';
    final qty = (item.quantity ?? 1).toString();
    final total = (item.total ?? 0.0).toStringAsFixed(2);

    return InkWell(
      onLongPress: !isDraft
          ? () {
              showDialog(
                context: context,
                builder: (c) => Dialog(
                  backgroundColor: SalesTheme.cardBackground,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.orange,
                          size: 48,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Anular producto?',
                          style: SalesTheme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Se eliminara "$name" de la orden de cocina.\nEsta accion puede requerir autorizacion.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(c),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                ),
                                child: const Text('Cancelar'),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: FilledButton(
                                onPressed: () {
                                  Navigator.pop(c);
                                  ref
                                      .read(currentOrderProvider.notifier)
                                      .deleteItem(item.id);
                                },
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                ),
                                child: const Text('ANULAR'),
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
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Delete X for drafts
            if (isDraft)
              GestureDetector(
                onTap: () {
                  ref.read(currentOrderProvider.notifier).deleteItem(item.id);
                },
                child: const Padding(
                  padding: EdgeInsets.only(right: 8.0),
                  child: Icon(Icons.close, color: Colors.red, size: 18),
                ),
              ),

            SizedBox(
              width: 30,
              child: Text(
                qty,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  if (!isDraft)
                    const Padding(
                      padding: EdgeInsets.only(right: 6.0),
                      child: Icon(
                        Icons.check_circle,
                        size: 14,
                        color: Colors.green,
                      ),
                    ),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'P',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: isDraft ? Colors.black : Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              'RD\$ $total',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: SalesTheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 3. CATALOG AREA
// -----------------------------------------------------------------------------
class _CatalogArea extends ConsumerStatefulWidget {
  final Function(dynamic) onProductTap;
  const _CatalogArea({required this.onProductTap});

  @override
  ConsumerState<_CatalogArea> createState() => _CatalogAreaState();
}

class _CatalogAreaState extends ConsumerState<_CatalogArea>
    with TickerProviderStateMixin {
  late TabController _mainTabController;

  @override
  void initState() {
    super.initState();
    // 4 Tabs: Categoria, Menu, Busqueda, Favoritos
    _mainTabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _mainTabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Tabs Superiores (Estilo clean)
        Container(
          color: Colors.white,
          child: TabBar(
            controller: _mainTabController,
            isScrollable: false,
            labelColor: SalesTheme.primary,
            unselectedLabelColor: SalesTheme.mutedForeground,
            indicatorColor: SalesTheme.primary,
            indicatorWeight: 3,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
            tabs: const [
              Tab(text: 'Categoria'),
              Tab(text: 'Menu'),
              Tab(text: 'Busqueda'),
              Tab(text: 'Favoritos'),
            ],
          ),
        ),

        // Contenido
        Expanded(
          child: Container(
            color: const Color(0xFFF3F6F9), // Light grey bg like image
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
                // 3. Busqueda
                const Center(child: Text('Busqueda')),
                // 4. Favoritos
                const Center(child: Text('Favoritos')),
              ],
            ),
          ),
        ),
      ],
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

    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 1.4,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final cat = categories[index];
        // Diseno Card Blanca Bordeada
        return InkWell(
          onTap: () => onCategoryTap(cat.id),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black.withOpacity(0.08)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  cat.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: SalesTheme.foreground,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Text(
                    '${(index * 2) + 4} prod.', // Mock count
                    style: const TextStyle(
                      fontSize: 11,
                      color: SalesTheme.mutedForeground,
                    ),
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

class _ProductsGrid extends ConsumerWidget {
  final Function(dynamic) onProductTap;
  const _ProductsGrid({required this.onProductTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final products = state.products;

    if (state.loading) {
      return const Center(
        child: CircularProgressIndicator(color: SalesTheme.primary),
      );
    }
    if (products.isEmpty) {
      return const Center(
        child: Text('Selecciona una categoria o busca productos'),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 0.9,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: products.length,
      itemBuilder: (context, index) {
        final product = products[index];
        return GestureDetector(
          onTap: () => onProductTap(product),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: SalesTheme.primary.withOpacity(0.3),
              ), // Borde active style
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Image placeholder logic
                Expanded(
                  child: Container(
                    decoration: const BoxDecoration(
                      color: SalesTheme.secondary,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(11),
                      ),
                    ),
                    child: product.imageUrl != null
                        ? Image.network(product.imageUrl!, fit: BoxFit.cover)
                        : const Center(
                            child: Icon(
                              Icons.fastfood,
                              color: Colors.black12,
                              size: 40,
                            ),
                          ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'RD\$ ${product.price.toStringAsFixed(0)}',
                        style: const TextStyle(
                          color: SalesTheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
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
