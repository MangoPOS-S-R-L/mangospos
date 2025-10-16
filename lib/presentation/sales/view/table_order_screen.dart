import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';

class TableOrderScreen extends ConsumerStatefulWidget {
  final String tableId;
  final String tableCode; // para mostrar M02, P10, etc.

  const TableOrderScreen({
    super.key,
    required this.tableId,
    required this.tableCode,
  });

  @override
  ConsumerState<TableOrderScreen> createState() => _TableOrderScreenState();
}

class _TableOrderScreenState extends ConsumerState<TableOrderScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 4,
      vsync: this,
    ); // Categoría | Menú | Búsqueda | Favoritos
    // Carga menú
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(menuBrowserVmProvider.notifier).loadAll();
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(currentOrderProvider);
    final menu = ref.watch(menuBrowserVmProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Regresar',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Mesa ${widget.tableCode}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          // “Actualizar menú”
          IconButton(
            tooltip: 'Actualizar menú',
            onPressed: () => ref
                .read(menuBrowserVmProvider.notifier)
                .loadAll(preselectCategoryId: menu.selectedCategoryId),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          // ------------------- PANEL IZQUIERDO (mesa / items / pagar)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(
                  right: BorderSide(
                    color: Colors.black.withOpacity(.06),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                children: [
                  // Encabezado mesa
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mesa ${widget.tableCode}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: const [
                            Icon(
                              Icons.person,
                              size: 16,
                              color: MangoColors.muted,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Cant. Personas: 1',
                              style: TextStyle(color: MangoColors.muted),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // Lista de items
                  Expanded(
                    child: order.loading
                        ? const Center(child: CircularProgressIndicator())
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: order.items.length,
                            separatorBuilder: (_, __) => const Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                            ),
                            itemBuilder: (_, i) {
                              final it = order.items[i];
                              // Datos mínimos para el modal
                              final double qty = (it.qty is num)
                                  ? (it.qty as num).toDouble()
                                  : 1.0;
                              final double total = (it.total is num)
                                  ? (it.total as num).toDouble()
                                  : 0.0;
                              final double unitPrice = qty > 0
                                  ? (total / qty)
                                  : total;
                              final String name = it.productName ?? 'Producto';
                              final bool isTakeout = it.isTakeout == true;

                              return ListTile(
                                dense: true,
                                onTap: () {
                                  // 👉 El popup se abre al tocar el item ya agregado (solo UI)
                                  showOrderItemDetailDialog(
                                    context,
                                    name: name,
                                    qty: qty,
                                    unitPrice: unitPrice,
                                    isTakeout: isTakeout,
                                  );
                                },
                                title: Text(
                                  name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  'Cant: ${qty.toStringAsFixed(1)} • ${isTakeout ? "Para llevar" : "Aquí"}',
                                  style: const TextStyle(
                                    color: MangoColors.muted,
                                  ),
                                ),
                                trailing: Text(
                                  'RD\$ ${total.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  // Total + Pagar
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border(
                        top: BorderSide(
                          color: Colors.black.withOpacity(.06),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        if (order.order != null) ...[
                          Row(
                            children: [
                              const Text(
                                'Total:',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                'RD\$ ${order.order!.total.toStringAsFixed(2)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
                        Row(
                          children: [
                            const Text(
                              'Para llevar',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            const Spacer(),
                            Switch.adaptive(
                              value: order.takeout,
                              onChanged: (v) => ref
                                  .read(currentOrderProvider.notifier)
                                  .toggleTakeout(v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: MangoColors.primaryOrange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: order.order == null || order.loading
                                ? null
                                : () => ref
                                      .read(currentOrderProvider.notifier)
                                      .closeOrderPaid(),
                            child: Text(
                              'PAGAR ${order.order == null ? "" : "RD\$ ${order.order!.total.toStringAsFixed(2)}"}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                letterSpacing: .2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ------------------- PANEL DERECHO (categorías / productos)
          Expanded(
            child: Column(
              children: [
                // Tabs
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: TabBar(
                    controller: _tab,
                    isScrollable: true,
                    labelColor: MangoColors.darkGray,
                    unselectedLabelColor: MangoColors.muted,
                    indicatorColor: MangoColors.primaryOrange,
                    tabs: const [
                      Tab(text: 'Categoría'),
                      Tab(text: 'Menú'),
                      Tab(text: 'Búsqueda'),
                      Tab(text: 'Favoritos'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                Expanded(
                  child: Stack(
                    children: [
                      TabBarView(
                        controller: _tab,
                        children: [
                          _CategoriesTab(),
                          _ProductsGridTab(),
                          _SearchTab(controller: _searchCtrl),
                          const _FavoritesPlaceholder(),
                        ],
                      ),
                      if (menu.loading)
                        const Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= TABS (reutilizan el VM de menú) ======================

class _CategoriesTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(menuBrowserVmProvider);
    final notifier = ref.read(menuBrowserVmProvider.notifier);

    if (vm.error != null) {
      return _ErrorBox(message: vm.error!, onRetry: () => notifier.loadAll());
    }

    if (vm.categories.isEmpty && vm.loading) {
      return const _CenteredSpinner(label: 'Cargando categorías...');
    }

    if (vm.categories.isEmpty) {
      return const _EmptyBox(
        icon: Icons.category_outlined,
        text: 'No hay categorías activas',
      );
    }

    return Column(
      children: [
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: vm.categories
                .map(
                  (c) => ChoiceChip(
                    label: Text(c.name),
                    selectedColor: MangoColors.primaryOrange.withOpacity(.12),
                    selected: vm.selectedCategoryId == c.id,
                    onSelected: (_) => notifier.loadProductsByCategory(c.id),
                    labelStyle: TextStyle(
                      color: vm.selectedCategoryId == c.id
                          ? MangoColors.primaryOrange
                          : MangoColors.darkGray,
                      fontWeight: vm.selectedCategoryId == c.id
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const Divider(height: 24),
        Expanded(child: _ProductsGridTab()),
      ],
    );
  }
}

class _ProductsGridTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(menuBrowserVmProvider);

    if (vm.error != null && !vm.loading) {
      return _ErrorBox(
        message: vm.error!,
        onRetry: () => ref
            .read(menuBrowserVmProvider.notifier)
            .loadProductsByCategory(vm.selectedCategoryId ?? ''),
      );
    }
    if (vm.products.isEmpty && vm.loading) {
      return const _CenteredSpinner(label: 'Cargando productos...');
    }
    if (vm.products.isEmpty) {
      return const _EmptyBox(
        icon: Icons.fastfood_outlined,
        text: 'No hay productos en esta categoría',
      );
    }

    // Responsive: columnas y proporción pensadas para cards con barra inferior
    final w = MediaQuery.of(context).size.width;
    int cross = 2;
    double aspect = 0.88; // un poco “alta” para imagen + nombre + barra

    if (w >= 560) {
      cross = 3;
      aspect = 0.92;
    }
    if (w >= 820) {
      cross = 4;
      aspect = 0.96;
    }
    if (w >= 1080) {
      cross = 5;
      aspect = 1.00;
    }
    if (w >= 1280) {
      cross = 6;
      aspect = 1.02;
    }
    if (w >= 1500) {
      cross = 7;
      aspect = 1.05;
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: GridView.builder(
        itemCount: vm.products.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cross,
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: aspect,
        ),
        itemBuilder: (_, i) => _ProductCard(item: vm.products[i]),
      ),
    );
  }
}

class _ProductCard extends ConsumerWidget {
  final MenuProduct item;
  const _ProductCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final price = 'RD\$${item.price.toStringAsFixed(2)}';

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        // 👉 NUEVO: abre popup de confirmación para cantidad / para llevar
        final orderState = ref.read(currentOrderProvider);
        final result = await showAddToOrderDialog(
          context,
          productName: item.name,
          unitPrice: item.price,
          initialTakeout: orderState.takeout,
        );

        if (result == null) return; // cancelado

        try {
          await ref
              .read(currentOrderProvider.notifier)
              .addItem(
                menuItemId: item.id,
                qty: result.qty,
                // Requiere que tu método soporte este parámetro:
                takeout: result.isTakeout,
              );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Agregado: ${item.name} x ${result.qty.toStringAsFixed(0)}'
                  '${result.isTakeout ? " (Para llevar)" : ""}',
                ),
                duration: const Duration(milliseconds: 1200),
              ),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('No se pudo agregar: $e')));
          }
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: MangoColors.cardBorder, width: 1),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              blurRadius: 10,
              offset: const Offset(0, 4),
              color: Colors.black.withOpacity(.06),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias, // evita overflow en bordes redondeados
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Imagen
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      color: Colors.grey.shade100,
                      child: item.imageUrl == null
                          ? const Icon(
                              Icons.fastfood,
                              size: 48,
                              color: MangoColors.muted,
                            )
                          : Image.network(
                              item.imageUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image_outlined,
                                size: 48,
                                color: MangoColors.muted,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),

            // Nombre
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Text(
                item.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: MangoColors.darkGray,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),

            // Barra inferior con el precio (a todo lo ancho)
            Container(
              height: 36,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: MangoColors.primaryOrange,
                // sutil división como en tu referencia
                border: Border(
                  top: BorderSide(color: Colors.white24, width: 0.4),
                ),
              ),
              child: Text(
                price,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchTab extends ConsumerWidget {
  final TextEditingController controller;
  const _SearchTab({required this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(menuBrowserVmProvider);
    final notifier = ref.read(menuBrowserVmProvider.notifier);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: 'Buscar por nombre...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: vm.search.isNotEmpty
                  ? IconButton(
                      tooltip: 'Limpiar',
                      onPressed: () {
                        controller.clear();
                        notifier.searchProducts('');
                      },
                      icon: const Icon(Icons.close),
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              isDense: true,
            ),
            onChanged: notifier.searchProducts,
          ),
        ),
        const Divider(height: 8),
        Expanded(child: _ProductsGridTab()),
      ],
    );
  }
}

class _FavoritesPlaceholder extends StatelessWidget {
  const _FavoritesPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const _EmptyBox(
      icon: Icons.star_border,
      text: 'Aún no tienes favoritos',
    );
  }
}

// ============================ Helpers UI ============================

class _CenteredSpinner extends StatelessWidget {
  final String label;
  const _CenteredSpinner({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(color: MangoColors.muted)),
        ],
      ),
    );
  }
}

class _EmptyBox extends StatelessWidget {
  final IconData icon;
  final String text;
  const _EmptyBox({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: MangoColors.muted),
          const SizedBox(height: 12),
          Text(
            text,
            style: const TextStyle(
              color: MangoColors.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: Colors.red.shade400),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.red.shade600),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================ POPUPS ============================

// Resultado simple del diálogo “Agregar al pedido”
class _AddToOrderResult {
  final double qty;
  final bool isTakeout;
  const _AddToOrderResult({required this.qty, required this.isTakeout});
}

/// Diálogo para confirmar cantidad y "para llevar" al tocar un producto
Future<_AddToOrderResult?> showAddToOrderDialog(
  BuildContext context, {
  required String productName,
  required double unitPrice,
  bool initialTakeout = false,
}) async {
  double qty = 1;
  bool takeout = initialTakeout;

  return showDialog<_AddToOrderResult>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          final total = unitPrice * qty;

          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 40,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      children: [
                        const Icon(
                          Icons.add_shopping_cart_outlined,
                          color: MangoColors.primaryOrange,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            productName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Confirmar producto',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),

                    // Cantidad
                    Row(
                      children: [
                        const Text(
                          'Cantidad',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: 'Restar',
                                onPressed: qty > 1
                                    ? () => setState(
                                        () => qty = (qty - 1).clamp(1, 9999),
                                      )
                                    : null,
                                icon: const Icon(Icons.remove),
                              ),
                              Text(
                                qty.toStringAsFixed(0),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Sumar',
                                onPressed: () => setState(() => qty = qty + 1),
                                icon: const Icon(Icons.add),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Para llevar
                    Row(
                      children: [
                        const Text(
                          '¿Para llevar?',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        Switch.adaptive(
                          value: takeout,
                          onChanged: (v) => setState(() => takeout = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Resumen
                    Row(
                      children: [
                        const Text('Precio unitario'),
                        const Spacer(),
                        Text(
                          'RD\$${unitPrice.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Text('Total'),
                        const Spacer(),
                        Text(
                          'RD\$${total.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 12),

                    // Acciones
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                            label: const Text('Cancelar'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: MangoColors.primaryOrange,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: qty < 1
                                ? null
                                : () => Navigator.pop(
                                    context,
                                    _AddToOrderResult(
                                      qty: qty.toDouble(),
                                      isTakeout: takeout,
                                    ),
                                  ),
                            icon: const Icon(Icons.check_circle_outline),
                            label: const Text('Agregar'),
                          ),
                        ),
                      ],
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

/// Dialog de detalle del ítem YA agregado (UI informativa, sin acciones)
Future<void> showOrderItemDetailDialog(
  BuildContext context, {
  required String name,
  required double qty,
  required double unitPrice,
  required bool isTakeout,
}) async {
  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    const Icon(
                      Icons.restaurant_menu_outlined,
                      color: MangoColors.primaryOrange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                const Text(
                  'Detalle del pedido',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),

                // Nombre de reemplazo
                TextField(
                  enabled: false,
                  decoration: InputDecoration(
                    labelText: 'Nombre de reemplazo',
                    hintText: name,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),

                // Notas
                TextField(
                  enabled: false,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Notas del pedido',
                    hintText: 'Por ejm: caliente, sin sal...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),

                // Para llevar
                Row(
                  children: [
                    const Text('¿Tu pedido es para llevar?'),
                    const Spacer(),
                    Switch(value: isTakeout, onChanged: null),
                  ],
                ),
                const SizedBox(height: 12),

                // Cantidad + Precio
                Row(
                  children: [
                    const Text(
                      'Cantidad',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: null,
                          ),
                          Text(
                            qty.toStringAsFixed(0),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: null,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text(
                      'Precio unitario',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Text(
                      'RD\$${unitPrice.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 12),

                // Botones pie (deshabilitados)
                LayoutBuilder(
                  builder: (context, c) {
                    final isNarrow = c.maxWidth < 520;
                    final children = [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: null, // 🔒 Solo UI
                          icon: const Icon(Icons.warning_amber_outlined),
                          label: const Text('Agotar producto'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey.shade300,
                            foregroundColor: Colors.grey.shade700,
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                      if (!isNarrow)
                        const SizedBox(width: 8)
                      else
                        const SizedBox(height: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: null, // 🔒 Solo UI
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Eliminar pedido'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey.shade300,
                            foregroundColor: Colors.grey.shade700,
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                      if (!isNarrow)
                        const SizedBox(width: 8)
                      else
                        const SizedBox(height: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: null, // 🔒 Solo UI
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('Guardar cambios'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: MangoColors.primaryOrange
                                .withOpacity(.5),
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                    ];

                    return isNarrow
                        ? Column(children: children)
                        : Row(children: children);
                  },
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
