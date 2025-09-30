// lib/presentation/sales/view/sales_shell_view.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

enum SalesTab { byZone, manual, quick, delivery, selfService }

class SalesShellView extends StatelessWidget {
  final Widget child;
  const SalesShellView({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final route = GoRouterState.of(context).uri.toString();
    final selected = _selectedFromRoute(route);

    return Scaffold(
      backgroundColor: Colors.white,
      body: Row(
        children: [
          // ======= SUBMENÚ COMPACTO =======
          Material(
            color: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 90, maxWidth: 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Encabezado con altura fija de 72
                  Container(
                    height: 58,
                    alignment: Alignment.center,
                    child: Text(
                      'VENTAS',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .3,
                      ),
                    ),
                  ),
                  const _SideDivider(),

                  // Opciones
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 12,
                      ),
                      children: [
                        _SalesNavItemVertical(
                          icon: Icons.grid_view_rounded,
                          label: 'Por Zona',
                          selected: selected == SalesTab.byZone,
                          onTap: () => context.go(AppRoutes.salesByZone),
                        ),
                        _SalesNavItemVertical(
                          icon: Icons.handshake_outlined,
                          label: 'Manual',
                          selected: selected == SalesTab.manual,
                          onTap: () => context.go(AppRoutes.salesManual),
                        ),
                        _SalesNavItemVertical(
                          icon: Icons.speed_outlined,
                          label: 'Rápida',
                          selected: selected == SalesTab.quick,
                          onTap: () => context.go(AppRoutes.salesQuick),
                        ),
                        _SalesNavItemVertical(
                          icon: Icons.delivery_dining_outlined,
                          label: 'Delivery',
                          selected: selected == SalesTab.delivery,
                          onTap: () => context.go(AppRoutes.salesDelivery),
                        ),
                        _SalesNavItemVertical(
                          icon: Icons.table_bar_outlined,
                          label: 'Self',
                          selected: selected == SalesTab.selfService,
                          onTap: () => context.go(AppRoutes.salesSelfService),
                          disabled: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Divider vertical
          const _VerticalSeparator(),

          // ======= CONTENIDO =======
          Expanded(
            child: Container(color: Colors.white, child: child),
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
}

class _SideDivider extends StatelessWidget {
  const _SideDivider();
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, thickness: 1, color: Colors.grey.shade200);
}

class _VerticalSeparator extends StatelessWidget {
  const _VerticalSeparator();
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: double.infinity, color: Colors.grey.shade200);
}

/// Ítem de navegación compacto
class _SalesNavItemVertical extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool disabled;

  const _SalesNavItemVertical({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    const orange = MangoColors.primaryOrange;
    const baseFg = MangoColors.darkGray;

    final bg = selected ? const Color(0xFFFFF3E5) : Colors.transparent;
    final fg = selected ? orange : baseFg;
    final border = selected ? Border.all(color: orange, width: 2) : null;
    final opacity = disabled ? .38 : 1.0;

    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: InkWell(
          onTap: disabled ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          splashColor: orange.withOpacity(.1),
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Ink(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: fg, size: 26),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
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
