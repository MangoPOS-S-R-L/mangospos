// lib/presentation/sales/view/sales_shell_view.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';

enum SalesTab { byZone, manual, quick, delivery, selfService }

class SalesShellView extends ConsumerWidget {
  final Widget child;
  const SalesShellView({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String route;
    try {
      route = GoRouterState.of(context).uri.toString();
    } catch (_) {
      route = '';
    }
    final selected = _selectedFromRoute(route);
    final orderState = ref.watch(currentOrderProvider);
    final guardNavigation = _shouldGuardNavigation(route, orderState);

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

                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _SalesNavItem(
                        icon: Icons.grid_view_rounded,
                        label: 'Por zona',
                        selected: selected == SalesTab.byZone,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          AppRoutes.salesByZone,
                          guardNavigation,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SalesNavItem(
                        icon: Icons.description_outlined, // FileText
                        label: 'Venta manual',
                        selected: selected == SalesTab.manual,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          AppRoutes.salesManual,
                          guardNavigation,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SalesNavItem(
                        icon: Icons.bolt_rounded, // Zap
                        label: 'Venta rápida',
                        selected: selected == SalesTab.quick,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          AppRoutes.salesQuick,
                          guardNavigation,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _SalesNavItem(
                        icon: Icons.local_shipping_outlined, // Truck
                        label: 'Delivery',
                        selected: selected == SalesTab.delivery,
                        onTap: () => _handleNavTap(
                          context,
                          ref,
                          route,
                          AppRoutes.salesDelivery,
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
                          AppRoutes.salesSelfService,
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
            child: Container(color: SalesTheme.background, child: child),
          ),
        ],
      ),
    );
  }

  SalesTab _selectedFromRoute(String route) {
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
    final isManual = route.contains(AppRoutes.salesManual);
    final isQuick = route.contains(AppRoutes.salesQuick);
    return isManual || isQuick;
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

  const _SalesNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? SalesTheme.primary : Colors.transparent;
    final fg = selected ? SalesTheme.primaryForeground : SalesTheme.foreground;
    // Opacidad para items deshabilitados
    final double opacity = disabled ? 0.5 : 1.0;

    return Opacity(
      opacity: opacity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: SalesTheme.primary.withOpacity(0.05),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
