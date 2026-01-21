import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';

class SalesByZoneView extends ConsumerStatefulWidget {
  final String businessId;
  const SalesByZoneView({super.key, required this.businessId});

  @override
  ConsumerState createState() => _SalesByZoneViewState();
}

class _SalesByZoneViewState extends ConsumerState<SalesByZoneView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  TabController? _tabController;
  int _previousZoneCount = 0;
  Timer? _autoRefreshTimer;

  // Configuración de actualización automática
  static const Duration _refreshInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
      _startAutoRefresh();
    });
  }

  void _loadData() {
    ref.read(byZoneVmProvider.notifier).load(widget.businessId);
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(_refreshInterval, (timer) {
      if (mounted) {
        _loadData();
      }
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadData();
      _startAutoRefresh();
    } else if (state == AppLifecycleState.paused) {
      _stopAutoRefresh();
    }
  }

  @override
  void dispose() {
    _stopAutoRefresh();
    WidgetsBinding.instance.removeObserver(this);
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

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(byZoneVmProvider);
    final zones = vm.zones;
    final hasZones = zones.isNotEmpty;

    _updateTabController(zones);

    Widget body;
    if (!hasZones) {
      if (vm.loading) {
        body = const Center(
          child: CircularProgressIndicator(color: SalesTheme.primary),
        );
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
      backgroundColor: SalesTheme.background,
      appBar: hasZones && _tabController != null
          ? AppBar(
              backgroundColor: SalesTheme.background,
              elevation: 0,
              automaticallyImplyLeading: false,
              toolbarHeight: 56,
              titleSpacing: 0,
              title: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TabBar(
                        controller: _tabController!,
                        isScrollable: true,
                        labelColor: SalesTheme.primary,
                        unselectedLabelColor: SalesTheme.mutedForeground,
                        indicatorColor: SalesTheme.primary,
                        indicatorWeight: 3,
                        labelStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        unselectedLabelStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                        indicatorSize: TabBarIndicatorSize.label,
                        tabAlignment: TabAlignment.start,
                        padding: EdgeInsets.zero,
                        labelPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        tabs: zones
                            .map((zone) => Tab(text: zone.name))
                            .toList(),
                      ),
                    ),
                    IconButton(
                      onPressed: _loadData,
                      icon: const Icon(
                        Icons.refresh,
                        size: 22,
                        color: SalesTheme.mutedForeground,
                      ),
                      tooltip: 'Actualizar',
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: RefreshIndicator(
        color: SalesTheme.primary,
        onRefresh: () async {
          await ref.read(byZoneVmProvider.notifier).load(widget.businessId);
        },
        child: body,
      ),
    );
  }

  Widget _buildEmptyState(String message, {IconData? icon}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, size: 64, color: SalesTheme.mutedForeground),
          const SizedBox(height: 16),
          Text(
            message,
            style: SalesTheme.textTheme.bodyLarge?.copyWith(
              color: SalesTheme.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            size: 64,
            color: SalesTheme.destructive,
          ),
          const SizedBox(height: 16),
          Text(
            'Error: $error',
            style: SalesTheme.textTheme.bodyMedium?.copyWith(
              color: SalesTheme.destructive,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: SalesTheme.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoneGrid extends ConsumerStatefulWidget {
  final String zoneId;
  const _ZoneGrid({required this.zoneId});

  @override
  ConsumerState<_ZoneGrid> createState() => _ZoneGridState();
}

class _ZoneGridState extends ConsumerState<_ZoneGrid> {
  Timer? _zoneRefreshTimer;
  static const Duration _zoneRefreshInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _startZoneRefresh();
  }

  void _startZoneRefresh() {
    _zoneRefreshTimer?.cancel();
    ref.read(byZoneVmProvider.notifier).loadZoneStatus(widget.zoneId);
    _zoneRefreshTimer = Timer.periodic(_zoneRefreshInterval, (timer) {
      if (mounted) {
        ref.read(byZoneVmProvider.notifier).loadZoneStatus(widget.zoneId);
      }
    });
  }

  @override
  void dispose() {
    _zoneRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(byZoneVmProvider);
    final tables = vm.statusByZone[widget.zoneId];

    if (tables == null) {
      return const Center(
        child: CircularProgressIndicator(color: SalesTheme.primary),
      );
    }

    if (vm.error != null && !vm.loading && tables.isEmpty) {
      return Center(
        child: TextButton.icon(
          onPressed: () =>
              ref.read(byZoneVmProvider.notifier).loadZoneStatus(widget.zoneId),
          icon: const Icon(Icons.refresh),
          label: const Text('Reintentar'),
        ),
      );
    }

    if (tables.isEmpty) {
      return const Center(child: Text('No hay mesas en esta zona'));
    }

    final availableCount = tables.where((t) => t.sessionId == null).length;
    final occupiedCount = tables.where((t) => t.sessionId != null).length;

    return Column(
      children: [
        // Indicadores
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Row(
            children: [
              _StatusBadge(
                label: '$availableCount disponibles',
                color: const Color(0xFF10B981),
              ),
              const SizedBox(width: 12),
              _StatusBadge(
                label: '$occupiedCount ocupadas',
                color: const Color(0xFFF59E0B),
              ),
            ],
          ),
        ),
        // Grid
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              childAspectRatio: 2.0,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: tables.length,
            itemBuilder: (context, index) => _TableCard(ts: tables[index]),
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TableCard extends ConsumerStatefulWidget {
  final TableStatus ts;
  const _TableCard({required this.ts});

  @override
  ConsumerState<_TableCard> createState() => _TableCardState();
}

class _TableCardState extends ConsumerState<_TableCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final occupied = widget.ts.sessionId != null;
    final borderColor = occupied
        ? const Color(0xFFF59E0B)
        : const Color(0xFF10B981);

    final opening = ref
        .watch(byZoneVmProvider)
        .openingTables
        .contains(widget.ts.tableId);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => _animController.forward(),
        onTapUp: (_) {
          _animController.reverse();
          if (!opening) _handleTableAction(context, ref);
        },
        onTapCancel: () => _animController.reverse(),
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(0, _isHovered ? -2 : 0, 0),
            constraints: const BoxConstraints(minHeight: 120),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
              boxShadow: [
                if (_isHovered)
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  )
                else
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
              ],
            ),
            child: Stack(
              children: [
                // Borde de color izquierdo
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: borderColor,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(12),
                        bottomLeft: Radius.circular(12),
                      ),
                    ),
                  ),
                ),
                // Contenido
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.ts.code,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                              letterSpacing: -0.5,
                            ),
                          ),
                          if (occupied && widget.ts.total > 0)
                            Text(
                              'RD\$ ${widget.ts.total.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},')}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                        ],
                      ),

                      const SizedBox(height: 4),

                      // Status text (sin badge)
                      Text(
                        occupied ? 'Ocupado' : 'Disponible',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: borderColor,
                        ),
                      ),

                      const SizedBox(height: 6),

                      // Divider
                      Container(height: 1, color: const Color(0xFFE2E8F0)),

                      const SizedBox(height: 6),

                      // Bottom info
                      if (opening) ...[
                        Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: borderColor,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Abriendo...',
                              style: TextStyle(
                                fontSize: 11,
                                color: borderColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ] else if (occupied) ...[
                        Row(
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 16,
                              color: const Color(0xFF64748B),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${widget.ts.peopleCount}',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Icon(
                              Icons.access_time,
                              size: 16,
                              color: const Color(0xFF64748B),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _formatTime(widget.ts.minutesOpen ?? 0),
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        const Text(
                          'Toca para asignar',
                          style: TextStyle(
                            fontSize: 14,
                            color: Color(0xFF94A3B8),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(int minutes) {
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return '${hours.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}';
  }

  Future<void> _handleTableAction(BuildContext context, WidgetRef ref) async {
    final byZone = ref.read(byZoneVmProvider.notifier);
    final ts = widget.ts;

    final opening = ref
        .read(byZoneVmProvider)
        .openingTables
        .contains(ts.tableId);
    if (opening) return;

    byZone.setOpening(ts.tableId, true);

    try {
      await ref.read(currentOrderProvider.notifier).openTable(ts.tableId);
      if (!context.mounted) return;
      context.go(
        Uri(
          path: '${AppRoutes.sales}/table/${ts.tableId}',
          queryParameters: {'code': ts.code, 'zone': ts.zoneId},
        ).toString(),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al abrir mesa: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      byZone.setOpening(ts.tableId, false);
    }
  }
}
