import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/services/session/session_controller.dart';

class PlanManagementView extends ConsumerWidget {
  const PlanManagementView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final businessName = session.activeBusinessName?.trim().isNotEmpty == true
        ? session.activeBusinessName!.trim()
        : 'Tu negocio';

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        titleSpacing: 12,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go(AppRoutes.settings),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Plan y Suscripción',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            Text(
              'Resumen comercial y crecimiento del negocio',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          _PlanHeroCard(businessName: businessName),
          const SizedBox(height: 18),
          const _SectionTitle(
            title: 'Incluido en tu operación actual',
            subtitle: 'Capacidades que ya tienes activas dentro de MangoPOS',
          ),
          const SizedBox(height: 12),
          const _FeatureGrid(
            items: [
              _FeatureItem(
                title: 'Punto de venta',
                subtitle: 'Ventas, caja, cocina y reportes operativos.',
                icon: Icons.point_of_sale_rounded,
                accent: Color(0xFFFFE6D5),
              ),
              _FeatureItem(
                title: 'Control de usuarios',
                subtitle: 'Roles, permisos y accesos por cargo.',
                icon: Icons.admin_panel_settings_rounded,
                accent: Color(0xFFEAF0FF),
              ),
              _FeatureItem(
                title: 'Inventario y compras',
                subtitle: 'Entradas, salidas, kardex y recepción de compras.',
                icon: Icons.inventory_2_rounded,
                accent: Color(0xFFE6F7EE),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _SectionTitle(
            title: 'Mejoras sugeridas',
            subtitle: 'Opciones para crecer sin romper el flujo operativo actual',
          ),
          const SizedBox(height: 12),
          const _UpgradeGrid(
            items: [
              _UpgradeItem(
                title: 'Multi-sucursal',
                subtitle: 'Opera varios locales con control separado por sede.',
                priceHint: 'Escalable',
                icon: Icons.store_mall_directory_rounded,
                accent: Color(0xFFFFF0D9),
              ),
              _UpgradeItem(
                title: 'Más usuarios',
                subtitle: 'Amplía tu equipo con más cajeros, meseros o cocina.',
                priceHint: 'Por equipo',
                icon: Icons.group_add_rounded,
                accent: Color(0xFFEAF0FF),
              ),
              _UpgradeItem(
                title: 'Acompañamiento premium',
                subtitle: 'Soporte prioritario para operación, hardware y fiscal.',
                priceHint: 'Soporte',
                icon: Icons.support_agent_rounded,
                accent: Color(0xFFFFEDED),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _CommercialCallout(),
        ],
      ),
    );
  }
}

class _PlanHeroCard extends StatelessWidget {
  const _PlanHeroCard({required this.businessName});

  final String businessName;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF0E7),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.workspace_premium_rounded,
                    color: MangoColors.primaryOrange,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            businessName,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1F2937),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE6F7EE),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'Plan Base activo',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF15803D),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Tu operación está lista para ventas, caja, cocina, inventario y control de accesos.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[700],
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(height: 1, color: MangoColors.cardBorder),
            const SizedBox(height: 14),
            const Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _HeroStat(
                  label: 'Estado',
                  value: 'Operativo',
                  icon: Icons.check_circle_rounded,
                  color: Color(0xFF22C55E),
                ),
                _HeroStat(
                  label: 'Usuarios',
                  value: 'RBAC activo',
                  icon: Icons.people_alt_rounded,
                  color: Color(0xFF2563EB),
                ),
                _HeroStat(
                  label: 'Crecimiento',
                  value: 'Disponible',
                  icon: Icons.trending_up_rounded,
                  color: MangoColors.primaryOrange,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Column(
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
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
      ],
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid({required this.items});

  final List<_FeatureItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        int crossAxisCount = 3;
        if (constraints.maxWidth < 980) crossAxisCount = 2;
        if (constraints.maxWidth < 620) crossAxisCount = 1;

        return GridView.builder(
          itemCount: items.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.45,
          ),
          itemBuilder: (context, index) => _FeatureCard(item: items[index]),
        );
      },
    );
  }
}

class _FeatureItem {
  const _FeatureItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.item});

  final _FeatureItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: item.accent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: MangoColors.darkGray),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UpgradeGrid extends StatelessWidget {
  const _UpgradeGrid({required this.items});

  final List<_UpgradeItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isSingleColumn = constraints.maxWidth < 920;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: items
              .map(
                (item) => SizedBox(
                  width: isSingleColumn
                      ? constraints.maxWidth
                      : (constraints.maxWidth - 24) / 3,
                  child: _UpgradeCard(item: item),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _UpgradeItem {
  const _UpgradeItem({
    required this.title,
    required this.subtitle,
    required this.priceHint,
    required this.icon,
    required this.accent,
  });

  final String title;
  final String subtitle;
  final String priceHint;
  final IconData icon;
  final Color accent;
}

class _UpgradeCard extends StatelessWidget {
  const _UpgradeCard({required this.item});

  final _UpgradeItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: item.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(item.icon, color: MangoColors.darkGray),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  item.priceHint,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            item.title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            item.subtitle,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommercialCallout extends StatelessWidget {
  const _CommercialCallout();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '¿Quieres subir de plan?',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  'Podemos conectar esta pantalla luego con facturación, ventas o contacto comercial. Por ahora queda lista para que el administrador vea el estado actual y el siguiente paso.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[700],
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Flujo comercial listo para integrar con tu proveedor de facturación o CRM.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.rocket_launch_rounded),
            label: const Text('Solicitar mejora de plan'),
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: Colors.white,
              minimumSize: const Size(220, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
