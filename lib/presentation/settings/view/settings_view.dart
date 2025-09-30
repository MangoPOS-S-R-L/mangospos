// lib/presentation/settings/settings_view.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key, this.businessId = ''});

  /// Pasamos el businessId para componer las rutas del módulo menú
  final String businessId;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: MangoColors.white,
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: .4,
        title: Row(
          children: [
            const Icon(Icons.settings_outlined, size: 22),
            const SizedBox(width: 10),
            Text(
              'Ajustes',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          // ---------------- CARD: Gestión de productos ----------------
          SettingsCard(
            title: 'Gestión de productos',
            icon: Icons.restaurant_menu,
            items: [
              SettingsItem(
                title: 'Menús',
                route: AppRoutes.menuMenus.replaceFirst(
                  ':businessId',
                  businessId,
                ),
                icon: Icons.table_restaurant_outlined,
              ),
              SettingsItem(
                title: 'Elementos de menú',
                route: AppRoutes.menuItems.replaceFirst(
                  ':businessId',
                  businessId,
                ),
                icon: Icons.local_dining_outlined,
              ),
              SettingsItem(
                title: 'Categorías de artículos',
                route: AppRoutes.menuCategories.replaceFirst(
                  ':businessId',
                  businessId,
                ),
                icon: Icons.folder_outlined,
              ),
              SettingsItem(
                title: 'Grupos de modificadores',
                route: AppRoutes.menuModifierGroups.replaceFirst(
                  ':businessId',
                  businessId,
                ),
                icon: Icons.group_work_outlined,
              ),
              SettingsItem(
                title: 'Modificadores de artículo',
                route: AppRoutes.menuModifiers.replaceFirst(
                  ':businessId',
                  businessId,
                ),
                icon: Icons.tune_outlined,
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ---------------- CARD: Ajustes del sistema (tu lista anterior) ------------
          SettingsCard(
            title: 'Ajustes del sistema',
            icon: Icons.settings_suggest_outlined,
            items: const [
              SettingsItem(title: 'Usuarios.', icon: Icons.person_2_outlined),
              SettingsItem(
                title: 'Salones y mesas.',
                route: AppRoutes.settingsZonesTables,
                icon: Icons.grid_view_rounded,
              ),
              SettingsItem(title: 'Cajas.', icon: Icons.point_of_sale_outlined),
              SettingsItem(
                title: 'Impuestos.',
                route: AppRoutes.settingsTaxes,
                icon: Icons.percent_outlined,
              ),

              SettingsItem(
                title: 'Tarjetas.',
                icon: Icons.credit_card_outlined,
              ),
              SettingsItem(title: 'Turnos.', icon: Icons.schedule_outlined),
              SettingsItem(title: 'Monedas.', icon: Icons.attach_money),
              SettingsItem(
                title: 'Comprobantes.',
                icon: Icons.receipt_long_outlined,
              ),
              SettingsItem(
                title: 'Transferencias.',
                icon: Icons.swap_horiz_outlined,
              ),
              SettingsItem(
                title: 'Opciones del sistema.',
                icon: Icons.settings_suggest_outlined,
              ),
              SettingsItem(
                title: 'Opciones APP Quipu.',
                icon: Icons.phone_android_outlined,
              ),
              SettingsItem(
                title: 'Configuraciones regionales.',
                icon: Icons.public_outlined,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ================== Widgets reutilizables ==================

class SettingsItem {
  final String title;
  final String? route;
  final IconData? icon;
  final bool selected;
  const SettingsItem({
    required this.title,
    this.route,
    this.icon,
    this.selected = false,
  });
}

class SettingsCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<SettingsItem> items;

  const SettingsCard({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: MangoColors.primaryOrange),
              const SizedBox(width: 8),
              Text(
                title,
                style: text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: MangoColors.cardBorder),
          const SizedBox(height: 8),
          ...items.map((e) => _SettingsRow(data: e)).toList(),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final SettingsItem data;
  const _SettingsRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final isLink = data.route != null;

    final row = Container(
      decoration: BoxDecoration(
        color: data.selected
            ? const Color(0xFFFFF3E6)
            : Colors.transparent, // tono mango muy suave
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      child: Row(
        children: [
          const Text('•', style: TextStyle(fontSize: 22, height: .9)),
          const SizedBox(width: 10),
          if (data.icon != null) ...[
            Icon(data.icon, size: 18, color: MangoColors.darkGray),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              data.title,
              style: TextStyle(
                fontSize: 18,
                color: isLink ? MangoColors.darkGray : Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (isLink)
            const Icon(Icons.chevron_right, size: 20, color: Colors.black54),
        ],
      ),
    );

    if (!isLink) return row;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => context.go(data.route!),
      child: row,
    );
  }
}
