import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:mangopos/app/widgets/sidebar/sidebar_item.dart';

// importa tu clase AppRoutes
import '../../router/routes.dart';

class AdminSidebar extends StatelessWidget {
  final double width;
  const AdminSidebar({super.key, this.width = 96});

  List<SidebarItem> get _mainItems => [
    SidebarItem(
      label: 'Dashboard',
      icon: SvgPicture.asset(
        'assets/icons/dashboard.svg',
        width: 24,
        height: 24,
      ),
      route: AppRoutes.dashboard,
    ),
    SidebarItem(
      label: 'Ventas',
      icon: SvgPicture.asset(
        'assets/icons/ventas_principal.svg',
        width: 26,
        height: 26,
      ),
      route: AppRoutes.sales,
    ),
    SidebarItem(
      label: 'Caja',
      icon: SvgPicture.asset(
        'assets/icons/caja_principal.svg',
        width: 26,
        height: 26,
      ),
      route: AppRoutes.cashier,
    ),
    SidebarItem(
      label: 'Cocina',
      icon: SvgPicture.asset(
        'assets/icons/cocina_principal.svg',
        width: 26,
        height: 26,
      ),
      route: AppRoutes.kitchen,
    ),
    SidebarItem(
      label: 'Clientes',
      icon: SvgPicture.asset(
        'assets/icons/clientes_principal.svg',
        width: 26,
        height: 26,
      ),
      route: AppRoutes.customers,
    ),
    SidebarItem(
      label: 'Productos',
      icon: SvgPicture.asset(
        'assets/icons/productos_principal.svg',
        width: 26,
        height: 26,
      ),
      route: AppRoutes.products,
    ),
    SidebarItem(
      label: 'Reportes',
      icon: SvgPicture.asset(
        'assets/icons/reportes_principal.svg',
        width: 26,
        height: 26,
      ),
      route: AppRoutes.reports,
    ),
  ];

  SidebarItem get _settingsItem => SidebarItem(
    label: 'Mas Ajustes',
    icon: SvgPicture.asset(
      'assets/icons/masajustes.svg',
      width: 26,
      height: 26,
    ),
    route: AppRoutes.settings,
  );

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).uri.toString();
    return Container(
      width: width,
      color: Colors.white, // Cambiado a blanco
      child: SafeArea(
        child: Column(
          children: [
            // Items principales
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 16),
                itemCount: _mainItems.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final it = _mainItems[i];
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

            // Separador visual
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              height: 1,
              color: Colors.grey[300],
            ),

            // Item de configuración al final
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Builder(
                builder: (context) {
                  final it = _settingsItem;
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
          ],
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

  // Método helper para manejar ambos tipos de iconos
  Widget _buildIcon() {
    final color = active ? const Color(0xFFF7941A) : Colors.grey[500]!;

    if (item.icon is IconData) {
      return Icon(item.icon as IconData, color: color);
    } else if (item.icon is Widget) {
      return ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        child: item.icon as Widget,
      );
    }
    return Icon(Icons.error, color: color); // fallback
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            color: active ? const Color(0xFFF7F7F7) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? const Color(0x80F7941A) : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildIcon(),
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
