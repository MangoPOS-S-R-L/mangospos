import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';

class MenuBrowserSheet extends ConsumerStatefulWidget {
  const MenuBrowserSheet({super.key});

  @override
  ConsumerState<MenuBrowserSheet> createState() => _MenuBrowserSheetState();
}

class _MenuBrowserSheetState extends ConsumerState<MenuBrowserSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 4,
      vsync: this,
    ); // Categoría | Menú | Búsqueda | Favoritos
    _tab.addListener(_handleTabChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(menuBrowserVmProvider.notifier).loadAll();
    });
  }

  void _handleTabChange() {
    if (_tab.indexIsChanging) return;

    final notifier = ref.read(menuBrowserVmProvider.notifier);
    switch (_tab.index) {
      case 0:
        notifier.loadProductsByCategory(
          ref.read(menuBrowserVmProvider).selectedCategoryId ?? '',
        );
        break;
      case 1:
        notifier.loadDefaultMenuProducts();
        break;
      case 2:
        if (_searchCtrl.text.trim().isNotEmpty) {
          notifier.searchProducts(_searchCtrl.text);
        }
        break;
      case 3:
        notifier.loadFavoriteProducts();
        break;
    }
  }

  @override
  void dispose() {
    _tab.removeListener(_handleTabChange);
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(menuBrowserVmProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        titleSpacing: 0,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            const Text(
              'Selecciona productos',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            TabBar(
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
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            onPressed: () => ref
                .read(menuBrowserVmProvider.notifier)
                .loadAll(
                  preselectCategoryId: vm.selectedCategoryId,
                  preselectMenuId: vm.selectedMenuId,
                ),
            icon: const Icon(Icons.refresh, color: MangoColors.darkGray),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tab,
            children: [
              _CategoriesTab(),
              _MenusTab(),
              _SearchTab(controller: _searchCtrl),
              _FavoritesTab(),
            ],
          ),
          if (vm.loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }
}

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
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: vm.categories
              .map(
                (c) => ChoiceChip(
                  label: Text(c.name),
                  selectedColor: MangoColors.primaryOrange.withValues(
                    alpha: .12,
                  ),
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
        const Divider(height: 24),
        Expanded(child: _ProductsGridTab()),
      ],
    );
  }
}

class _MenusTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(menuBrowserVmProvider);
    final notifier = ref.read(menuBrowserVmProvider.notifier);

    if (vm.error != null) {
      return _ErrorBox(
        message: vm.error!,
        onRetry: () => notifier.loadDefaultMenuProducts(),
      );
    }

    if (vm.menus.isEmpty && vm.loading) {
      return const _CenteredSpinner(label: 'Cargando menus...');
    }

    if (vm.menus.isEmpty) {
      return const _EmptyBox(
        icon: Icons.restaurant_menu_outlined,
        text: 'No hay menus activos',
      );
    }

    return Column(
      children: [
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: vm.menus
              .map(
                (menu) => ChoiceChip(
                  label: Text(menu.name),
                  selectedColor: MangoColors.primaryOrange.withValues(
                    alpha: .12,
                  ),
                  selected: vm.selectedMenuId == menu.id,
                  onSelected: (_) => notifier.loadProductsByMenu(menu.id),
                  labelStyle: TextStyle(
                    color: vm.selectedMenuId == menu.id
                        ? MangoColors.primaryOrange
                        : MangoColors.darkGray,
                    fontWeight: vm.selectedMenuId == menu.id
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              )
              .toList(),
        ),
        const Divider(height: 24),
        const Expanded(
          child: _ProductsGridTab(
            emptyText: 'No hay productos activos en este menu',
          ),
        ),
      ],
    );
  }
}

class _ProductsGridTab extends ConsumerWidget {
  final String emptyText;

  const _ProductsGridTab({
    this.emptyText = 'No hay productos en esta categoría',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(menuBrowserVmProvider);

    if (vm.error != null && !vm.loading) {
      return _ErrorBox(
        message: vm.error!,
        onRetry: () {
          final notifier = ref.read(menuBrowserVmProvider.notifier);
          if (vm.productsMode == MenuProductsMode.menu &&
              vm.selectedMenuId != null) {
            notifier.loadProductsByMenu(vm.selectedMenuId!);
            return;
          }
          notifier.loadProductsByCategory(vm.selectedCategoryId ?? '');
        },
      );
    }

    if (vm.products.isEmpty && vm.loading) {
      return const _CenteredSpinner(label: 'Cargando productos...');
    }

    if (vm.products.isEmpty) {
      return _EmptyBox(
        icon: Icons.fastfood_outlined,
        text: emptyText,
      );
    }

    // Grid responsive
    final w = MediaQuery.of(context).size.width;
    int cross = 2;
    if (w >= 560) cross = 3;
    if (w >= 820) cross = 4;
    if (w >= 1080) cross = 5;
    if (w >= 1280) cross = 6;
    if (w >= 1500) cross = 7;
    if (w >= 1800) cross = 8;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: GridView.builder(
        itemCount: vm.products.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cross,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.15,
        ),
        itemBuilder: (_, i) => _ProductCard(item: vm.products[i]),
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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
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

class _FavoritesTab extends StatelessWidget {
  const _FavoritesTab();

  @override
  Widget build(BuildContext context) {
    return _FavoritesProductsGrid();
  }
}

class _FavoritesProductsGrid extends ConsumerWidget {
  const _FavoritesProductsGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(menuBrowserVmProvider);

    if (vm.error != null && !vm.loading) {
      return _ErrorBox(
        message: vm.error!,
        onRetry: () => ref.read(menuBrowserVmProvider.notifier).loadFavoriteProducts(),
      );
    }

    if (vm.products.isEmpty && vm.loading) {
      return const _CenteredSpinner(label: 'Cargando favoritos...');
    }

    if (vm.products.isEmpty) {
      return const _EmptyBox(
        icon: Icons.star_border,
        text: 'Todavía no hay productos frecuentes',
      );
    }

    return _ProductsGridTab();
  }
}

class _ProductCard extends ConsumerWidget {
  final MenuProduct item;
  const _ProductCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = Theme.of(context).textTheme;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () async {
        // Al tocar, agrega 1 unidad al pedido actual
        await ref
            .read(currentOrderProvider.notifier)
            .addItem(
              menuItemId: item.id,
              qty: 1,
              productName: item.name,
              productPrice: item.price,
              productTaxMode: item.taxMode,
              productTaxRate: item.taxRate,
            );

        // Feedback visual sutil
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Agregado: ${item.name}'),
              duration: const Duration(milliseconds: 900),
            ),
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: MangoColors.cardBorder, width: 1.5),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              blurRadius: 10,
              offset: const Offset(0, 4),
              color: Colors.black.withValues(alpha: .06),
            ),
          ],
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Expanded(
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    color: Colors.grey.shade100,
                    child: item.imageUrl == null
                        ? const Icon(
                            Icons.restaurant_menu,
                            size: 48,
                            color: MangoColors.muted,
                          )
                        : Image.network(item.imageUrl!, fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: s.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: MangoColors.primaryOrange,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'RD\$${item.price.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
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
