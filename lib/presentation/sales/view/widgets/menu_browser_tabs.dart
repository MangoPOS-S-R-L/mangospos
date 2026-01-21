import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';

/// Shared tabbed browser used by table orders and manual sales.
class MenuBrowserTabs extends ConsumerWidget {
  final TabController tabController;
  final TextEditingController searchController;
  final VoidCallback onAddProduct;

  const MenuBrowserTabs({
    super.key,
    required this.tabController,
    required this.searchController,
    required this.onAddProduct,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menuState = ref.watch(menuBrowserVmProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: TabBar(
            controller: tabController,
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
                controller: tabController,
                children: [
                  _CategoriesTab(onAddProduct: onAddProduct),
                  _ProductsGridTab(onAddProduct: onAddProduct),
                  _SearchTab(
                    controller: searchController,
                    onAddProduct: onAddProduct,
                  ),
                  const _FavoritesPlaceholder(),
                ],
              ),
              if (menuState.loading)
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
    );
  }
}

class _CategoriesTab extends ConsumerWidget {
  final VoidCallback onAddProduct;
  const _CategoriesTab({required this.onAddProduct});

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
        Expanded(child: _ProductsGridTab(onAddProduct: onAddProduct)),
      ],
    );
  }
}

class _ProductsGridTab extends ConsumerWidget {
  final VoidCallback onAddProduct;
  const _ProductsGridTab({required this.onAddProduct});

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
    final w = MediaQuery.of(context).size.width;
    int cross = 2;
    double aspect = 1.0;
    if (w >= 560) cross = 3;
    if (w >= 820) cross = 4;
    if (w >= 1080) cross = 5;
    if (w >= 1280) cross = 6;
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
        itemBuilder: (_, i) =>
            _ProductCard(item: vm.products[i], onAddProduct: onAddProduct),
      ),
    );
  }
}

class _ProductCard extends ConsumerWidget {
  final MenuProduct item;
  final VoidCallback onAddProduct;
  const _ProductCard({required this.item, required this.onAddProduct});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final price = 'RD\$${item.price.toStringAsFixed(2)}';
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        try {
          await ref
              .read(currentOrderProvider.notifier)
              .addItem(menuItemId: item.id, qty: 1, takeout: false);
          onAddProduct();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Agregado: ${item.name}'),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Colors.grey.shade100,
                child: const Icon(
                  Icons.fastfood,
                  size: 48,
                  color: MangoColors.muted,
                ),
              ),
            ),
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
            Container(
              height: 36,
              alignment: Alignment.center,
              color: MangoColors.primaryOrange,
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
  final VoidCallback onAddProduct;
  const _SearchTab({required this.controller, required this.onAddProduct});

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
        Expanded(child: _ProductsGridTab(onAddProduct: onAddProduct)),
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
