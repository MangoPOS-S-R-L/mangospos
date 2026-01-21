import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/view/widgets/menu_browser_tabs.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/payments/widgets/payment_modal.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ManualSaleView extends ConsumerStatefulWidget {
  const ManualSaleView({super.key});

  @override
  ConsumerState<ManualSaleView> createState() => _ManualSaleViewState();
}

class _ManualSaleViewState extends ConsumerState<ManualSaleView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _searchCtrl = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(menuBrowserVmProvider.notifier).loadAll();
      ref.read(currentOrderProvider.notifier).ensureManualOrder();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(currentOrderProvider);
    final menu = ref.watch(menuBrowserVmProvider);
    final hasOrder = order.order != null;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 320, maxWidth: 420),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(
                    right: BorderSide(color: Colors.black.withOpacity(.06)),
                  ),
                ),
                child: _ManualOrderPanel(
                  order: order,
                  onOrderClosed: () async {
                    await ref
                        .read(currentOrderProvider.notifier)
                        .openManual(forceRestart: true);
                  },
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ManualSaleHeader(
                    refreshing: menu.loading,
                    onRefreshMenu: () => ref
                        .read(menuBrowserVmProvider.notifier)
                        .loadAll(preselectCategoryId: menu.selectedCategoryId),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Stack(
                      children: [
                        MenuBrowserTabs(
                          tabController: _tabs,
                          searchController: _searchCtrl,
                          onAddProduct: () {},
                        ),
                        if (!hasOrder)
                          _ManualSaleOverlay(
                            isLoading: order.loading,
                            message: order.loading
                                ? 'Preparando venta manual...'
                                : 'No pudimos iniciar la venta manual',
                            onRetry: order.loading
                                ? null
                                : () => ref
                                      .read(currentOrderProvider.notifier)
                                      .openManual(),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ManualSaleHeader extends StatelessWidget {
  final bool refreshing;
  final VoidCallback onRefreshMenu;

  const _ManualSaleHeader({
    required this.refreshing,
    required this.onRefreshMenu,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Selecciona productos',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
              ),
              SizedBox(height: 4),
              Text(
                'Explora categorías, menú o búsqueda',
                style: TextStyle(
                  color: MangoColors.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Actualizar menú',
            onPressed: refreshing ? null : onRefreshMenu,
            icon: refreshing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}

class _ManualOrderPanel extends ConsumerWidget {
  final CurrentOrderState order;
  final Future<void> Function()? onOrderClosed;

  const _ManualOrderPanel({required this.order, this.onOrderClosed});

  String _cashierName() {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return 'Sin sesión';
    final metadata = user.userMetadata ?? {};
    return (metadata['full_name'] ?? metadata['name'] ?? user.email ?? user.id)
        as String;
  }

  String _formatCurrency(num value) =>
      'RD\$ ${value.toDouble().toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = (order.order?.total as num?)?.toDouble() ?? 0;
    final canPay =
        order.order != null &&
        order.items.isNotEmpty &&
        !order.loading &&
        total > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (order.loading) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Venta Manual',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Cajero: ${_cashierName()}',
                style: const TextStyle(
                  color: MangoColors.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Selección de clientes estará disponible pronto.',
                        ),
                      ),
                    );
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: MangoColors.darkGray,
                  side: const BorderSide(color: MangoColors.cardBorder),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                icon: const Icon(Icons.person_add_alt_1_outlined),
                label: const Text(
                  'Selecciona un cliente',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        if (order.error != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red.shade400, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    order.error!,
                    style: TextStyle(color: Colors.red.shade600, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: order.loading && order.items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : order.items.isEmpty
                ? const _ManualEmptyCart()
                : ListView.separated(
                    itemCount: order.items.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (_, i) {
                      final it = order.items[i];
                      final qty = (it.quantity as num).toDouble();
                      final totalLine = (it.total as num).toDouble();
                      final unit = qty == 0 ? totalLine : totalLine / qty;
                      final qtyLabel = qty % 1 == 0
                          ? qty.toInt().toString()
                          : qty.toStringAsFixed(1);
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: MangoColors.primaryOrange
                              .withOpacity(.12),
                          foregroundColor: MangoColors.primaryOrange,
                          child: Text(
                            qtyLabel,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        title: Text(
                          it.productName ?? 'Producto',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${_formatCurrency(unit)} · ${it.isTakeout == true ? "Para llevar" : "En salón"}',
                          style: const TextStyle(
                            color: MangoColors.muted,
                            fontSize: 12,
                          ),
                        ),
                        trailing: Text(
                          _formatCurrency(totalLine),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      );
                    },
                  ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Row(
            children: [
              const Text(
                'Para llevar',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              Switch.adaptive(
                value: order.takeout,
                onChanged: (v) =>
                    ref.read(currentOrderProvider.notifier).toggleTakeout(v),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: !canPay
                ? null
                : () {
                    if (order.order == null) return;
                    showDialog(
                      context: context,
                      builder: (context) => PaymentModal(
                        order: order.order!,
                        onPaymentSuccess: () {
                          ref
                              .read(currentOrderProvider.notifier)
                              .refreshOrder(clearIfPaid: true);
                          if (onOrderClosed != null) {
                            onOrderClosed!();
                          } else {
                            ref
                                .read(currentOrderProvider.notifier)
                                .openManual(forceRestart: true);
                          }
                        },
                      ),
                    );
                  },
            child: Text(
              order.items.isEmpty ? 'PAGAR' : 'PAGAR ${_formatCurrency(total)}',
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: .2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ManualSaleOverlay extends StatelessWidget {
  final bool isLoading;
  final String message;
  final VoidCallback? onRetry;
  const _ManualSaleOverlay({
    required this.isLoading,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withOpacity(.8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
            ] else ...[
              const Icon(
                Icons.info_outline,
                size: 36,
                color: MangoColors.muted,
              ),
              const SizedBox(height: 12),
            ],
            Text(
              message,
              style: const TextStyle(
                color: MangoColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Intentar de nuevo'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ManualEmptyCart extends StatelessWidget {
  const _ManualEmptyCart();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.shopping_bag_outlined,
              size: 56,
              color: MangoColors.muted,
            ),
            SizedBox(height: 12),
            Text(
              'Aún no has agregado productos.\nUsa el panel derecho para empezar.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: MangoColors.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
