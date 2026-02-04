import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';

class CatalogColumn extends ConsumerStatefulWidget {
  final String tableCode;
  final Function(MenuProduct) onProductTap;
  final VoidCallback? onMobileMenuTap;

  const CatalogColumn({
    super.key,
    required this.tableCode,
    required this.onProductTap,
    this.onMobileMenuTap,
  });

  @override
  ConsumerState<CatalogColumn> createState() => _CatalogColumnState();
}

class _CatalogColumnState extends ConsumerState<CatalogColumn> {
  int _selectedTab = 0;
  String? _selectedCategoryId;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // A. HEADER (h-[70px])
        Container(
          height: 70,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: SalesTheme.border)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Left: Back/Menu + Title
              Row(
                children: [
                  _NavigationButton(
                    isBack: _selectedCategoryId != null,
                    onTap: () {
                      if (_selectedCategoryId != null) {
                        setState(() => _selectedCategoryId = null);
                      } else {
                        widget.onMobileMenuTap?.call();
                      }
                    },
                  ),
                  const SizedBox(width: 16),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedCategoryId != null
                            ? 'Productos'
                            : 'Menú Principal',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 20, // text-xl
                          fontWeight: FontWeight.w700,
                          color: SalesTheme.foreground,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _selectedCategoryId != null
                            ? 'Selecciona un producto'
                            : 'Selecciona una categoría',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12, // text-xs
                          color: SalesTheme.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              // Right: Asignar cliente
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.person_outline, size: 16),
                label: const Text('Asignar cliente'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36), // h-9
                  foregroundColor: SalesTheme.foreground,
                  side: const BorderSide(color: SalesTheme.border),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ],
          ),
        ),

        // B. SEARCH & TABS
        Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: SalesTheme.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Search (px-6 py-3)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: Container(
                  height: 44, // h-11
                  decoration: BoxDecoration(
                    color: SalesTheme.secondary.withOpacity(
                      0.5,
                    ), // bg-secondary/20 approximation
                    border: Border.all(color: SalesTheme.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      const Icon(
                        Icons.search,
                        size: 16,
                        color: SalesTheme.mutedForeground,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          onChanged: (val) {
                            ref
                                .read(menuBrowserVmProvider.notifier)
                                .searchProducts(val);
                            // If searching, maybe clear category selection?
                          },
                          style: const TextStyle(fontSize: 14),
                          decoration: const InputDecoration(
                            hintText: 'Buscar productos...',
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Tabs (px-6 flex gap-6)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    _TabButton(
                      label: 'Categorías',
                      isActive: _selectedTab == 0,
                      onTap: () => setState(() {
                        _selectedTab = 0;
                        _selectedCategoryId = null; // Reset nav
                      }),
                    ),
                    const SizedBox(width: 24),
                    _TabButton(
                      label: 'Menú',
                      isActive: _selectedTab == 1,
                      onTap: () => setState(() => _selectedTab = 1),
                    ),
                    const SizedBox(width: 24),
                    _TabButton(
                      label: 'Favoritos',
                      isActive: _selectedTab == 2,
                      onTap: () => setState(() => _selectedTab = 2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // C. CONTENT
        Expanded(
          child: Container(
            color: SalesTheme.secondary.withOpacity(0.3),
            padding: const EdgeInsets.all(24),
            child: _buildContent(),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_selectedTab == 0) {
      return _CategoriesView(
        selectedCategoryId: _selectedCategoryId,
        onCategorySelect: (id) => setState(() => _selectedCategoryId = id),
        onProductTap: widget.onProductTap,
      );
    } else if (_selectedTab == 1) {
      // Just reuse Categories view or implement flat list
      return const Center(child: Text('Vista Menú - Pendiente'));
    } else {
      return const Center(child: Text('Favoritos - Pendiente'));
    }
  }
}

class _NavigationButton extends StatelessWidget {
  final bool isBack;
  final VoidCallback onTap;

  const _NavigationButton({required this.isBack, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent, // hover:bg-accent handled
        ),
        child: Icon(
          isBack ? Icons.arrow_back : Icons.menu,
          color: SalesTheme.foreground,
          size: 24,
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isActive ? SalesTheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive ? SalesTheme.primary : SalesTheme.mutedForeground,
          ),
        ),
      ),
    );
  }
}

class _CategoriesView extends ConsumerWidget {
  final String? selectedCategoryId;
  final Function(String?) onCategorySelect;
  final Function(MenuProduct) onProductTap;

  const _CategoriesView({
    required this.selectedCategoryId,
    required this.onCategorySelect,
    required this.onProductTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(menuBrowserVmProvider);
    final categories = state.categories;

    if (selectedCategoryId != null) {
      // Products Grid
      final products = state.products
          .where((p) => p.categoryId == selectedCategoryId)
          .toList();
      // Should show category name? Spec says: Header has "Entradas" (h3) + "Ver todas" button.
      // We already have main header showing "Productos".
      // We'll mimic the "Content (Grid)" Section C.

      final categoryName = categories
          .firstWhere(
            (c) => c.id == selectedCategoryId,
            orElse: () => const MenuCategory(id: '', name: 'Unknown'),
          )
          .name;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                categoryName,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: SalesTheme.foreground,
                ),
              ),
              TextButton(
                onPressed: () => onCategorySelect(null),
                child: const Text('Ver todas'),
                style: TextButton.styleFrom(
                  foregroundColor: SalesTheme.primary,
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.only(bottom: 80), // Space for scroll
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 250, // Responsive approximation
                childAspectRatio: 4 / 3, // aspect-[4/3]
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: products.length,
              itemBuilder: (context, index) {
                return _ProductCard(
                  product: products[index],
                  onTap: () => onProductTap(products[index]),
                );
              },
            ),
          ),
        ],
      );
    }

    // Categories List
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        childAspectRatio: 1.5,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final cat = categories[index];
        return InkWell(
          onTap: () async {
            onCategorySelect(cat.id);
            await ref
                .read(menuBrowserVmProvider.notifier)
                .loadProductsByCategory(cat.id);
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: SalesTheme.border),
              boxShadow: [SalesTheme.shadowCard],
            ),
            alignment: Alignment.center,
            child: Text(
              cat.name,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        );
      },
    );
  }
}

class _ProductCard extends StatefulWidget {
  final MenuProduct product;
  final VoidCallback onTap;
  const _ProductCard({required this.product, required this.onTap});

  @override
  State<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends State<_ProductCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    // Spec: rounded-2xl border border-border/60 shadow-sm hover:shadow-lg hover:border-primary/40 hover:-translate-y-1
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          transform: _isHovered
              ? (Matrix4.identity()..translate(0.0, -4.0))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16), // rounded-2xl
            border: Border.all(
              color: _isHovered
                  ? SalesTheme.primary.withOpacity(0.4)
                  : SalesTheme.border.withOpacity(0.6),
            ),
            boxShadow: [
              if (_isHovered)
                const BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.1),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                )
              else
                const BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.05),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
            ],
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 18, // text-lg
                  fontWeight: FontWeight.w700, // font-bold
                  color: _isHovered
                      ? SalesTheme.primary
                      : SalesTheme.foreground,
                  height: 1.2,
                ),
              ),
              Text(
                'RD\$ ${widget.product.price.toStringAsFixed(0)}',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 20, // text-xl
                  fontWeight: FontWeight.w900, // font-black
                  color: SalesTheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
