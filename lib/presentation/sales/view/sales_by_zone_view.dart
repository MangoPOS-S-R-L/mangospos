import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/multimesero/multimesero_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/cashier/widgets/open_cash_dialog.dart';
import 'package:mangopos/presentation/sales/state/sales_zoom_provider.dart';
import 'package:mangopos/presentation/sales/state/sales_view_mode_provider.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/widgets/sales_zoom_control.dart';
import 'package:mangopos/presentation/sales/widgets/zone_floor_map.dart';
import 'package:mangopos/presentation/sales/view/theme/table_status_style.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/sales/widgets/pin_verification_modal.dart';
import 'package:mangopos/presentation/sales/widgets/transfer_session_dialog.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';
import 'package:mangopos/presentation/sales/widgets/table_card.dart';
import 'package:mangopos/app/widgets/skeleton_loading.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';

/// Delega al helper compartido [isTableEffectivelyEmpty] para que grid y
/// floor map apliquen el mismo criterio de "ocupada fantasma".
bool _isEffectivelyEmpty(TableStatus ts) => isTableEffectivelyEmpty(ts);

class SalesByZoneView extends ConsumerStatefulWidget {
  final String businessId;

  /// Zona inicial a seleccionar al montar la vista. Usado cuando el
  /// usuario regresa desde una mesa abierta — queremos volver a la
  /// misma zona donde estaba (no saltar al index 0). Pasado vía
  /// `?zone=<id>` en el route.
  final String? initialZoneId;

  const SalesByZoneView({
    super.key,
    required this.businessId,
    this.initialZoneId,
  });

  @override
  ConsumerState createState() => _SalesByZoneViewState();
}

