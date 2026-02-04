import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/domain/models/ventas_table.dart' as ventas;
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';
import 'package:mangopos/presentation/sales/widgets/table_card.dart';

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
      // Añadir listener para actualizar la UI cuando cambie el tab
      _tabController!.addListener(() {
        if (_tabController!.indexIsChanging ||
            _tabController!.index != _tabController!.previousIndex) {
          if (mounted) setState(() {});
        }
      });
      _previousZoneCount = currentZoneCount;
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(byZoneVmProvider);
    // Filter out 'Ventas manuales' as it is not a physical zone with tables
    final zones = vm.zones.where((z) => z.name != 'Ventas manuales').toList();
    final hasZones = zones.isNotEmpty;

    _updateTabController(zones);

    // Calcular contadores de disponibles y ocupadas SOLO para la zona actual
    int availableCount = 0;
    int occupiedCount = 0;

    // Determinamos la zona actual basándonos directamente en el índice del controller
    final currentZoneId =
        (hasZones &&
            _tabController != null &&
            _tabController!.index < zones.length)
        ? zones[_tabController!.index].id
        : null;

    if (currentZoneId != null && vm.statusByZone.containsKey(currentZoneId)) {
      final currentZoneTables = vm.statusByZone[currentZoneId]!;
      for (final table in currentZoneTables) {
        if (table.sessionId == null) {
          availableCount++;
        } else {
          occupiedCount++;
        }
      }
    }

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
              title: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // TABS LIST - Container con fondo secondary
                    Container(
                      padding: const EdgeInsets.all(4), // p-1
                      decoration: BoxDecoration(
                        color: SalesTheme.secondary, // bg-secondary
                        borderRadius: BorderRadius.circular(12), // rounded-xl
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: zones.asMap().entries.map((entry) {
                          final index = entry.key;
                          final zone = entry.value;
                          final isActive = _tabController?.index == index;

                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => _tabController?.animateTo(index),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                curve: Curves.easeInOut,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16, // px-4
                                  vertical: 8, // py-2
                                ),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? SalesTheme
                                            .cardBackground // bg-card (blanco)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(
                                    8,
                                  ), // rounded-lg
                                  boxShadow: isActive
                                      ? [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(
                                              0.05,
                                            ),
                                            blurRadius: 2,
                                            offset: const Offset(0, 1),
                                          ),
                                        ]
                                      : null,
                                ),
                                child: Text(
                                  zone.name,
                                  style: TextStyle(
                                    fontSize: 14, // text-sm
                                    fontWeight: FontWeight.w500, // Medium
                                    color: isActive
                                        ? SalesTheme
                                              .foreground // Negro cálido
                                        : SalesTheme
                                              .mutedForeground, // Gris medio
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),

                    // INDICADORES DE ESTADO a la derecha
                    Row(
                      children: [
                        // Indicador DISPONIBLES (verde)
                        _buildStatusIndicator(
                          count: availableCount,
                          label: 'disponible',
                          color: SalesTheme.success,
                        ),
                        const SizedBox(width: 16), // gap-4
                        // Indicador OCUPADAS (naranja)
                        _buildStatusIndicator(
                          count: occupiedCount,
                          label: 'ocupada',
                          color: SalesTheme.warning,
                        ),
                        const SizedBox(width: 12),
                        // Botón refresh
                        IconButton(
                          onPressed: _loadData,
                          icon: const Icon(
                            Icons.refresh_rounded,
                            size: 20,
                            color: SalesTheme.mutedForeground,
                          ),
                          tooltip: 'Actualizar',
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                      ],
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

  /// Construye un indicador de estado (disponibles/ocupadas)
  Widget _buildStatusIndicator({
    required int count,
    required String label,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Dot circular de 12x12px
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6), // gap-2
        // Texto del indicador
        Text(
          '$count ${label}${count != 1 ? 's' : ''}',
          style: const TextStyle(
            fontSize: 14, // text-sm
            fontWeight: FontWeight.w400, // Regular
            color: SalesTheme.mutedForeground,
            height: 1.25, // line-height 20px
          ),
        ),
      ],
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

    return Column(
      children: [
        // Eliminamos los indicadores de estado aquí, ya que están en el AppBar
        // y se actualizarán dinámicamente según la zona seleccionada
        // Grid
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Calcular número óptimo de columnas
              // Usando 220px como referencia para favorecer más columnas (cards más estrechas)
              final availableWidth =
                  constraints.maxWidth - 48; // Quitando padding (24px × 2)

              int columns =
                  ((availableWidth + SalesTheme.gridGap) /
                          (220.0 +
                              SalesTheme.gridGap)) // 220px en lugar de 240px
                      .floor()
                      .clamp(
                        1,
                        5,
                      ); // Máximo 5 columnas según tabla de referencia

              // Calcular el ancho REAL de cada card
              final totalGaps = (columns - 1) * SalesTheme.gridGap;
              final cardWidth = (availableWidth - totalGaps) / columns;

              // Calcular aspect ratio dinámico: cardWidth / cardHeight
              final aspectRatio = cardWidth / SalesTheme.tableCardHeight;

              return GridView.builder(
                padding: const EdgeInsets.all(24),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: aspectRatio, // Dinámico
                  crossAxisSpacing: SalesTheme.gridGap,
                  mainAxisSpacing: SalesTheme.gridGap,
                ),
                itemCount: tables.length,
                itemBuilder: (context, index) {
                  final table = tables[index];
                  final opening = ref
                      .watch(byZoneVmProvider)
                      .openingTables
                      .contains(table.tableId);
                  return TableCard(
                    table: _convertTableStatusToVentasTable(table),
                    isOpening: opening,
                    onTap: () => _handleTableAction(context, ref, table),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _handleTableAction(
    BuildContext context,
    WidgetRef ref,
    TableStatus ts,
  ) async {
    final byZone = ref.read(byZoneVmProvider.notifier);
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

  /// Convierte TableStatus a VentasTable para el  nuevo TableCard
  ventas.VentasTable _convertTableStatusToVentasTable(TableStatus ts) {
    // Determinar el estado basado en sessionId y status
    ventas.TableStatus status;
    if (ts.sessionId == null) {
      status = ventas.TableStatus.disponible;
    } else {
      final statusRaw = (ts.status ?? '').toLowerCase();
      if (statusRaw == 'paying' ||
          statusRaw == 'checkout' ||
          statusRaw == 'payment') {
        status = ventas.TableStatus.pagando;
      } else {
        status = ventas.TableStatus.ocupado;
      }
    }

    // Formatear el tiempo
    String? time;
    if (ts.minutesOpen != null && ts.minutesOpen! > 0) {
      final hours = ts.minutesOpen! ~/ 60;
      final mins = ts.minutesOpen! % 60;
      time =
          '${hours.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}';
    }

    return ventas.VentasTable(
      id: ts.tableId,
      code: ts.code,
      status: status,
      zone: ts.zoneId,
      guests: ts.peopleCount > 0 ? ts.peopleCount : null,
      time: time,
      total: ts.total > 0 ? ts.total : null,
      waiterId: ts.sessionId, // Usamos sessionId como waiterId temporalmente
      waiterName: ts.waiterName,
    );
  }
}
