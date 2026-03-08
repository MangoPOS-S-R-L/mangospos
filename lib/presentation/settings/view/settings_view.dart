import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/services/session/session_controller.dart';

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key, this.businessId = ''});

  final String businessId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        titleSpacing: 12,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Más Ajustes',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            Text(
              'Configuración completa del sistema MangoPOS',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          _BusinessSummaryCard(
            businessName: ref.watch(sessionProvider).activeBusinessName,
          ),
          const SizedBox(height: 18),
          ..._sections(context),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    return [
      _SettingsSection(
        title: 'Punto de Venta',
        items: [
          _SettingsOption(
            title: 'Venta Rápida',
            subtitle: 'Ventas express sin mesa',
            icon: Icons.flash_on_rounded,
            color: const Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Venta Manual',
            subtitle: 'Asignar manual de pedidos y precios',
            icon: Icons.edit_rounded,
            color: const Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Delivery',
            subtitle: 'Configurar ordenes de entrega a domicilio',
            icon: Icons.delivery_dining_rounded,
            color: const Color(0xFFFFF0D9),
          ),
          _SettingsOption(
            title: 'Self Service',
            subtitle: 'Modo autoservicio para el cliente',
            icon: Icons.self_improvement_rounded,
            color: const Color(0xFFE6F7EE),
          ),
          _SettingsOption(
            title: 'Salones y Mesas',
            subtitle: 'Gestión de zonas y mesas del local',
            icon: Icons.grid_view_rounded,
            color: const Color(0xFFF0F0F0),
            route: AppRoutes.settingsZonesTables,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Caja',
        items: const [
          _SettingsOption(
            title: 'Apertura y Cierre',
            subtitle: 'Flujos de apertura y cierre de caja',
            icon: Icons.point_of_sale_rounded,
            color: Color(0xFFE6F7EE),
          ),
          _SettingsOption(
            title: 'Historial de Venta',
            subtitle: 'Consulta de ventas realizadas',
            icon: Icons.receipt_long_rounded,
            color: Color(0xFFF1F1F1),
          ),
          _SettingsOption(
            title: 'Registro de Ingresos y Egresos',
            subtitle: 'Movimientos de efectivo en caja',
            icon: Icons.attach_money_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Gestión de Cierres de Caja',
            subtitle: 'Administración de cierres y arqueos',
            icon: Icons.lock_rounded,
            color: Color(0xFFFFEFE3),
          ),
          _SettingsOption(
            title: 'Gestión de Notas de Crédito',
            subtitle: 'Anulaciones y devoluciones',
            icon: Icons.note_alt_rounded,
            color: Color(0xFFFFE6E6),
          ),
          _SettingsOption(
            title: 'Monitor de Ventas',
            subtitle: 'Visualización en tiempo real',
            icon: Icons.monitor_rounded,
            color: Color(0xFFF3F3F3),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Gestión de Productos',
        items: [
          _SettingsOption(
            title: 'Productos y Categorias',
            subtitle: 'Catálogo de productos',
            icon: Icons.inventory_2_rounded,
            color: const Color(0xFFFFE6D5),
            route: AppRoutes.products,
          ),
          _SettingsOption(
            title: 'Modificadores',
            subtitle: 'Extras y variantes de productos',
            icon: Icons.tune_rounded,
            color: const Color(0xFFEAF0FF),
            route: AppRoutes.menuModifiers,
          ),
          _SettingsOption(
            title: 'Combos',
            subtitle: 'Paquetes y ofertas especiales',
            icon: Icons.widgets_rounded,
            color: const Color(0xFFE6F7EE),
          ),
          _SettingsOption(
            title: 'Menu',
            subtitle: 'Configuración de menús',
            icon: Icons.menu_book_rounded,
            color: const Color(0xFFFFF0D9),
            route: AppRoutes.menuMenus.replaceFirst(':businessId', businessId),
          ),
          _SettingsOption(
            title: 'Recetas',
            subtitle: 'Ingredientes y costos de recetas',
            icon: Icons.receipt_rounded,
            color: const Color(0xFFF1F1F1),
            route: AppRoutes.menuRecipes,
          ),
          _SettingsOption(
            title: 'Insumos',
            subtitle: 'Materias primas e ingredientes',
            icon: Icons.science_rounded,
            color: const Color(0xFFFFEDED),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Comandas y Precuentas',
        items: const [
          _SettingsOption(
            title: 'Configuración de Comandas',
            subtitle: 'Formato y comportamiento de comandas',
            icon: Icons.list_alt_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Configuración de Precuentas',
            subtitle: 'Formato de precuentas',
            icon: Icons.description_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Turnos',
            subtitle: 'Gestión de turnos de trabajo',
            icon: Icons.schedule_rounded,
            color: Color(0xFFE6F7EE),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Ajustes Generales',
        items: [
          _SettingsOption(
            title: 'Usuarios',
            subtitle: 'Gestión de usuarios del sistema',
            icon: Icons.person_outline_rounded,
            color: const Color(0xFFFFE6D5),
            route: AppRoutes.settingsUsers,
          ),
          const _SettingsOption(
            title: 'Clientes',
            subtitle: 'Gestión de clientes y contactos',
            icon: Icons.people_alt_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.customers,
          ),
          const _SettingsOption(
            title: 'Cajas',
            subtitle: 'Configuración de puntos de venta',
            icon: Icons.point_of_sale_rounded,
            color: Color(0xFFE6F7EE),
          ),
          const _SettingsOption(
            title: 'Impuestos',
            subtitle: 'ITBIS y configuración fiscal',
            icon: Icons.percent_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.settingsTaxes,
          ),
          const _SettingsOption(
            title: 'Monedas',
            subtitle: 'Configuración de divisas',
            icon: Icons.monetization_on_rounded,
            color: Color(0xFFEAF0FF),
          ),
          const _SettingsOption(
            title: 'Configuraciones Regionales',
            subtitle: 'Idioma, zona horaria y formato',
            icon: Icons.public_rounded,
            color: Color(0xFFF1F1F1),
          ),
          const _SettingsOption(
            title: 'Sucursales',
            subtitle: 'Gestión de múltiples locales',
            icon: Icons.store_mall_directory_rounded,
            color: Color(0xFFFFEDED),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Almacenes e Inventario',
        items: const [
          _SettingsOption(
            title: 'Kardex por Sucursal',
            subtitle: 'Historial de movimientos por ubicación',
            icon: Icons.list_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.inventoryKardex,
          ),
          _SettingsOption(
            title: 'Registro de Salida de Inventario',
            subtitle: 'Control de salidas de stock',
            icon: Icons.logout_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.inventoryOutflow,
          ),
          _SettingsOption(
            title: 'Mover Inventario entre Almacenes',
            subtitle: 'Transferencias entre almacenes',
            icon: Icons.swap_horiz_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Cuadre de Stock',
            subtitle: 'Ajustes de inventario',
            icon: Icons.inventory_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.inventoryReconciliation,
          ),
          _SettingsOption(
            title: 'Mermas o Perecederos',
            subtitle: 'Registro de pérdidas',
            icon: Icons.warning_rounded,
            color: Color(0xFFFFEDED),
          ),
          _SettingsOption(
            title: 'Requerimientos',
            subtitle: 'Solicitudes de stock',
            icon: Icons.assignment_rounded,
            color: Color(0xFFF1F1F1),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Compras',
        items: const [
          _SettingsOption(
            title: 'Lista de Compras',
            subtitle: 'Listado de pedidos a proveedores',
            icon: Icons.list_alt_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.purchasesList,
          ),
          _SettingsOption(
            title: 'Registro de Compras',
            subtitle: 'Historial de compras realizadas',
            icon: Icons.receipt_long_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.purchasesRegister,
          ),
          _SettingsOption(
            title: 'Gestión de Proveedores',
            subtitle: 'Catalogo de proveedores',
            icon: Icons.group_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.purchasesList,
          ),
          _SettingsOption(
            title: 'Crédito de Compras a Proveedores',
            subtitle: 'Cuentas por pagar',
            icon: Icons.credit_score_rounded,
            color: Color(0xFFFFF0D9),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Gestión de Impresión',
        items: [
          _SettingsOption(
            title: 'Impresoras',
            subtitle: 'Configurar y agregar impresoras',
            icon: Icons.print_rounded,
            color: const Color(0xFFFFE6D5),
            route: AppRoutes.printingBase,
          ),
          _SettingsOption(
            title: 'Asignar Impresión de Productos',
            subtitle: 'Productos por impresora',
            icon: Icons.print_rounded,
            color: const Color(0xFFEAF0FF),
            route: AppRoutes.printingAreas,
          ),
          _SettingsOption(
            title: 'Asignar Impresión de Comprobantes',
            subtitle: 'Comprobantes por impresora',
            icon: Icons.print_rounded,
            color: const Color(0xFFE6F7EE),
            route: AppRoutes.printingPrinters,
          ),
          _SettingsOption(
            title: 'Asignar Impresión de Comandas',
            subtitle: 'Comandas por impresora de cocina',
            icon: Icons.print_rounded,
            color: const Color(0xFFFFF0D9),
            route: AppRoutes.printingAreas,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Pagos del Sistema',
        items: const [
          _SettingsOption(
            title: 'Tarjeta',
            subtitle: 'Configuración de pagos con tarjeta',
            icon: Icons.credit_card_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Transferencias',
            subtitle: 'Pagos por transferencia bancaria',
            icon: Icons.account_balance_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Información Histórica de Pagos',
            subtitle: 'Historial de transacciones',
            icon: Icons.history_rounded,
            color: Color(0xFFE6F7EE),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Crédito',
        items: const [
          _SettingsOption(
            title: 'Venta a Crédito',
            subtitle: 'Configuración de ventas a crédito',
            icon: Icons.payments_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Gestión de Créditos',
            subtitle: 'Administración de cuentas por cobrar',
            icon: Icons.account_balance_wallet_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Créditos de Clientes',
            subtitle: 'Créditos otorgados a clientes',
            icon: Icons.person_rounded,
            color: Color(0xFFE6F7EE),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Finanzas',
        items: const [
          _SettingsOption(
            title: 'Gestión de Costos',
            subtitle: 'Control de costos y gastos',
            icon: Icons.request_quote_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Gestión de Metas',
            subtitle: 'Objetivos y metas del negocio',
            icon: Icons.flag_rounded,
            color: Color(0xFFE6F7EE),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Fidelizacion',
        items: const [
          _SettingsOption(
            title: 'Tarjeta de Fidelidad',
            subtitle: 'Programa de puntos y recompensas',
            icon: Icons.card_membership_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Niveles de Membresías',
            subtitle: 'Categorias de clientes VIP',
            icon: Icons.star_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Promociones y Descuentos',
            subtitle: 'Ofertas y promociones activas',
            icon: Icons.local_offer_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Gestión de Cupones',
            subtitle: 'Códigos promocionales',
            icon: Icons.confirmation_number_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Gift Cards y Bonos',
            subtitle: 'Tarjetas de regalo',
            icon: Icons.card_giftcard_rounded,
            color: Color(0xFFFFEDED),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Puntos de Recompensa',
            subtitle: 'Sistema de puntos acumulables',
            icon: Icons.workspace_premium_rounded,
            color: Color(0xFFF1F1F1),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Historial de Fidelidad',
            subtitle: 'Registro de actividad de clientes',
            icon: Icons.history_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.promosCenter,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Sistema',
        items: const [
          _SettingsOption(
            title: 'Opciones del Sistema',
            subtitle: 'Configuración general del sistema',
            icon: Icons.settings_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Opciones de APP MangoPOS',
            subtitle: 'Configuración de la aplicación móvil',
            icon: Icons.phone_android_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Información del Restaurante',
            subtitle: 'Datos del negocio',
            icon: Icons.store_rounded,
            color: Color(0xFFE6F7EE),
          ),
          _SettingsOption(
            title: 'Gestión de Sucursales',
            subtitle: 'Administración multisucursal',
            icon: Icons.apartment_rounded,
            color: Color(0xFFFFF0D9),
          ),
          _SettingsOption(
            title: 'Actualizaciones',
            subtitle: 'Versiones y actualizaciones',
            icon: Icons.system_update_alt_rounded,
            color: Color(0xFFF1F1F1),
          ),
          _SettingsOption(
            title: 'Integración con Marketing',
            subtitle: 'Conexión con herramientas de marketing',
            icon: Icons.campaign_rounded,
            color: Color(0xFFFFEDED),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Comprobantes de Ventas',
        items: const [
          _SettingsOption(
            title: 'Configuración de Crédito Fiscal',
            subtitle: 'NCF y comprobantes fiscales DGII',
            icon: Icons.receipt_long_rounded,
            color: Color(0xFFFFE6D5),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Informes',
        items: const [
          _SettingsOption(
            title: 'Informe de Ventas',
            subtitle: 'Reportes de ventas detallados',
            icon: Icons.bar_chart_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Informe de Compras',
            subtitle: 'Reportes de compras',
            icon: Icons.receipt_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Informe de Finanzas',
            subtitle: 'Reportes financieros',
            icon: Icons.trending_up_rounded,
            color: Color(0xFFE6F7EE),
          ),
          _SettingsOption(
            title: 'Informe de Inventario',
            subtitle: 'Reportes de stock',
            icon: Icons.inventory_2_rounded,
            color: Color(0xFFFFF0D9),
          ),
          _SettingsOption(
            title: 'Informe de Asistencia',
            subtitle: 'Reportes del personal',
            icon: Icons.groups_rounded,
            color: Color(0xFFF1F1F1),
          ),
          _SettingsOption(
            title: 'Indicadores Gráficos',
            subtitle: 'Dashboard de indicadores',
            icon: Icons.analytics_rounded,
            color: Color(0xFFFFEDED),
          ),
        ],
      ),
    ].expand((section) sync* {
      yield section;
      yield const SizedBox(height: 20);
    }).toList();
  }
}

class _BusinessSummaryCard extends StatelessWidget {
  const _BusinessSummaryCard({this.businessName});

  final String? businessName;

  @override
  Widget build(BuildContext context) {
    final resolvedBusinessName = businessName?.trim().isNotEmpty == true
        ? businessName!.trim()
        : 'Negocio no configurado';
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: MangoColors.primaryOrange,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.storefront_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resolvedBusinessName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'Configuracion general del negocio',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1, color: MangoColors.cardBorder),
          const SizedBox(height: 12),
          Row(
            children: [
              _MiniStat(
                label: 'NCF Disponibles',
                value: '2,450',
                color: MangoColors.primaryOrange,
                icon: Icons.receipt_outlined,
              ),
              const SizedBox(width: 12),
              _MiniStat(
                label: 'CF',
                value: 'Pendiente',
                color: const Color(0xFFF97316),
                icon: Icons.access_time_rounded,
              ),
              const SizedBox(width: 12),
              _MiniStat(
                label: 'Impresoras',
                value: '3 activas',
                color: const Color(0xFF22C55E),
                icon: Icons.print_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontSize: 12,
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

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<_SettingsOption> items;

  const _SettingsSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            int crossAxisCount = 4;
            if (width < 1200) crossAxisCount = 3;
            if (width < 900) crossAxisCount = 2;
            if (width < 560) crossAxisCount = 1;
            return GridView.builder(
              itemCount: items.length,
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 3.2,
              ),
              itemBuilder: (context, index) {
                return _SettingsCardItem(data: items[index]);
              },
            );
          },
        ),
      ],
    );
  }
}

class _SettingsOption {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String? route;

  const _SettingsOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.route,
  });
}

class _SettingsCardItem extends StatelessWidget {
  final _SettingsOption data;
  const _SettingsCardItem({required this.data});

  @override
  Widget build(BuildContext context) {
    final isLink = data.route != null;

    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isLink ? MangoColors.white : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isLink ? MangoColors.cardBorder : Colors.transparent,
        ),
        boxShadow: isLink
            ? const [
                BoxShadow(
                  color: Color(0x12000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Opacity(
        opacity: isLink ? 1.0 : 0.6,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isLink ? data.color : Colors.grey[300],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                data.icon,
                size: 18,
                color: isLink ? MangoColors.darkGray : Colors.grey[600],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    data.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isLink ? null : Colors.grey[700],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: isLink ? Colors.grey[600] : Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
            if (isLink)
              const Icon(Icons.chevron_right, size: 18, color: Colors.black54),
          ],
        ),
      ),
    );

    if (!isLink) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.go(data.route!),
      child: card,
    );
  }
}
