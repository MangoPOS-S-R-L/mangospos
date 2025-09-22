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
      backgroundColor: MangoColors.sidebarBg,
      body: Row(
        children: [
          // ---- Sidebar ----
          Container(
            width: 220,
            color: MangoColors.sidebarBg,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ListView(
              children: [
                const _SectionTitle('VENTAS'),
                const SizedBox(height: 12),
                _BackButton(onPressed: () => context.go(AppRoutes.dashboard)),
                const SizedBox(height: 12),
                const Divider(),

                const SizedBox(height: 12),
                _SalesNavItem(
                  icon: Icons.grid_view_rounded,
                  label: 'Por salón',
                  selected: selected == SalesTab.byZone,
                  onTap: () => context.go(AppRoutes.salesByZone),
                ),
                const SizedBox(height: 20),
                _SalesNavItem(
                  icon: Icons.handshake_outlined,
                  label: 'Venta manual',
                  selected: selected == SalesTab.manual,
                  onTap: () => context.go(AppRoutes.salesManual),
                ),
                const SizedBox(height: 20),
                _SalesNavItem(
                  icon: Icons.speed_outlined,
                  label: 'Venta rápida',
                  selected: selected == SalesTab.quick,
                  onTap: () => context.go(AppRoutes.salesQuick),
                ),
                const SizedBox(height: 20),
                _SalesNavItem(
                  icon: Icons.delivery_dining_outlined,
                  label: 'Delivery express',
                  selected: selected == SalesTab.delivery,
                  onTap: () => context.go(AppRoutes.salesDelivery),
                ),
                const SizedBox(height: 20),
                _SalesNavItem(
                  icon: Icons.table_bar_outlined,
                  label: 'Self-service',
                  selected: selected == SalesTab.selfService,
                  onTap: () => context.go(AppRoutes.salesSelfService),
                  disabled: true, // aún no disponible
                ),
              ],
            ),
          ),

          // ---- Contenido ----
          Expanded(
            child: Container(
              color: Colors.white,
              child: child,
            ),
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

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: const Color(0xFF3B82F6), // azul como en tu referencia
            letterSpacing: .3,
            fontWeight: FontWeight.w800,
          ),
    );
  }
}

class _BackButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _BackButton({required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        decoration: BoxDecoration(
          color: const Color(0xFFE9F0FF),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
        child: Row(
          children: const [
            CircleAvatar(
              radius: 18,
              backgroundColor: Color(0xFF3B82F6),
              child: Icon(Icons.arrow_back, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Regresar', style: TextStyle(color: Color(0xFF3B82F6), fontWeight: FontWeight.w600)),
          ],
        ),
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
    final bg = selected ? const Color(0xFF3B82F6) : Colors.white;
    final fg = selected ? Colors.white : MangoColors.darkGray;
    final opacity = disabled ? .35 : 1.0;

    return Opacity(
      opacity: opacity,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE6E6E6)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
          child: Row(
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
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
