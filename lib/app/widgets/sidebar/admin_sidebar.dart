import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

// importa tu clase AppRoutes
import '../../router/routes.dart';

class AdminSidebar extends StatelessWidget {
  final double width;
  const AdminSidebar({super.key, this.width = 96});

  List<SidebarItem> get _items => [
    SidebarItem(
      label: 'Dashboard',
      icon: Icons.home_rounded,
      route: AppRoutes.dashboard,
    ),
    SidebarItem(
      label: 'Ventas',
      icon: Icons.point_of_sale_rounded,
      route: AppRoutes.sales,
    ),
    SidebarItem(
      label: 'Caja',
      icon: Icons.attach_money_rounded,
      route: AppRoutes.cashier,
    ),
    SidebarItem(
      label: 'Cocina',
      icon: Icons.kitchen_rounded,
      route: AppRoutes.kitchen,
    ),
    SidebarItem(
      label: 'Mesas',
      icon: Icons.table_restaurant_rounded,
      route: AppRoutes.reservations,
    ),
    SidebarItem(
      label: 'Clientes',
      icon: Icons.people_alt_rounded,
      route: AppRoutes.customers,
    ),
    SidebarItem(
      label: 'Productos',
      icon: Icons.shopping_bag_rounded,
      route: AppRoutes.products,
    ),
    SidebarItem(
      label: 'Reportes',
      icon: Icons.pie_chart_rounded,
      route: AppRoutes.reports,
    ),
    SidebarItem(
      label: 'Mas Opciones',
      icon: Icons.settings,
      route: AppRoutes.settings,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).uri.toString();
    return Container(
      width: width,
      color: const Color(0xFFF7F7F7),
      child: SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 16),
          itemCount: _items.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final it = _items[i];
            final active =
                loc == it.route ||
                (it.route != '/' && loc.startsWith(it.route));
            return _Tile(
              item: it,
              active: active,
              onTap: () => context.go(it.route),
            );
          },
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final SidebarItem item;
  final bool active;
  final VoidCallback onTap;
  const _Tile({required this.item, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? const Color(0x80F7941A) : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                item.icon,
                color: active ? const Color(0xFFF7941A) : Colors.grey[500],
              ),
              const SizedBox(height: 6),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? const Color(0xFFF7941A) : Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SidebarItem {
  final String label;
  final IconData icon;
  final String route;
  const SidebarItem({
    required this.label,
    required this.icon,
    required this.route,
  });
}
