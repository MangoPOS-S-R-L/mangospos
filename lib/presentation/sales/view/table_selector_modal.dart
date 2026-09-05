// PRD 4 — F4.4.2 / F4.4.3
//
// Bottom sheet que permite asignar una orden Manual a una mesa.
//
// Flujo:
//   1. Carga zonas activas del negocio.
//   2. Por cada zona, carga lazy las mesas (caché en memoria).
//   3. Las mesas `available` son tappables; el resto se muestra en gris.
//   4. Tap → confirm → `assignManualOrderToTable(orderId, tableId)`
//      (RPC backend convierte origin manual→table y abre la mesa).
//   5. Modal se cierra; OrderScreen reacciona al cambio de origin.
//
// Reglas:
//   - NO toca `table_order_screen.dart` (regla cardinal del PRD 4).
//   - Reutiliza `ZonesRepository` y `assignManualOrderToTable` existentes.
//   - Sólo visible cuando origin == 'manual'.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/data/models/dining_table.dart';
import 'package:mangopos/data/models/zone.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

class TableSelectorModal extends ConsumerStatefulWidget {
  final String orderId;
  final VoidCallback? onAssigned;

  const TableSelectorModal({
    super.key,
    required this.orderId,
    this.onAssigned,
  });

  @override
  ConsumerState<TableSelectorModal> createState() => _TableSelectorModalState();
}

class _TableSelectorModalState extends ConsumerState<TableSelectorModal>
    with SingleTickerProviderStateMixin {
  Future<List<Zone>>? _zonesFuture;
  final Map<String, Future<List<DiningTable>>> _tablesByZone = {};
  TabController? _tabController;
  List<Zone> _zones = const [];
  bool _assigning = false;

  @override
  void initState() {
    super.initState();
    _zonesFuture = _loadZones();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  Future<List<Zone>> _loadZones() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      throw Exception('Sin negocio activo.');
    }
    final repo = ref.read(zonesRepoProvider);
    return repo.fetchZones(businessId);
  }

  Future<List<DiningTable>> _tablesFor(String zoneId) {
    return _tablesByZone.putIfAbsent(
      zoneId,
      () => ref.read(zonesRepoProvider).fetchTablesByZone(zoneId),
    );
  }

  Future<void> _handleAssign(DiningTable table) async {
    if (_assigning) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Asignar a mesa'),
        content: Text(
          '¿Asignar esta venta manual a la mesa ${table.label ?? table.code}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Asignar'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _assigning = true);
    try {
      await ref
          .read(currentOrderProvider.notifier)
          .assignManualOrderToTable(orderId: widget.orderId, tableId: table.id);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onAssigned?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _assigning = false);
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(
          content: Text('No se pudo asignar la mesa: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1),
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Asignar a mesa',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: _assigning ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            tooltip: 'Cerrar',
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return FutureBuilder<List<Zone>>(
      future: _zonesFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorState(
            message: 'Error al cargar zonas: ${snap.error}',
            onRetry: () => setState(() => _zonesFuture = _loadZones()),
          );
        }
        final zones = snap.data ?? const <Zone>[];
        if (zones.isEmpty) {
          return const _EmptyState(
            message:
                'No hay zonas configuradas. Configurá zonas y mesas en Ajustes.',
          );
        }

        if (_tabController == null || _zones.length != zones.length) {
          _tabController?.dispose();
          _tabController = TabController(length: zones.length, vsync: this);
          _zones = zones;
        }

        if (zones.length == 1) {
          return _ZoneTablesView(
            zoneId: zones.first.id,
            tablesFor: _tablesFor,
            onSelect: _handleAssign,
            disabled: _assigning,
          );
        }

        return Column(
          children: [
            TabBar(
              controller: _tabController,
              isScrollable: true,
              labelColor: MangoColors.primaryOrange,
              unselectedLabelColor: const Color(0xFF7A7A7A),
              indicatorColor: MangoColors.primaryOrange,
              tabs: zones.map((z) => Tab(text: z.name)).toList(),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: zones
                    .map(
                      (z) => _ZoneTablesView(
                        zoneId: z.id,
                        tablesFor: _tablesFor,
                        onSelect: _handleAssign,
                        disabled: _assigning,
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ZoneTablesView extends StatelessWidget {
  final String zoneId;
  final Future<List<DiningTable>> Function(String zoneId) tablesFor;
  final void Function(DiningTable) onSelect;
  final bool disabled;

  const _ZoneTablesView({
    required this.zoneId,
    required this.tablesFor,
    required this.onSelect,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DiningTable>>(
      future: tablesFor(zoneId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorState(message: 'Error: ${snap.error}');
        }
        final tables = snap.data ?? const <DiningTable>[];
        if (tables.isEmpty) {
          return const _EmptyState(message: 'No hay mesas en esta zona.');
        }

        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1,
          ),
          itemCount: tables.length,
          itemBuilder: (context, index) {
            final t = tables[index];
            return _TableCard(
              table: t,
              onTap: (t.state == TableState.available && !disabled)
                  ? () => onSelect(t)
                  : null,
            );
          },
        );
      },
    );
  }
}

class _TableCard extends StatelessWidget {
  final DiningTable table;
  final VoidCallback? onTap;

  const _TableCard({required this.table, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isAvailable = table.state == TableState.available;
    final stateLabel = _stateLabel(table.state);
    final stateColor = _stateColor(table.state);

    return Material(
      color: isAvailable ? Colors.white : const Color(0xFFF5F5F5),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: isAvailable
                  ? MangoColors.primaryOrange.withValues(alpha: 0.3)
                  : const Color(0xFFE5E7EB),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                table.shape == TableShape.circle
                    ? Icons.circle_outlined
                    : Icons.crop_square,
                color: isAvailable
                    ? MangoColors.primaryOrange
                    : const Color(0xFF9CA3AF),
                size: 32,
              ),
              const SizedBox(height: 6),
              Text(
                table.label ?? table.code,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isAvailable
                      ? const Color(0xFF2C2C2C)
                      : const Color(0xFF9CA3AF),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'Cap. ${table.capacity}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A7A)),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  stateLabel,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: stateColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _stateLabel(TableState s) {
    switch (s) {
      case TableState.available:
        return 'Libre';
      case TableState.occupied:
        return 'Ocupada';
      case TableState.reserved:
        return 'Reservada';
      case TableState.blocked:
        return 'Bloqueada';
    }
  }

  /// Mismos colores de estado que las cards del salón (ver
  /// `table_status_style.dart`): verde libre, ámbar ocupada, violeta
  /// reservada. Gris queda solo para la mesa bloqueada, que no es un
  /// estado del salón.
  Color _stateColor(TableState s) {
    switch (s) {
      case TableState.available:
        return AppColors.success;
      case TableState.occupied:
        return AppColors.warning;
      case TableState.reserved:
        return AppColors.reserved;
      case TableState.blocked:
        return const Color(0xFF6B7280);
    }
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF7A7A7A)),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const _ErrorState({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Color(0xFFEF4444)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF7A7A7A)),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('Reintentar')),
            ],
          ],
        ),
      ),
    );
  }
}
