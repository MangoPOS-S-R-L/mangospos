import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';

class PrintingHomeView extends ConsumerWidget {
  final String businessId;
  const PrintingHomeView({super.key, this.businessId = 'auto'});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(printingPrintersViewModelProvider);
    final printersCtrl = ref.read(printingPrintersViewModelProvider.notifier);

    if (!printers.isLoading && printers.items.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        printersCtrl.load(businessId: businessId);
      });
    }

    final cards = [
      _PrintingCardData(
        title: 'Impresoras',
        subtitle: 'Configuración de impresoras',
        icon: Icons.print,
        iconColor: const Color(0xFFFF9800),
        color: const Color(0xFFFFF4E6),
        route: AppRoutes.printingPrinters,
      ),
      _PrintingCardData(
        title: 'Asignar Impresión de Productos',
        subtitle: 'Productos por impresora',
        icon: Icons.fastfood,
        iconColor: const Color(0xFFFFA726),
        color: const Color(0xFFFFF3E0),
        route: AppRoutes.printingProducts,
      ),
      _PrintingCardData(
        title: 'Asignar Impresión de Comprobantes',
        subtitle: 'Comprobantes por impresora',
        icon: Icons.receipt_long,
        iconColor: const Color(0xFF66BB6A),
        color: const Color(0xFFE8F5E9),
        route: AppRoutes.printingReceipts,
      ),
      _PrintingCardData(
        title: 'Asignar Impresión de Comandas',
        subtitle: 'Comandas por impresora de cocina',
        icon: Icons.restaurant_menu,
        iconColor: const Color(0xFF42A5F5),
        color: const Color(0xFFE3F2FD),
        route: AppRoutes.printingOrders,
      ),
      _PrintingCardData(
        title: 'Diagnóstico',
        subtitle: 'Estado del agente, dispositivos e impresoras',
        icon: Icons.health_and_safety_outlined,
        iconColor: const Color(0xFF3C83F6),
        color: const Color(0xFFEFF6FF),
        route: AppRoutes.printingDiagnostics,
      ),
    ];

    return Container(
      color: const Color(0xFFF7F7F7),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: MangoColors.darkGray,
                padding: const EdgeInsets.symmetric(horizontal: 0),
              ),
              onPressed: () => context.go(AppRoutes.settings),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Regresar'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Gestión de Impresión',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 18),
            _PrintersSection(
              state: printers,
              onAdd: () => context.go(AppRoutes.printingPrinters),
            ),
            const SizedBox(height: 22),
            const Text(
              'Otras opciones',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                double maxWidth = constraints.maxWidth;
                int crossAxisCount = 3;
                if (maxWidth < 1200) crossAxisCount = 2;
                if (maxWidth < 720) crossAxisCount = 1;

                return GridView.builder(
                  itemCount: cards.length,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 14,
                    childAspectRatio: 2.8,
                  ),
                  itemBuilder: (_, index) {
                    final data = cards[index];
                    return _PrintingCard(data: data);
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PrintersSection extends StatelessWidget {
  final PrintingPrintersState state;
  final VoidCallback onAdd;
  const _PrintersSection({required this.state, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MangoColors.cardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.print_rounded, color: MangoColors.darkGray),
              const SizedBox(width: 8),
              const Text(
                'Impresoras',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: MangoColors.darkGray,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Agregar impresora'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF2B7A2E),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (state.isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(
                minHeight: 6,
                backgroundColor: MangoColors.bgLight,
                color: MangoColors.primaryOrange,
              ),
            )
          else if (state.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: MangoColors.bgLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Sin impresoras configuradas',
                      style: TextStyle(
                        color: MangoColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: onAdd,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Agregar ahora'),
                  ),
                ],
              ),
            )
          else
            Column(
              children: state.items.take(3).map((p) {
                final ip = p.ip?.isNotEmpty == true ? p.ip! : 'Sin IP';
                final mac = p.mac?.isNotEmpty == true ? p.mac! : 'Sin MAC';
                final typeLabel = p.type.label.toUpperCase();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: MangoColors.bgLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.print_rounded,
                            size: 18,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.name,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: MangoColors.darkGray,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'IP: $ip   MAC: $mac',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  p.online
                                      ? Icons.circle
                                      : Icons.circle_outlined,
                                  size: 10,
                                  color: p.online
                                      ? const Color(0xFF2BAA3D)
                                      : Colors.redAccent,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  p.online ? 'En linea' : 'Desconectada',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: p.online
                                        ? const Color(0xFF2BAA3D)
                                        : Colors.redAccent,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              typeLabel,
                              style: const TextStyle(
                                fontSize: 10,
                                color: MangoColors.muted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}

class _PrintingCardData {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Color iconColor;
  final String route;

  const _PrintingCardData({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.iconColor,
    required this.route,
  });
}

class _PrintingCard extends StatelessWidget {
  final _PrintingCardData data;
  const _PrintingCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => context.go(data.route),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MangoColors.cardBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: data.color,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(data.icon, size: 20, color: data.iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    data.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.black45, size: 18),
          ],
        ),
      ),
    );
  }
}
