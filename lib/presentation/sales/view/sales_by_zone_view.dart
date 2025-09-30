import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import '../../../data/models/table_status.dart';

class SalesByZoneView extends ConsumerStatefulWidget {
  final String businessId;
  const SalesByZoneView({super.key, required this.businessId});

  @override
  ConsumerState<SalesByZoneView> createState() => _SalesByZoneViewState();
}

class _SalesByZoneViewState extends ConsumerState<SalesByZoneView>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;
  int _previousZoneCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(byZoneVmProvider.notifier).load(widget.businessId);
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _updateTabController(List zones) {
    final currentZoneCount = zones.length;

    if (currentZoneCount == 0) {
      _tabController?.dispose();
      _tabController = null;
      _previousZoneCount = 0;
      return;
    }

    if (_tabController == null || _previousZoneCount != currentZoneCount) {
      final previousIndex = _tabController?.index ?? 0;
      _tabController?.dispose();

      final initialIndex = previousIndex < currentZoneCount
          ? previousIndex
          : currentZoneCount - 1;

      _tabController = TabController(
        length: currentZoneCount,
        vsync: this,
        initialIndex: initialIndex,
      );

      _previousZoneCount = currentZoneCount;
    }
  }

  Widget _buildEmptyState(String message, {IconData? icon}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 64, color: MangoColors.muted),
              const SizedBox(height: 16),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: MangoColors.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red.shade400),
            const SizedBox(height: 16),
            Text(
              'Error: $error',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.red.shade600),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () =>
                  ref.read(byZoneVmProvider.notifier).load(widget.businessId),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(byZoneVmProvider);
    final zones = vm.zones;
    final hasZones = zones.isNotEmpty;

    _updateTabController(zones);

    Widget body;
    if (!hasZones) {
      if (vm.loading) {
        body = const Center(child: CircularProgressIndicator());
      } else if (vm.error != null) {
        body = _buildErrorState(vm.error!);
      } else {
        body = _buildEmptyState(
          'No hay zonas configuradas',
          icon: Icons.location_off,
        );
      }
    } else {
      body = TabBarView(
        controller: _tabController!,
        children: zones.map((zone) => _ZoneGrid(zoneId: zone.id)).toList(),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: hasZones && _tabController != null
          ? AppBar(
              backgroundColor: Colors.white,
              elevation: 0,
              automaticallyImplyLeading: false,
              // ↑ AppBar un poquito más grande para dar aire vertical
              toolbarHeight: 59,
              titleSpacing: 0,
              title: Row(
                children: [
                  Expanded(
                    child: TabBar(
                      controller: _tabController!,
                      isScrollable: true,
                      // ↑ Más espacio entre cada tab
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      labelPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      // ↑ Dejamos la indicación un poco “separada”
                      indicatorPadding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      labelColor: MangoColors.primaryOrange,
                      unselectedLabelColor: MangoColors.muted,
                      indicatorSize: TabBarIndicatorSize.label,
                      // ↑ Quitamos hover/splash en web
                      overlayColor: WidgetStatePropertyAll<Color>(
                        Colors.transparent,
                      ),
                      splashFactory: NoSplash.splashFactory,
                      indicator: BoxDecoration(
                        color: MangoColors.primaryOrange.withOpacity(0.10),
                        border: Border.all(
                          color: MangoColors.primaryOrange,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      tabs: zones
                          .map(
                            (zone) => Tab(
                              child: Container(
                                // ↑ Más padding interno para que el borde no “coma” el texto
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                child: Text(
                                  zone.name.toUpperCase(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: .3,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                  // Botón refrescar sin sombra/hover
                  IconButton(
                    onPressed: () => ref
                        .read(byZoneVmProvider.notifier)
                        .load(widget.businessId),
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Actualizar',
                    style: const ButtonStyle(
                      overlayColor: WidgetStatePropertyAll<Color>(
                        Colors.transparent,
                      ),
                      splashFactory: NoSplash.splashFactory,
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(byZoneVmProvider.notifier).load(widget.businessId);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            body,
            if (vm.loading && hasZones)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                  ),
                ),
              ),
          ],
        ),
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
      return const _LoadingGrid();
    }

    if (vm.error != null && !vm.loading) {
      return _ErrorStateWidget(
        error: vm.error!,
        onRetry: () =>
            ref.read(byZoneVmProvider.notifier).loadZoneStatus(zoneId),
      );
    }

    if (tables.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.table_restaurant, size: 64, color: MangoColors.muted),
            SizedBox(height: 16),
            Text(
              'No hay mesas en esta zona',
              style: TextStyle(
                color: MangoColors.muted,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    return _ResponsiveTableGrid(tables: tables);
  }
}

class _ResponsiveTableGrid extends StatelessWidget {
  final List<TableStatus> tables;
  const _ResponsiveTableGrid({required this.tables});

  GridConfiguration _getGridConfiguration(double width) {
    if (width >= 1800) return GridConfiguration(8, 0.86, 18);
    if (width >= 1500) return GridConfiguration(7, 0.82, 18);
    if (width >= 1280) return GridConfiguration(6, 0.80, 18);
    if (width >= 1080) return GridConfiguration(5, 0.78, 16);
    if (width >= 820) return GridConfiguration(4, 0.76, 16);
    if (width >= 560) return GridConfiguration(3, 0.74, 14);
    return GridConfiguration(2, 0.74, 14);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final config = _getGridConfiguration(width);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.builder(
        itemCount: tables.length,
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: config.crossAxisCount,
          crossAxisSpacing: config.spacing,
          mainAxisSpacing: config.spacing,
          childAspectRatio: config.aspectRatio,
        ),
        itemBuilder: (context, index) =>
            _TableCard(ts: tables[index], screenWidth: width),
      ),
    );
  }
}

class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Cargando mesas...', style: TextStyle(color: MangoColors.muted)),
        ],
      ),
    );
  }
}

class _ErrorStateWidget extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorStateWidget({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
            const SizedBox(height: 12),
            Text(
              'Error: $error',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.red.shade600),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TableCard extends StatelessWidget {
  final TableStatus ts;
  final double screenWidth;

  const _TableCard({required this.ts, required this.screenWidth});

  CardSizes _getCardSizes(double width) {
    if (width >= 1500) return CardSizes(30, 17, 44, 16);
    if (width >= 1280) return CardSizes(28, 16, 44, 16);
    if (width >= 1080) return CardSizes(28, 16, 42, 14);
    if (width >= 820) return CardSizes(26, 16, 42, 14);
    return CardSizes(26, 16, 40, 14);
  }

  void _handleTableAction(BuildContext context) {
    final occupied = ts.sessionId != null;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          occupied
              ? 'Navegando a pedidos de mesa ${ts.code}'
              : 'Abriendo mesa ${ts.code}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final occupied = ts.sessionId != null;
    final sizes = _getCardSizes(screenWidth);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: occupied ? MangoColors.primaryOrange : MangoColors.cardBorder,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
            spreadRadius: 0,
          ),
        ],
      ),
      padding: EdgeInsets.all(sizes.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              ts.code,
              maxLines: 1,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: sizes.codeSize,
                color: MangoColors.primaryOrange,
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (occupied) ...[
            Text(
              '${ts.ordersCount ?? 0} ${ts.ordersCount == 1 ? 'Pedido' : 'Pedidos'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: sizes.labelSize,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.access_time,
                  size: 16,
                  color: MangoColors.muted,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    ts.minutesOpen == null ? '—' : '${ts.minutesOpen} min',
                    style: const TextStyle(color: MangoColors.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ] else ...[
            Text(
              'Disponible',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: sizes.labelSize,
                color: MangoColors.successGreen,
              ),
            ),
            const SizedBox(height: 4),
            const Row(
              children: [
                Icon(Icons.access_time, size: 16, color: MangoColors.muted),
                SizedBox(width: 6),
                Text('00:00', style: TextStyle(color: MangoColors.muted)),
              ],
            ),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: occupied
                    ? MangoColors.primaryOrange
                    : MangoColors.darkGray,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
                minimumSize: Size.fromHeight(sizes.buttonHeight),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => _handleTableAction(context),
              child: Text(
                occupied ? 'Ver pedidos' : 'Abrir mesa',
                style: TextStyle(
                  fontSize: sizes.labelSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GridConfiguration {
  final int crossAxisCount;
  final double aspectRatio;
  final double spacing;

  const GridConfiguration(this.crossAxisCount, this.aspectRatio, this.spacing);
}

class CardSizes {
  final double codeSize;
  final double labelSize;
  final double buttonHeight;
  final double cardPadding;

  const CardSizes(
    this.codeSize,
    this.labelSize,
    this.buttonHeight,
    this.cardPadding,
  );
}
