import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:go_router/go_router.dart';
import '../../theme/mango_colors.dart';
import '../../router/routes.dart';

class SidebarItem {
  final String label;
  final String route;
  final String asset; // svg path
  final double iconSize;
  const SidebarItem({
    required this.label,
    required this.route,
    required this.asset,
    this.iconSize = 26,
  });
}

class AdminSidebar extends StatelessWidget {
  final bool expanded;
  final double widthExpanded;
  final double widthCollapsed;

  const AdminSidebar({
    super.key,
    required this.expanded,
    this.widthExpanded = 140,
    this.widthCollapsed = 88,
  });

  List<SidebarItem> get _mainItems => const [
    SidebarItem(
      label: 'Dashboard',
      route: AppRoutes.dashboard,
      asset: 'assets/icons/dashboard.svg',
      iconSize: 24,
    ),
    SidebarItem(
      label: 'Ventas',
      route: AppRoutes.sales,
      asset: 'assets/icons/ventas_principal.svg',
    ),
    SidebarItem(
      label: 'Caja',
      route: AppRoutes.cashier,
      asset: 'assets/icons/caja_principal.svg',
    ),
    SidebarItem(
      label: 'Cocina',
      route: AppRoutes.kitchen,
      asset: 'assets/icons/cocina_principal.svg',
    ),
    SidebarItem(
      label: 'Clientes',
      route: AppRoutes.customers,
      asset: 'assets/icons/clientes_principal.svg',
    ),
    SidebarItem(
      label: 'Productos',
      route: AppRoutes.products,
      asset: 'assets/icons/productos_principal.svg',
    ),
    SidebarItem(
      label: 'Reportes',
      route: AppRoutes.reports,
      asset: 'assets/icons/reportes_principal.svg',
    ),
  ];

  SidebarItem get _settingsItem => const SidebarItem(
    label: 'Mas Ajustes',
    route: AppRoutes.settings,
    asset: 'assets/icons/masajustes.svg',
  );

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).uri.toString();
    final width = expanded ? widthExpanded : widthCollapsed;

    return Container(
      width: width,
      color: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
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
                    expanded: expanded,
                    onTap: () => context.go(it.route),
                  );
                },
              ),
            ),

            // Separador + título del grupo “Más Ajustes”
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: expanded
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  Container(height: 1, color: Colors.grey[300]),
                  const SizedBox(height: 12),
                  if (expanded)
                    Text(
                      'Mas Ajustes',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[700],
                      ),
                    ),
                ],
              ),
            ),

            // Item de ajustes
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Builder(
                builder: (context) {
                  final it = _settingsItem;
                  final active =
                      loc == it.route ||
                      (it.route != '/' && loc.startsWith(it.route));
                  return _Tile(
                    item: it,
                    active: active,
                    expanded: expanded,
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

class _Tile extends StatefulWidget {
  final SidebarItem item;
  final bool active;
  final bool expanded;
  final VoidCallback onTap;
  const _Tile({
    required this.item,
    required this.active,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final expanded = widget.expanded;

    final tileBg = active
        ? const Color(0xFFF7F7F7)
        : _hover
        ? const Color(0xFFF9F9F9)
        : Colors.transparent;

    final borderColor = active ? const Color(0x80F97316) : Colors.transparent;
    final labelColor = active ? MangoColors.primaryOrange : Colors.grey[700]!;
    final iconColor = active ? MangoColors.primaryOrange : Colors.grey[500]!;

    final content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Icono SVG con tinte
        ColorFiltered(
          colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
          child: SvgPicture.asset(
            widget.item.asset,
            width: widget.item.iconSize,
            height: widget.item.iconSize,
          ),
        ),
        const SizedBox(height: 6),
        if (expanded)
          Text(
            widget.item.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: labelColor,
              height: 1.1,
            ),
          ),
      ],
    );

    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 88, // alto tipo “tile” grande como tu mock
          decoration: BoxDecoration(
            color: tileBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 2),
          ),
          child: content,
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: expanded
          ? tile
          : Tooltip(
              message: widget.item.label,
              waitDuration: const Duration(milliseconds: 300),
              child: tile,
            ),
    );
  }
}
