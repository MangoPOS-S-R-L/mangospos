import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/sales/view/sales_by_zone_view.dart';
import '../viewmodel/by_zone_viewmodel.dart';
import '../../../data/models/table_status.dart';

class SalesByZoneView extends ConsumerStatefulWidget {
  final String businessId;
  const SalesByZoneView({super.key, required this.businessId});

  @override
  ConsumerState<SalesByZoneView> createState() => _SalesByZoneViewState();
}

class _SalesByZoneViewState extends ConsumerState<SalesByZoneView> with SingleTickerProviderStateMixin {
  TabController? _tab;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(byZoneVmProvider.notifier).load(widget.businessId));
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(byZoneVmProvider);
    if (vm.loading) return const Center(child: CircularProgressIndicator());
    if (vm.zones.isEmpty) return const Center(child: Text('No hay zonas'));

    _tab ??= TabController(length: vm.zones.length, vsync: this);

    return Scaffold(
      backgroundColor: MangoColors.bgLight,
      appBar: AppBar(
        title: const Text('Ventas · Por Zona'),
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          labelColor: MangoColors.primaryOrange,
          unselectedLabelColor: MangoColors.muted,
          tabs: [for (final z in vm.zones) Tab(text: z.name.toUpperCase())],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [for (final z in vm.zones) _ZoneGrid(zoneId: z.id)],
      ),
    );
  }
}

class _ZoneGrid extends ConsumerWidget {
  final String zoneId;
  const _ZoneGrid({required this.zoneId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(byZoneVmProvider);
    final tables = vm.statusByZone[zoneId];
    if (tables == null) {
      ref.read(byZoneVmProvider.notifier).loadZoneStatus(zoneId);
      return const Center(child: CircularProgressIndicator());
    }
    final w = MediaQuery.of(context).size.width;
    final cross = w > 1400 ? 8 : w > 900 ? 6 : 3;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cross, crossAxisSpacing: 14, mainAxisSpacing: 14, childAspectRatio: 1),
        itemCount: tables.length,
        itemBuilder: (_, i) => _TableCard(ts: tables[i]),
      ),
    );
  }
}

class _TableCard extends StatelessWidget {
  final TableStatus ts;
  const _TableCard({required this.ts});

  @override
  Widget build(BuildContext context) {
    final occupied = ts.sessionId != null;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: occupied ? MangoColors.primaryOrange : MangoColors.cardBorder, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x12000000), blurRadius: 8, offset: Offset(0,3))],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ts.code, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 28, color: MangoColors.primaryOrange)),
        const SizedBox(height: 6),
        if (occupied) ...[
          Text('${ts.ordersCount} Pedidos', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.access_time, size: 16, color: MangoColors.muted),
            const SizedBox(width: 6),
            Text(ts.minutesOpen == null ? '—' : '${ts.minutesOpen} min', style: const TextStyle(color: MangoColors.muted)),
          ]),
        ] else ...[
          const Spacer(),
          const Text('Disponible', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: MangoColors.successGreen)),
          const SizedBox(height: 4),
          Row(children: const [
            Icon(Icons.access_time, size: 16, color: MangoColors.muted),
            SizedBox(width: 6),
            Text('00:00', style: TextStyle(color: MangoColors.muted)),
          ]),
        ],
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: occupied ? MangoColors.primaryOrange : MangoColors.darkGray,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onPressed: () {
              // Navegar al POS de esta mesa
            },
            child: Text(occupied ? 'Ver pedidos' : 'Abrir mesa'),
          ),
        ),
      ]),
    );
  }
}