class _SalesByZoneViewState extends ConsumerState<SalesByZoneView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  TabController? _tabController;
  int _previousZoneCount = 0;
  Timer? _autoRefreshTimer;

  // Configuración de actualización automática
  static const Duration _refreshInterval = Duration(seconds: 30);

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
    final cashierVm = ref.read(cashierViewModelProvider);
    if (!cashierVm.isLoading) {
      if (cashierVm.currentRegisterId == null || cashierVm.businessId == null) {
        unawaited(cashierVm.init());
      } else {
        unawaited(cashierVm.ensureCashOpenFast());
      }
    }
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
      final isFirstBuild = _tabController == null;
      final previousIndex = _tabController?.index ?? 0;
      _tabController?.dispose();

      int initialIndex;
      // En el primer build, respetar `initialZoneId` (viene del route
      // cuando el usuario regresa desde una mesa). En rebuilds, mantener
      // el index actual para no perder selección del usuario.
      if (isFirstBuild && widget.initialZoneId != null) {
        final wantedId = widget.initialZoneId;
        final foundIdx = zones.indexWhere((z) => z.id == wantedId);
        initialIndex = foundIdx >= 0 ? foundIdx : 0;
      } else {
        initialIndex = previousIndex < currentZoneCount
            ? previousIndex
            : currentZoneCount - 1;
      }

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
    // Use .select() to only rebuild when the specific data we need changes
    final zones = ref.watch(byZoneVmProvider.select((s) => s.zones));
    final isZoneLoading = ref.watch(byZoneVmProvider.select((s) => s.loading));
    final zoneError = ref.watch(byZoneVmProvider.select((s) => s.error));
    final isCashOpen = ref.watch(
      cashierViewModelProvider.select((vm) => vm.isCashOpen),
    );
    final viewMode = ref.watch(salesViewModeProvider);
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

    final statusByZone = ref.watch(byZoneVmProvider.select((s) => s.statusByZone));
    if (currentZoneId != null && statusByZone.containsKey(currentZoneId)) {
      final currentZoneTables = statusByZone[currentZoneId]!;
      for (final table in currentZoneTables) {
        // Una mesa con sesion abierta pero sin items+orders es "ocupada
        // fantasma" — el cajero la abrio, no agrego nada y salio. La
        // cuenta como disponible para que el contador refleje el estado
        // real, y la limpieza periodica del viewmodel cierra la sesion
        // huerfana en background.
        if (_isEffectivelyEmpty(table)) {
          availableCount++;
        } else {
          occupiedCount++;
        }
      }
    }

    _updateTabController(zones);

    Widget body;
    if (!hasZones) {
      if (isZoneLoading) {
        body = const ZoneGridSkeleton();
      } else if (zoneError != null) {
        body = _buildErrorState(zoneError);
      } else {
        body = _buildEmptyState(
          'No hay zonas configuradas',
          icon: Icons.location_off,
        );
      }
    } else {
      body = TabBarView(
        controller: _tabController!,
        children: zones
            .map(
              (zone) => viewMode == SalesZoneViewMode.map
                  ? _ZoneFloorMapView(
                      zoneId: zone.id,
                      canOpenTables: isCashOpen,
                    )
                  : _ZoneGrid(zoneId: zone.id, canOpenTables: isCashOpen),
            )
            .toList(),
      );
    }

    final isCompact = ResponsiveHelper.isMobile(context);

    Widget buildZoneTabs() {
      return Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: SalesTheme.secondary,
          borderRadius: BorderRadius.circular(12),
        ),
        // Wrap (no Row) para que cuando las zonas no quepan en una línea
        // pasen automáticamente a una segunda fila en vez de hacer
        // scroll horizontal. `runSpacing` deja un respiro entre filas
        // cuando hay wrap; `spacing: 0` mantiene el look pegado de los
        // tabs cuando caben en una sola línea (el padding interno de
        // cada chip ya genera el separador visual).
        child: Wrap(
          spacing: 0,
          runSpacing: 4,
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
                  padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 12 : 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isActive
                        ? SalesTheme.cardBackground
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 2,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    zone.name,
                    style: TextStyle(
                      fontSize: isCompact ? 13 : 14,
                      fontWeight: FontWeight.w500,
                      color: isActive
                          ? SalesTheme.foreground
                          : SalesTheme.mutedForeground,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      );
    }

    Widget buildIndicators() {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isCashOpen) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.red.withValues(alpha: 0.22),
                ),
              ),
              child: Text(
                isCompact ? 'Cerrada' : 'Caja cerrada',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.red,
                ),
              ),
            ),
            SizedBox(width: isCompact ? 8 : 12),
          ],
          _buildStatusIndicator(
            count: availableCount,
            label: isCompact ? '' : 'disponible',
            color: SalesTheme.success,
          ),
          SizedBox(width: isCompact ? 8 : 16),
          _buildStatusIndicator(
            count: occupiedCount,
            label: isCompact ? '' : 'ocupada',
            color: SalesTheme.warning,
          ),
          if (!isCompact) ...[
            const SizedBox(width: 16),
            const SalesZoomControl(),
            const SizedBox(width: 12),
          ] else
            const SizedBox(width: 8),
          // Toggle cuadrícula ↔ floor map. Mantiene el grid histórico y
          // permite ver las mesas en su posición física del salón.
          IconButton(
            onPressed: () =>
                ref.read(salesViewModeProvider.notifier).toggle(),
            icon: Icon(
              viewMode == SalesZoneViewMode.map
                  ? Icons.grid_view_rounded
                  : Icons.map_outlined,
              size: 20,
              color: SalesTheme.mutedForeground,
            ),
            tooltip: viewMode == SalesZoneViewMode.map
                ? 'Ver en cuadrícula'
                : 'Ver plano del salón',
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(
              minWidth: 36,
              minHeight: 36,
            ),
          ),
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
      );
    }

    PreferredSizeWidget? appBarWidget;
    if (hasZones && _tabController != null) {
      if (isCompact) {
        appBarWidget = PreferredSize(
          preferredSize: const Size.fromHeight(152),
          child: AppBar(
            backgroundColor: SalesTheme.background,
            elevation: 0,
            automaticallyImplyLeading: false,
            toolbarHeight: 152,
            titleSpacing: 0,
            title: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Tabs de zonas: ya no scrollean horizontal, hacen wrap
                  // a una segunda fila cuando no caben. La altura del
                  // AppBar (152) cubre hasta 2 filas de tabs + 1 fila de
                  // indicadores en mobile.
                  buildZoneTabs(),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: buildIndicators(),
                  ),
                ],
              ),
            ),
          ),
        );
      } else {
        // Anti-overflow: las tabs hacen Wrap automático a una 2da fila
        // cuando no caben (pantallas chicas tipo 1024×768 con muchas
        // zonas). Indicadores se quedan fijos a la derecha. Subimos
        // `toolbarHeight` para que cuando se dispare el wrap haya
        // espacio para la 2da fila — si solo hay una fila, queda un
        // poco de aire arriba/abajo, prefiero eso a recortar texto.
        final isCompactDesk = ResponsiveHelper.isCompactDesktop(context);
        final hPadding = isCompactDesk ? 16.0 : 24.0;
        appBarWidget = AppBar(
          backgroundColor: SalesTheme.background,
          elevation: 0,
          automaticallyImplyLeading: false,
          toolbarHeight: 80,
          titleSpacing: 0,
          title: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: hPadding,
              vertical: 8,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: buildZoneTabs()),
                const SizedBox(width: 12),
                buildIndicators(),
              ],
            ),
          ),
        );
      }
    }

    final isOffline = ref.watch(byZoneVmProvider.select((s) => s.isOffline));
    final lastSyncAt =
        ref.watch(byZoneVmProvider.select((s) => s.lastSyncAt));

    return Scaffold(
      backgroundColor: SalesTheme.background,
      appBar: appBarWidget,
      body: RefreshIndicator(
        color: SalesTheme.primary,
        onRefresh: () async {
          await ref.read(byZoneVmProvider.notifier).load(widget.businessId);
        },
        child: Column(
          children: [
            if (isOffline)
              _OfflineBanner(lastSyncAt: lastSyncAt),
            Expanded(child: body),
          ],
        ),
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
          label.isEmpty
              ? '$count'
              : '$count $label${count != 1 ? 's' : ''}',
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
  final bool canOpenTables;
  const _ZoneGrid({required this.zoneId, required this.canOpenTables});

  @override
  ConsumerState<_ZoneGrid> createState() => _ZoneGridState();
}

class _ZoneGridState extends ConsumerState<_ZoneGrid> {
  Timer? _zoneRefreshTimer;
  static const Duration _zoneRefreshInterval = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    _startZoneRefresh();
  }

  void _startZoneRefresh() {
    _zoneRefreshTimer?.cancel();
    // PERF: load() ya trae el estado de TODAS las zonas en 1 consulta
    // business-wide. Si esa consulta viene en camino (o ya llegó), no
    // dispares otra por zona al montar — pinta lo que hay y deja el
    // refresh periódico. Solo consulta directo si no hay nada (p.ej. la
    // consulta global falló).
    final vm = ref.read(byZoneVmProvider.notifier);
    final hasData = ref
        .read(byZoneVmProvider)
        .statusByZone
        .containsKey(widget.zoneId);
    if (!hasData && !vm.isBusinessStatusFetchInFlight) {
      vm.loadZoneStatus(widget.zoneId);
    }
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
    // Only rebuild when this specific zone's tables change
    final tables = ref.watch(
      byZoneVmProvider.select((s) => s.statusByZone[widget.zoneId]),
    );
    final zoneLoading = ref.watch(byZoneVmProvider.select((s) => s.loading));
    final zoneError = ref.watch(
      byZoneVmProvider.select((s) => s.errorByZone[widget.zoneId]),
    );

    if (tables == null) {
      return const ZoneTablesSkeleton();
    }

    if (zoneError != null && !zoneLoading && tables.isEmpty) {
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
        // 2026-05-13: el control de zoom se mudó al AppBar superior
        // (al lado de los indicadores disponible/ocupada), para que sea
        // accesible globalmente sin duplicarse en cada zone grid.
        if (!widget.canOpenTables)
          Builder(
            builder: (innerContext) {
              // Si el usuario tiene `caja.apertura`, el banner es clickeable
              // y abre el modal directo desde aqui — evita el viaje
              // Caja > Abrir > volver. Owners y cajeros con permiso lo ven
              // como CTA. Sin permiso, queda como aviso pasivo.
              final canOpenCash = ref
                  .read(sessionProvider.notifier)
                  .hasPermission('caja.apertura');
              final card = Container(
                margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(
                      canOpenCash ? Icons.lock_open : Icons.lock_outline,
                      size: 16,
                      color: Colors.red,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        canOpenCash
                            ? 'Caja cerrada — toca para abrir'
                            : 'Caja cerrada. Abre caja para abrir mesas.',
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (canOpenCash) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: Colors.red,
                      ),
                    ],
                  ],
                ),
              );
              if (!canOpenCash) return card;
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  showDialog(
                    context: innerContext,
                    barrierDismissible: false,
                    builder: (_) => const OpenCashDialog(),
                  );
                },
                child: card,
              );
            },
          ),
        // Eliminamos los indicadores de estado aquí, ya que están en el AppBar
        // y se actualizarán dinámicamente según la zona seleccionada
        // Grid
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = ResponsiveHelper.isMobile(context);
              // Zoom factor: lee `salesZoomProvider`. Aplica el multiplicador
              // sobre el ancho base 220 para que el cajero pueda ajustar la
              // densidad del grid (mas columnas con zoom out, menos con
              // zoom in). Persistente via shared_preferences.
              final zoom = ref.watch(salesZoomProvider);
              // Monitores cuadrados 1024×768 entran como compactDesktop:
              // padding y gap reducidos respecto al desktop grande, sin
              // forzar el modo mobile (que cambia el shell completo).
              final isCompactDesk = ResponsiveHelper.isCompactDesktop(context);

              final padding = isCompact
                  ? const EdgeInsets.fromLTRB(12, 6, 12, 12)
                  : isCompactDesk
                      ? const EdgeInsets.fromLTRB(14, 4, 14, 14)
                      : const EdgeInsets.fromLTRB(24, 4, 24, 24);
              final horizontalPad = isCompact
                  ? 24.0
                  : isCompactDesk
                      ? 28.0
                      : 48.0;
              final gap = isCompactDesk ? 12.0 : SalesTheme.gridGap;
              // compactDesk usaba 110px, pero el TableCard internamente se
              // dibuja a 140 (SalesTheme.tableCardHeight). El delta de 30px
              // hacía que el nombre del mesero/cliente se desbordara por
              // debajo del borde del card en tablets que caen en este bucket.
              // Unificamos a 140 para que el grid y el card hablen el mismo idioma.
              final cardHeight = SalesTheme.tableCardHeight;
              final baseCardWidth = isCompactDesk ? 180.0 : 220.0;
              final availableWidth = constraints.maxWidth - horizontalPad;

              int columns;
              if (isCompact) {
                columns = 2;
              } else {
                columns =
                    ((availableWidth + gap) /
                            ((baseCardWidth * zoom) + gap))
                        .floor()
                        .clamp(1, 10);
              }

              // Calcular el ancho REAL de cada card
              final totalGaps = (columns - 1) * gap;
              final cardWidth = (availableWidth - totalGaps) / columns;

              // Calcular aspect ratio dinámico: cardWidth / cardHeight
              final aspectRatio = cardWidth / cardHeight;

              return GridView.builder(
                padding: padding,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: aspectRatio, // Dinámico
                  crossAxisSpacing: gap,
                  mainAxisSpacing: gap,
                ),
                itemCount: tables.length,
                itemBuilder: (context, index) {
                  final table = tables[index];
                  final opening = ref
                      .watch(byZoneVmProvider.select(
                        (s) => s.openingTables.contains(table.tableId),
                      ));
                  return TableCard(
                    table: ventasTableFromStatus(table),
                    isOpening: opening,
                    enabled: widget.canOpenTables,
                    onTap: widget.canOpenTables
                        ? () => _handleTableAction(context, ref, table)
                        : null,
                    // PRD-12 F3: long-press en mesa ocupada → unir con
                    // otra mesa ocupada. Solo activo cuando la mesa
                    // tiene sesión abierta (sessionId != null).
                    // No permitir "unir mesas" sobre un borrador local sin
                    // sincronizar: no existe sesión real en el server que
                    // fusionar (rompería). Solo mesas con sesión real.
                    onLongPress:
                        widget.canOpenTables &&
                            table.sessionId != null &&
                            !table.isPendingSync
                        ? () =>
                            _handleMergeTable(context, ref, table, widget.zoneId)
                        : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Vista de floor map de una zona. Espejo de [_ZoneGrid] (mismo refresh
/// de 10s, mismos handlers de cajero) pero dibujando las mesas en su
/// posición física en vez de en cuadrícula. Reúsa la geometría que el
/// viewmodel cargó en `layoutByZone` y la fusiona con el estado en vivo
/// (`statusByZone`) por `tableId`.
class _ZoneFloorMapView extends ConsumerStatefulWidget {
  final String zoneId;
  final bool canOpenTables;

  /// Cuando es `true` (default) el mapa muestra el botón de expandir. En
  /// la vista a pantalla completa se pasa `false` para no anidar otro.
  final bool allowExpand;

  const _ZoneFloorMapView({
    required this.zoneId,
    required this.canOpenTables,
    this.allowExpand = true,
  });

  @override
  ConsumerState<_ZoneFloorMapView> createState() => _ZoneFloorMapViewState();
}

class _ZoneFloorMapViewState extends ConsumerState<_ZoneFloorMapView> {
  Timer? _zoneRefreshTimer;
  static const Duration _zoneRefreshInterval = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    // Geometría fresca al montar (refleja ediciones hechas en Ajustes).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(byZoneVmProvider.notifier)
          .loadZoneLayout(widget.zoneId, force: true);
    });
    _startZoneRefresh();
  }

  void _startZoneRefresh() {
    _zoneRefreshTimer?.cancel();
    // PERF: mismo criterio que _ZoneGrid — el estado ya viene (o viene en
    // camino) en la consulta business-wide de load(); no duplicar.
    final vm = ref.read(byZoneVmProvider.notifier);
    final hasData = ref
        .read(byZoneVmProvider)
        .statusByZone
        .containsKey(widget.zoneId);
    if (!hasData && !vm.isBusinessStatusFetchInFlight) {
      vm.loadZoneStatus(widget.zoneId);
    }
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
    final status = ref.watch(
      byZoneVmProvider.select((s) => s.statusByZone[widget.zoneId]),
    );
    final layout = ref.watch(
      byZoneVmProvider.select((s) => s.layoutByZone[widget.zoneId]),
    );
    final openingTables = ref.watch(
      byZoneVmProvider.select((s) => s.openingTables),
    );

    // Esperamos a tener la geometría (fuente de las posiciones). El
    // estado puede llegar después; las mesas sin fila de estado se pintan
    // como disponibles.
    if (layout == null || status == null) {
      return const ZoneTablesSkeleton();
    }

    if (layout.isEmpty) {
      return const Center(child: Text('No hay mesas en esta zona'));
    }

    final statusByTableId = {for (final ts in status) ts.tableId: ts};

    return Column(
      children: [
        if (!widget.canOpenTables)
          Container(
            margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: Colors.red),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Caja cerrada. Abre caja para abrir mesas.',
                    style: TextStyle(
                      color: Colors.red,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ZoneFloorMap(
            tables: layout,
            statusByTableId: statusByTableId,
            openingTableIds: openingTables,
            enabled: widget.canOpenTables,
            onTapTable: (ts) => _handleTableAction(context, ref, ts),
            onLongPressTable: (ts) =>
                _handleMergeTable(context, ref, ts, widget.zoneId),
            onExpand: widget.allowExpand ? () => _openFullscreen() : null,
          ),
        ),
      ],
    );
  }

  /// Abre el plano a pantalla completa en una ruta nueva. Reusa la misma
  /// vista (con su realtime y handlers) pero sin el botón de expandir.
  void _openFullscreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: SalesTheme.background,
          appBar: AppBar(
            backgroundColor: SalesTheme.background,
            elevation: 0,
            title: const Text(
              'Plano del salón',
              style: TextStyle(
                color: SalesTheme.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            iconTheme: const IconThemeData(color: SalesTheme.foreground),
          ),
          body: _ZoneFloorMapView(
            zoneId: widget.zoneId,
            canOpenTables: widget.canOpenTables,
            allowExpand: false,
          ),
        ),
      ),
    );
  }
}

