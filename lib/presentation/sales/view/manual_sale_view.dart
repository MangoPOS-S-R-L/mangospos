import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/payments/widgets/payment_modal.dart';
import 'package:mangopos/data/models/sales_models.dart';

// --- CONSTANTS & DESIGN TOKENS ---
const kColorBackground = Color(0xFFFAF9F7); // Creamy White
const kColorCartPanel = Color(0xFFFFFFFF);
const kColorTextMain = Color(0xFF231F1D);
const kColorPrimary = Color(0xFFFB7116);
const kColorPrimaryGradientEnd = Color(0xFFFBA24F);
const kShadowSoft = BoxShadow(
  color: Color.fromRGBO(0, 0, 0, 0.05),
  blurRadius: 20,
  offset: Offset(0, 4),
  spreadRadius: -2,
);

class ManualSaleView extends ConsumerStatefulWidget {
  const ManualSaleView({super.key});

  @override
  ConsumerState<ManualSaleView> createState() => _ManualSaleViewState();
}

class _ManualSaleViewState extends ConsumerState<ManualSaleView> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(menuBrowserVmProvider.notifier).loadAll();
      ref.read(currentOrderProvider.notifier).ensureManualOrder();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kColorBackground,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 1024;

          if (isDesktop) {
            // --- DESKTOP LAYOUT ---
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. COLUMNA IZQUIERDA (CATÁLOGO)
                Expanded(
                  flex: 65,
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: _CatalogSection(searchController: _searchCtrl),
                  ),
                ),
                // 2. COLUMNA DERECHA (TIKET/CARRITO)
                Container(
                  width: 400,
                  decoration: const BoxDecoration(
                    color: kColorCartPanel,
                    border: Border(
                      left: BorderSide(color: Color(0xFFE0DBD9), width: 1),
                    ),
                  ),
                  child: const _CartSection(),
                ),
              ],
            );
          } else {
            // --- MOBILE/TABLET LAYOUT ---
            return Stack(
              children: [
                // Catálogo Full Width
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: columnWithBottomPadding(context),
                  ),
                ),
                // Barra Inferior Flotante
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _MobileBottomBar(
                    onOpenCart: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => Container(
                          height: MediaQuery.of(context).size.height * 0.85,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                          ),
                          child: const ClipRRect(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                            child: _CartSection(isMobileModal: true),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          }
        },
      ),
    );
  }

  Widget columnWithBottomPadding(BuildContext context) {
    return Column(
      children: [
        Expanded(child: _CatalogSection(searchController: _searchCtrl)),
        const SizedBox(height: 80), // Space for bottom bar
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// SECCIÓN 1: CATÁLOGO Y BUSCADOR
// -----------------------------------------------------------------------------
class _CatalogSection extends ConsumerWidget {
  final TextEditingController searchController;

  const _CatalogSection({required this.searchController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menuVm = ref.watch(menuBrowserVmProvider);
    final notifier = ref.read(menuBrowserVmProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. HEADER DEL CATÁLOGO
        // Buscador
        Container(
          height: 56,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.grey.shade200),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.03),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: searchController,
            onChanged: notifier.searchProducts,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 16,
              color: kColorTextMain,
            ),
            decoration: InputDecoration(
              hintText: "Buscar por nombre, código de barras o SKU...",
              hintStyle: GoogleFonts.plusJakartaSans(
                color: Colors.grey.shade400,
              ),
              prefixIcon: Icon(Icons.search, color: Colors.grey.shade400),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
              suffixIcon: menuVm.search.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        searchController.clear();
                        notifier.searchProducts('');
                      },
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Filtro de Categorías (Pills)
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _CategoryPill(
                label: 'Todas',
                isSelected: menuVm.selectedCategoryId == null,
                onTap: () => notifier.loadAll(),
              ),
              ...menuVm.categories.map((c) {
                return _CategoryPill(
                  label: c.name,
                  isSelected: menuVm.selectedCategoryId == c.id,
                  onTap: () => notifier.loadProductsByCategory(c.id),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // 2. GRID DE PRODUCTOS
        Expanded(
          child: menuVm.loading && menuVm.products.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(color: kColorPrimary),
                )
              : menuVm.products.isEmpty
              ? Center(
                  child: Text(
                    "No se encontraron productos",
                    style: GoogleFonts.plusJakartaSans(
                      color: Colors.grey,
                      fontSize: 16,
                    ),
                  ),
                )
              : GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 240,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: menuVm.products.length,
                  itemBuilder: (context, index) {
                    final product = menuVm.products[index];
                    return _ProductCard(item: product);
                  },
                ),
        ),
      ],
    );
  }
}

class _CategoryPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _CategoryPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? kColorPrimary : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isSelected ? kColorPrimary : Colors.grey.shade200,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              color: isSelected ? Colors.white : Colors.grey.shade600,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProductCard extends ConsumerStatefulWidget {
  final MenuProduct item;

  const _ProductCard({required this.item});

  @override
  ConsumerState<_ProductCard> createState() => _ProductCardState();
}

class _ProductCardState extends ConsumerState<_ProductCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() async {
    _controller.forward().then((_) => _controller.reverse());
    try {
      await ref
          .read(currentOrderProvider.notifier)
          .addItem(
            menuItemId: widget.item.id,
            qty: 1,
            takeout: false,
            productName: widget.item.name,
            productPrice: widget.item.price,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) =>
            Transform.scale(scale: _scaleAnimation.value, child: child),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.04), // Soft shadow
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Image Placeholder or Real Image
              Expanded(
                flex: 3,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12),
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.fastfood_rounded,
                      size: 40,
                      color: Colors.grey.shade300,
                    ),
                  ),
                ),
              ),
              // Content
              Expanded(
                flex: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        widget.item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: kColorTextMain,
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'RD\$${widget.item.price.toStringAsFixed(2)}',
                            style: GoogleFonts.plusJakartaSans(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              color: kColorPrimary,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: kColorPrimary,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.add,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ],
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

// -----------------------------------------------------------------------------
// SECCIÓN 2: TICKET, CLIENTE Y PAGO (CARRITO)
// -----------------------------------------------------------------------------
class _CartSection extends ConsumerWidget {
  final bool isMobileModal;

  const _CartSection({this.isMobileModal = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderState = ref.watch(currentOrderProvider);
    final items = orderState.items;
    final total = (orderState.order?.total as num?)?.toDouble() ?? 0.0;
    final subtotal = total / 1.18; // Approx tax logic if not provided
    final tax = total - subtotal;

    return Column(
      children: [
        if (isMobileModal)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

        // 1. Cabecera del Ticket (Cliente)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Column(
            children: [
              // Selector Cliente
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.person_outline,
                    color: kColorTextMain,
                  ),
                  title: Text(
                    "Cliente Público",
                    style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w600,
                      color: kColorTextMain,
                    ),
                  ),
                  trailing: const Icon(Icons.keyboard_arrow_down, size: 20),
                  onTap: () {
                    // TODO: Selector de cliente
                  },
                ),
              ),
              const SizedBox(height: 12),
              // Tipo de Comprobante Tabs
              Container(
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    _InvoiceTab(label: "Recibo", isActive: true),
                    _InvoiceTab(label: "Factura", isActive: false),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(),

        // 2. Lista de Items
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.shopping_cart_outlined,
                        size: 48,
                        color: Colors.grey[300],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        "El carrito está vacío",
                        style: GoogleFonts.plusJakartaSans(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _CartItemRow(item: item);
                  },
                ),
        ),

        // 3. Resumen Financiero
        Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Column(
            children: [
              _SummaryRow(label: "Subtotal", value: subtotal),
              _SummaryRow(label: "ITBIS (18%)", value: tax),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "TOTAL",
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: kColorTextMain,
                    ),
                  ),
                  Text(
                    "RD\$ ${total.toStringAsFixed(2)}",
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 24, // 32px is too big for 400px width sometimes
                      fontWeight: FontWeight.w800,
                      color: kColorPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // 4. Panel de Acciones
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        ref
                            .read(currentOrderProvider.notifier)
                            .openManual(forceRestart: true);
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: BorderSide(color: Colors.red.shade100),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        "CANCELAR",
                        style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700,
                          color: Colors.red.shade400,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [kColorPrimary, kColorPrimaryGradientEnd],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: kColorPrimary.withValues(alpha: 0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: items.isEmpty
                            ? null
                            : () {
                                if (orderState.order == null) return;
                                if (isMobileModal)
                                  Navigator.pop(context); // Close sheet
                                showDialog(
                                  context: context,
                                  builder: (context) => PaymentModal(
                                    order: orderState.order!,
                                    onPaymentSuccess: () {
                                      ref
                                          .read(currentOrderProvider.notifier)
                                          .refreshOrder(clearIfPaid: true);
                                      ref
                                          .read(currentOrderProvider.notifier)
                                          .openManual(forceRestart: true);
                                    },
                                  ),
                                );
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          "COBRAR",
                          style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: Colors.white,
                            letterSpacing: 1,
                          ),
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

class _InvoiceTab extends StatelessWidget {
  final String label;
  final bool isActive;

  const _InvoiceTab({required this.label, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 2,
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 12,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive ? kColorTextMain : Colors.grey,
          ),
        ),
      ),
    );
  }
}

class _CartItemRow extends ConsumerWidget {
  final OrderItem item;

  const _CartItemRow({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qty = (item.quantity as num).toDouble();
    final total = (item.total as num).toDouble();

    return Row(
      children: [
        // Name & Unit Price
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.productName ?? 'Producto',
                style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: kColorTextMain,
                ),
              ),
              Text(
                "RD\$ ${(total / (qty == 0 ? 1 : qty)).toStringAsFixed(2)}",
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ),
        // Stepper
        Expanded(
          flex: 3,
          child: Container(
            height: 32,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _StepperBtn(
                  icon: Icons.remove,
                  onTap: () {
                    // Lógica para reducir cantidad o eliminar
                    if (qty > 1) {
                      ref
                          .read(currentOrderProvider.notifier)
                          .updateItemQuantity(item.id, qty - 1);
                    } else {
                      ref
                          .read(currentOrderProvider.notifier)
                          .deleteItem(item.id);
                    }
                  },
                ),
                Text(
                  qty % 1 == 0 ? qty.toInt().toString() : qty.toString(),
                  style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _StepperBtn(
                  icon: Icons.add,
                  onTap: () {
                    ref
                        .read(currentOrderProvider.notifier)
                        .updateItemQuantity(item.id, qty + 1);
                  },
                ),
              ],
            ),
          ),
        ),
        // Total
        Expanded(
          flex: 3,
          child: Text(
            "RD\$ ${total.toStringAsFixed(2)}",
            textAlign: TextAlign.right,
            style: GoogleFonts.plusJakartaSans(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: kColorTextMain,
            ),
          ),
        ),
      ],
    );
  }
}

class _StepperBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepperBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(icon, size: 16, color: kColorTextMain),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final double value;

  const _SummaryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              color: Colors.grey[600],
            ),
          ),
          Text(
            "RD\$ ${value.toStringAsFixed(2)}",
            style: GoogleFonts.plusJakartaSans(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: kColorTextMain,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileBottomBar extends ConsumerWidget {
  final VoidCallback onOpenCart;

  const _MobileBottomBar({required this.onOpenCart});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(currentOrderProvider);
    final total = (order.order?.total as num?)?.toDouble() ?? 0.0;
    final itemCount = order.items.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Total",
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              Text(
                "RD\$ ${total.toStringAsFixed(2)}",
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: kColorTextMain,
                ),
              ),
            ],
          ),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: onOpenCart,
            style: ElevatedButton.styleFrom(
              backgroundColor: kColorPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.shopping_bag_outlined, color: Colors.white),
            label: Text(
              "Ver Carrito ($itemCount)",
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
