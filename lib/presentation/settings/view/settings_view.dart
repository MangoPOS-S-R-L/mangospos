import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    // Lista de items. Puedes ir agregando más luego.
    final items = <_SettingsItemData>[
      _SettingsItemData(title: 'Usuarios.', route: null, icon: Icons.person_2_outlined),
      _SettingsItemData(
        title: 'Salones y mesas.',
        route: AppRoutes.settingsZonesTables,
        icon: Icons.grid_view_rounded,
        selected: true, // ← resaltado como en tu captura
      ),
      _SettingsItemData(title: 'Cajas.', route: null, icon: Icons.point_of_sale_outlined),
      _SettingsItemData(title: 'Impuestos.', route: null, icon: Icons.percent_outlined),
      _SettingsItemData(title: 'Tarjetas.', route: null, icon: Icons.credit_card_outlined),
      _SettingsItemData(title: 'Turnos.', route: null, icon: Icons.schedule_outlined),
      _SettingsItemData(title: 'Monedas.', route: null, icon: Icons.attach_money),
      _SettingsItemData(title: 'Comprobantes.', route: null, icon: Icons.receipt_long_outlined),
      _SettingsItemData(title: 'Transferencias.', route: null, icon: Icons.swap_horiz_outlined),
      _SettingsItemData(title: 'Opciones del sistema.', route: null, icon: Icons.settings_suggest_outlined),
      _SettingsItemData(title: 'Opciones APP Quipu.', route: null, icon: Icons.phone_android_outlined),
      _SettingsItemData(title: 'Configuraciones regionales.', route: null, icon: Icons.public_outlined),
    ];

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
            Text('Ajustes', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        itemBuilder: (ctx, i) => _SettingsRow(data: items[i]),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemCount: items.length,
      ),
    );
  }
}

class _SettingsItemData {
  final String title;
  final String? route;
  final IconData? icon;
  final bool selected;

  _SettingsItemData({
    required this.title,
    this.route,
    this.icon,
    this.selected = false,
  });
}

class _SettingsRow extends StatelessWidget {
  final _SettingsItemData data;
  const _SettingsRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final isLink = data.route != null;
    final row = Container(
      decoration: BoxDecoration(
        color: data.selected ? const Color(0xFFEFF5FF) : Colors.transparent, // azul muy suave
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      child: Row(
        children: [
          const Text('•', style: TextStyle(fontSize: 22, height: .9)), // bullet como en la captura
          const SizedBox(width: 10),
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
          if (isLink) const Icon(Icons.chevron_right, size: 20, color: Colors.black54),
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