/// PRD-12 F3: long-press en mesa ocupada → abre dialog "Unir mesas"
/// en modo `mergeOnly`. Solo lista mesas también ocupadas como
/// destino. Tras un merge exitoso refresca la zona [zoneId] (mesa
/// origen quedó vacía) — la zona destino se refresca al volver.
///
/// Top-level para compartirse entre el grid ([_ZoneGrid]) y el floor
/// map ([_ZoneFloorMapView]) sin duplicar el flujo de cajero.
Future<void> _handleMergeTable(
  BuildContext context,
  WidgetRef ref,
  TableStatus ts,
  String zoneId,
) async {
    final messenger = ScaffoldMessenger.of(context);
    final sessionId = ts.sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Esta mesa no tiene cuenta abierta para unir.'),
        ),
      );
      return;
    }

    // Resolver businessId vía resolver canónico.
    final String businessId;
    try {
      businessId = await BusinessResolver.ensure('auto');
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('No se pudo identificar el negocio: $e'),
        ),
      );
      return;
    }
    if (!context.mounted) return;

    final tableLabel = ts.code;

    final merged = await showTransferSessionDialog(
      context,
      ref,
      businessId: businessId,
      sourceSessionId: sessionId,
      sourceTableId: ts.tableId,
      sourceTableLabel: tableLabel,
      // En modo merge no mostramos items individuales — siempre va
      // toda la cuenta. Pasamos lista vacía para no cargar nada extra.
      items: const [],
      mergeOnly: true,
    );

    if (!merged) return;
    if (!context.mounted) return;

    // Refrescar la zona actual: la mesa origen ya no tiene cuenta.
    await ref
        .read(byZoneVmProvider.notifier)
        .loadZoneStatus(zoneId, emitError: false);
  }

  Future<void> _handleTableAction(
    BuildContext context,
    WidgetRef ref,
    TableStatus ts,
  ) async {
    final cashierVm = ref.read(cashierViewModelProvider);
    final isCashOpen = await cashierVm.ensureCashOpenFast();
    if (!isCashOpen) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Debes abrir la caja antes de abrir una mesa.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final byZone = ref.read(byZoneVmProvider.notifier);
    final opening = ref
        .read(byZoneVmProvider)
        .openingTables
        .contains(ts.tableId);
    if (opening) return;

    byZone.setOpening(ts.tableId, true);

    final session = ref.read(sessionProvider);
    final businessIdForGate = ref.read(byZoneVmProvider).businessId ??
        session.activeBusinessId;

    // ── Multimesero gate ──────────────────────────────────────────────
    // Si el negocio tiene multimesero activo, este flujo identifica al
    // mesero ANTES de navegar a la mesa. Reemplaza al check legacy de
    // "otro mesero" (que pide PIN del usuario logueado) por uno que
    // valida CUALQUIER PIN de empleado activo y guarda el "active waiter"
    // del dispositivo.
    //   - Mesa nueva → siempre pide PIN para identificar al opener.
    //   - Mesa existente abierta por el activeWaiter → pasa directo.
    //   - Mesa existente abierta por otro → pide PIN para identificar al
    //     que entra (sin cambiar el opened_by original).
    //
    // SOLO APLICA AL ROL `mesero`. Owner/admin/manager/cajero operan en
    // nombre del negocio y no necesitan identificarse vía PIN —
    // entran a cualquier mesa directo. El cajero también porque suele
    // hacer cobros en cualquier mesa sin importar qué mesero la abrió.
    bool multimeseroEnabled = false;
    final isWaiterRole = session.activeRole == PosRole.mesero;
    if (isWaiterRole && businessIdForGate != null && businessIdForGate.isNotEmpty) {
      try {
        multimeseroEnabled = await ref
            .read(multimeseroRepositoryProvider)
            .isEnabled(businessIdForGate);
      } catch (_) {
        // Si la lectura falla, asumimos OFF para no romper el flujo
        // operativo. El admin verá que el toggle no toma efecto y reabre
        // el setting.
        multimeseroEnabled = false;
      }
    }

    if (multimeseroEnabled && businessIdForGate != null) {
      // Siempre pedir PIN cuando el rol del device es mesero y multimesero
      // está activo. Antes había un short-circuit que comparaba el
      // `activeWaiter` cacheado contra el `opened_by_employee_id` de la
      // sesión y si coincidía, dejaba pasar sin PIN. Eso causaba el bug
      // de "a veces pide, a veces no" porque el cache sobrevivía entre
      // taps. El feature de multimesero existe para AUDITAR quién accede
      // a cada mesa — la única forma de garantizar la auditoría es
      // pedir PIN en cada entrada.
      if (!context.mounted) {
        byZone.setOpening(ts.tableId, false);
        return;
      }
      final waiter = await showWaiterPinModal(
        context,
        ref,
        businessId: businessIdForGate,
        title: ts.sessionId == null
            ? 'Identifícate'
            : 'Identifícate para entrar',
        subtitle: ts.sessionId == null
            ? 'Ingresa tu PIN para abrir la mesa ${ts.code}'
            : 'Ingresa tu PIN para registrar tu actividad en la mesa ${ts.code}',
      );
      if (waiter == null) {
        byZone.setOpening(ts.tableId, false);
        return;
      }
    }

    // Mesa ocupada por otro mesero (LEGACY — solo cuando multimesero está OFF):
    // - el dueño entra sin PIN
    // - admin/supervisor/cajero pueden abrir cualquier mesa sin PIN extra
    // - otro mesero puede entrar, usando SU propio PIN
    final isOtherWaiterTable =
        !multimeseroEnabled && ts.sessionId != null && !ts.isOwn;
    final canBypassPin =
        session.activeRole == PosRole.administrador ||
        session.activeRole == PosRole.supervisor ||
        session.activeRole == PosRole.cajero;
    final isWaiter = session.activeRole == PosRole.mesero;
    if (isOtherWaiterTable && !isWaiter && !canBypassPin) {
      if (!context.mounted) {
        byZone.setOpening(ts.tableId, false);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Solo administradores, supervisores, cajeros u otro mesero con PIN pueden abrir esta mesa.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      byZone.setOpening(ts.tableId, false);
      return;
    }
    if (isOtherWaiterTable && isWaiter && !canBypassPin) {
      if (!context.mounted) {
        byZone.setOpening(ts.tableId, false);
        return;
      }
      final authorized = await showCurrentUserPinVerificationModal(
        context,
        ref,
        title: 'Mesa de otro mesero',
        subtitle:
            'Ingresa tu PIN para abrir esta mesa. El acceso quedará registrado con tu usuario.',
      );
      if (!authorized) {
        byZone.setOpening(ts.tableId, false);
        return;
      }

      final sessionId = ts.sessionId;
      if (sessionId != null && sessionId.isNotEmpty) {
        try {
          final repo = ref.read(salesRepositoryProvider);
          final currentSession = await repo.getSessionCustomer(
            sessionId,
            businessId: session.activeBusinessId,
          );
          final currentNote = currentSession.note?.trim();
          final actorName = session.userName?.trim().isNotEmpty == true
              ? session.userName!.trim()
              : 'Usuario';
          final ownerName = ts.waiterName?.trim().isNotEmpty == true
              ? ts.waiterName!.trim()
              : 'otro mesero';
          final stamp = DateTime.now().toLocal().toIso8601String();
          final auditLine =
              '[ACCESO_MESA][$stamp] $actorName accedió a la mesa ${ts.code} asignada a $ownerName';
          final nextNote = (currentNote == null || currentNote.isEmpty)
              ? auditLine
              : '$currentNote\n$auditLine';
          await repo.updateSessionNote(
            sessionId: sessionId,
            note: nextNote,
            businessId: session.activeBusinessId,
          );
        } catch (_) {
          // No bloqueamos la operación si falla la auditoría.
        }
      }
    }

    int peopleCount = 1;
    if (ts.sessionId == null) {
      final businessId =
          ref.read(byZoneVmProvider).businessId ??
          ref.read(sessionProvider).activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        final promptEnabled = await ref
            .read(posSettingsRepositoryProvider)
            .getPromptPeopleCountOnTableOpen(businessId);
        if (promptEnabled) {
          if (!context.mounted) {
            byZone.setOpening(ts.tableId, false);
            return;
          }
          final requestedCount = await _promptPeopleCount(context, ts.code);
          if (requestedCount == null) {
            byZone.setOpening(ts.tableId, false);
            return;
          }
          peopleCount = requestedCount;
        }
      }
    }

    // La apertura de mesa ocurre en TableOrderScreen; evitar doble openTable.
    byZone.setOpening(ts.tableId, false);
    if (!context.mounted) return;
    context.go(
      Uri(
        path: '${AppRoutes.sales}/table/${ts.tableId}',
        queryParameters: {
          'code': ts.code,
          'zone': ts.zoneId,
          'guests': peopleCount.toString(),
        },
      ).toString(),
    );
  }

  Future<int?> _promptPeopleCount(
    BuildContext context,
    String tableCode,
  ) async {
    final controller = TextEditingController(text: '1');
    final focusNode = FocusNode();

    final result = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (focusNode.canRequestFocus) {
            focusNode.requestFocus();
            controller.selection = TextSelection(
              baseOffset: 0,
              extentOffset: controller.text.length,
            );
          }
        });
        return AlertDialog(
          title: Text('Abrir Mesa $tableCode'),
          content: SizedBox(
            width: 320,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: false,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Cantidad de personas',
                hintText: 'Ej. 4',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) {
                final parsed = int.tryParse(controller.text.trim());
                if (parsed != null && parsed > 0) {
                  Navigator.of(dialogContext).pop(parsed);
                }
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = int.tryParse(controller.text.trim());
                if (parsed == null || parsed <= 0) return;
                Navigator.of(dialogContext).pop(parsed);
              },
              child: const Text('Abrir mesa'),
            ),
          ],
        );
      },
    );

    controller.dispose();
    focusNode.dispose();
    return result;
  }

class _OfflineBanner extends StatelessWidget {
  final DateTime? lastSyncAt;

  const _OfflineBanner({this.lastSyncAt});

  String _formatLastSync(DateTime ts) {
    final diff = DateTime.now().difference(ts);
    if (diff.inSeconds < 60) return 'hace unos segundos';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return 'hace $h ${h == 1 ? 'hora' : 'horas'}';
    }
    final d = diff.inDays;
    return 'hace $d ${d == 1 ? 'dia' : 'dias'}';
  }

  @override
  Widget build(BuildContext context) {
    final syncLabel = lastSyncAt == null
        ? 'Sin conexion'
        : 'Sin conexion — datos guardados ${_formatLastSync(lastSyncAt!)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: SalesTheme.warning.withValues(alpha: 0.12),
        border: Border(
          bottom: BorderSide(
            color: SalesTheme.warning.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 18, color: SalesTheme.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              syncLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: SalesTheme.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
