// lib/presentation/sales/view/sales_shell_view.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';
import 'package:mangopos/services/session/session_controller.dart';

enum SalesTab { byZone, manual, quick, delivery, selfService }

class SalesShellView extends ConsumerStatefulWidget {
  final Widget child;
  const SalesShellView({super.key, required this.child});

  @override
  ConsumerState<SalesShellView> createState() => _SalesShellViewState();
}

class _SalesShellViewState extends ConsumerState<SalesShellView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cashierVm = ref.read(cashierViewModelProvider);
      if (cashierVm.currentRegisterId == null || cashierVm.businessId == null) {
        await cashierVm.init();
      } else {
        await cashierVm.refreshSilently();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    String route;
    try {
      route = GoRouterState.of(context).uri.toString();
    } catch (_) {
      route = '';
    }
    final selected = _selectedFromRoute(route);
    final orderState = ref.watch(currentOrderProvider);
    final cashierVm = ref.watch(cashierViewModelProvider);
    final isCashOpen = cashierVm.lastSession?['status'] == 'open';
    final guardNavigation = _shouldGuardNavigation(route, orderState);
    final sessionCtrl = ref.read(sessionProvider.notifier);

    return Scaffold(
      backgroundColor: SalesTheme.background,
      body: Row(
        children: [
          // 📂 SIDEBAR IZQUIERDO (FIJO – 224px)
          Container(
            width: 224,
            decoration: const BoxDecoration(
              color: SalesTheme.cardBackground,
              border: Border(
                right: BorderSide(color: SalesTheme.border, width: 1),
              ),
            ),
            child: Column(
              children: [
                // Espacio superior o Header
                const SizedBox(height: 24),
                if (!isCashOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.25),
                        ),
                      ),
                      child: const Text(
                        'Caja cerrada: no se pueden abrir ventas',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.red,
                        ),
                      ),
                    ),
                  ),

                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _SalesNavItem(
                        icon: Icons.grid_view_rounded,
                        label: 'Por zona',
                        selected: selected == SalesTab.byZone,
                        locked: !sessionCtrl.hasPermission(
                          'ventas.mesas.acceso',
                        ),
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          AppRoutes.salesReact,
                          guardNavigation,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SalesNavItem(
                        icon: Icons.description_outlined, // FileText
                        label: 'Venta manual',
                        selected: selected == SalesTab.manual,
                        locked: !sessionCtrl.hasPermission(
                          'ventas.mesas.abrir',
                        ),
                        disabled: !isCashOpen,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          Uri(
                            path: AppRoutes.salesReact,
                            queryParameters: const {'mode': 'manual'},
                          ).toString(),
                          guardNavigation,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SalesNavItem(
                        icon: Icons.bolt_rounded, // Zap
                        label: 'Venta rápida',
                        selected: selected == SalesTab.quick,
                        locked: !sessionCtrl.hasPermission(
                          'ventas_rapida.acceso',
                        ),
                        disabled: !isCashOpen,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          Uri(
                            path: AppRoutes.salesReact,
                            queryParameters: const {'mode': 'rapida'},
                          ).toString(),
                          guardNavigation,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SalesNavItem(
                        icon: Icons.local_shipping_outlined, // Truck
                        label: 'Delivery',
                        selected: selected == SalesTab.delivery,
                        locked: !sessionCtrl.hasPermission(
                          'delivery.crear_orden',
                        ),
                        disabled: true,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          Uri(
                            path: AppRoutes.salesReact,
                            queryParameters: const {'mode': 'delivery'},
                          ).toString(),
                          guardNavigation,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SalesNavItem(
                        icon: Icons.smartphone_rounded, // Smartphone
                        label: 'Self service',
                        selected: selected == SalesTab.selfService,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          Uri(
                            path: AppRoutes.salesReact,
                            queryParameters: const {'mode': 'selfservice'},
                          ).toString(),
                          guardNavigation,
                        ),
                        disabled: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ======= CONTENIDO PRINCIPAL =======
          Expanded(
            child: Container(color: SalesTheme.background, child: widget.child),
          ),
        ],
      ),
    );
  }

  SalesTab _selectedFromRoute(String route) {
    final uri = Uri.tryParse(route);
    final mode = uri?.queryParameters['mode']?.toLowerCase().trim();
    if (uri?.path == AppRoutes.salesReact || uri?.path == AppRoutes.sales) {
      switch (mode) {
        case 'manual':
          return SalesTab.manual;
        case 'rapida':
          return SalesTab.quick;
        case 'delivery':
          return SalesTab.delivery;
        case 'selfservice':
          return SalesTab.selfService;
      }
    }
    if (route.contains(AppRoutes.salesManual)) return SalesTab.manual;
    if (route.contains(AppRoutes.salesQuick)) return SalesTab.quick;
    if (route.contains(AppRoutes.salesDelivery)) return SalesTab.delivery;
    if (route.contains(AppRoutes.salesSelfService)) return SalesTab.selfService;
    return SalesTab.byZone;
  }

  Future<void> _handleNavTap(
    BuildContext context,
    WidgetRef ref,
    String currentRoute,
    String targetRoute,
    bool guardNavigation,
  ) async {
    if (currentRoute == targetRoute) return;
    if (guardNavigation) {
      final confirmed = await _showExitSaleDialog(context);
      if (confirmed != true) return;
      await ref.read(currentOrderProvider.notifier).cancelCurrentOrder();
    }
    if (!context.mounted) return;
    context.go(targetRoute);
  }

  bool _shouldGuardNavigation(String route, CurrentOrderState orderState) {
    if (orderState.items.isEmpty) return false;
    final uri = Uri.tryParse(route);
    final mode = uri?.queryParameters['mode']?.toLowerCase().trim();
    final isManual = route.contains(AppRoutes.salesManual);
    final isQuick = route.contains(AppRoutes.salesQuick);
    final isManualByQuery = mode == 'manual';
    final isQuickByQuery = mode == 'rapida';
    return isManual || isQuick || isManualByQuery || isQuickByQuery;
  }

  Future<bool?> _showExitSaleDialog(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: SalesTheme.cardBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          'Cancelar venta',
          style: SalesTheme.textTheme.headlineMedium,
        ),
        content: Text(
          '¿Estás seguro de que deseas salir? Se perderá el progreso actual.',
          style: SalesTheme.textTheme.bodyLarge,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancelar',
              style: TextStyle(color: SalesTheme.mutedForeground),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: SalesTheme.destructive,
            ),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
  }
}

class _SalesNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool disabled;
  final bool locked;

  const _SalesNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.disabled = false,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    final blocked = disabled || locked;
    final bg = selected ? SalesTheme.primary : Colors.transparent;
    final fg = blocked
        ? SalesTheme.mutedForeground
        : (selected ? SalesTheme.primaryForeground : SalesTheme.foreground);
    // Opacidad para items deshabilitados
    final double opacity = blocked ? 0.55 : 1.0;

    return Opacity(
      opacity: opacity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: blocked ? null : onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: SalesTheme.primary.withValues(alpha: 0.05),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(icon, color: fg, size: 20),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: SalesTheme.textTheme.bodyMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w500, // Medium
                    fontSize: 14,
                  ),
                ),
                if (locked) ...[
                  const Spacer(),
                  Icon(Icons.lock_outline, size: 16, color: fg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
