// Sprint 3 Inventario — Vista Kardex.
//
// Historial completo de movimientos con saldo corrido y filtros por:
//   - Insumo (dropdown)
//   - Bodega (dropdown)
//   - Tipo de movimiento (dropdown)
//   - Rango de fechas (desde / hasta)
//
// El usuario que registró el movimiento se muestra en cada fila pero no se
// expone como filtro en esta primera entrega (requiere selector de empleados
// con permisos — se deja para una mejora futura).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../state/inventory_state.dart';
import '../state/kardex_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../viewmodel/kardex_viewmodel.dart';

class InventoryKardexView extends ConsumerStatefulWidget {
  const InventoryKardexView({super.key});

  @override
  ConsumerState<InventoryKardexView> createState() =>
      _InventoryKardexViewState();
}

class _InventoryKardexViewState extends ConsumerState<InventoryKardexView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // El kardex consume catálogo de items + bodegas para llenar dropdowns.
      await ref.read(inventoryViewModelProvider).init();
      await ref.read(kardexViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final kvm = ref.watch(kardexViewModelProvider);
    final ivm = ref.watch(inventoryViewModelProvider);
    final kstate = kvm.state;
    final istate = ivm.state;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            onRefresh: kstate.loading ? null : () => kvm.refresh(),
            count: kstate.movements.length,
            hasMore: kstate.hasMore,
          ),
          _FiltersBar(
            filters: kstate.filters,
            items: istate.items,
            warehouses: istate.warehouses,
            onChanged: (f) => kvm.applyFilters(f),
          ),
          if (kstate.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red.shade50,
              child: Text(
                kstate.error!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          Expanded(
            child: kstate.loading && kstate.movements.isEmpty
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : kstate.movements.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        kstate.filters.isEmpty
                            ? 'Aún no hay movimientos registrados.'
                            : 'Ningún movimiento coincide con los filtros aplicados.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.mutedForeground,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  )
                : _MovementsList(
                    movements: kstate.movements,
                    hasMore: kstate.hasMore,
                    loadingMore: kstate.loadingMore,
                    onLoadMore: () => kvm.loadMore(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback? onRefresh;
  final int count;
  final bool hasMore;
  const _Header({
    required this.onRefresh,
    required this.count,
    required this.hasMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Kardex',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Historial de movimientos con saldo corrido por bodega e insumo.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count movimiento(s)${hasMore ? ' · hay más por cargar' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refrescar',
          ),
        ],
      ),
    );
  }
}

const _movementTypeOptions = <(String code, String label)>[
  ('', 'Todos'),
  ('purchase', 'Compra'),
  ('sale', 'Venta'),
  ('adjustment', 'Ajuste'),
  ('transfer_in', 'Entrada de traslado'),
  ('transfer_out', 'Salida de traslado'),
  ('waste', 'Merma / Salida'),
  ('return', 'Devolución'),
];

String _movementTypeLabel(String code) {
  for (final entry in _movementTypeOptions) {
    if (entry.$1 == code) return entry.$2;
  }
  return code;
}

class _FiltersBar extends StatelessWidget {
  final KardexFilters filters;
  final List<InventoryItemSummary> items;
  final List<InventoryWarehouse> warehouses;
  final ValueChanged<KardexFilters> onChanged;

  const _FiltersBar({
    required this.filters,
    required this.items,
    required this.warehouses,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: 240,
            child: DropdownButtonFormField<String>(
              initialValue: filters.itemId ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Insumo',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('Todos')),
                ...items.map(
                  (i) => DropdownMenuItem(
                    value: i.id,
                    child: Text(i.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (v) => onChanged(
                filters.copyWith(
                  itemId: v == null || v.isEmpty ? null : v,
                  clearItemId: v == null || v.isEmpty,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String>(
              initialValue: filters.warehouseId ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Bodega',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('Todas')),
                ...warehouses.map(
                  (w) => DropdownMenuItem(
                    value: w.id,
                    child: Text(w.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (v) => onChanged(
                filters.copyWith(
                  warehouseId: v == null || v.isEmpty ? null : v,
                  clearWarehouseId: v == null || v.isEmpty,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String>(
              initialValue: filters.movementType ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Tipo',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: _movementTypeOptions
                  .map(
                    (e) => DropdownMenuItem(value: e.$1, child: Text(e.$2)),
                  )
                  .toList(growable: false),
              onChanged: (v) => onChanged(
                filters.copyWith(
                  movementType: v == null || v.isEmpty ? null : v,
                  clearMovementType: v == null || v.isEmpty,
                ),
              ),
            ),
          ),
          _DateRangeField(
            from: filters.from,
            to: filters.to,
            onChanged: (from, to) => onChanged(
              filters.copyWith(
                from: from,
                to: to,
                clearFrom: from == null,
                clearTo: to == null,
              ),
            ),
          ),
          if (!filters.isEmpty)
            TextButton.icon(
              onPressed: () => onChanged(const KardexFilters()),
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('Limpiar filtros'),
            ),
        ],
      ),
    );
  }
}

class _DateRangeField extends StatelessWidget {
  final DateTime? from;
  final DateTime? to;
  final void Function(DateTime? from, DateTime? to) onChanged;

  const _DateRangeField({
    required this.from,
    required this.to,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd/MM/yyyy');
    final label = (from == null && to == null)
        ? 'Rango de fechas'
        : '${from != null ? fmt.format(from!) : '—'}  →  ${to != null ? fmt.format(to!) : '—'}';
    return SizedBox(
      width: 280,
      child: OutlinedButton.icon(
        onPressed: () async {
          final now = DateTime.now();
          final range = await showDateRangePicker(
            context: context,
            firstDate: DateTime(now.year - 5),
            lastDate: DateTime(now.year + 1),
            initialDateRange: (from != null && to != null)
                ? DateTimeRange(start: from!, end: to!)
                : null,
            saveText: 'Aplicar',
          );
          if (range != null) {
            onChanged(
              DateTime(range.start.year, range.start.month, range.start.day),
              DateTime(
                range.end.year,
                range.end.month,
                range.end.day,
                23,
                59,
                59,
              ),
            );
          }
        },
        icon: const Icon(Icons.calendar_today_outlined, size: 16),
        label: Text(label, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          alignment: Alignment.centerLeft,
        ),
      ),
    );
  }
}

class _MovementsList extends StatelessWidget {
  final List<KardexMovement> movements;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  const _MovementsList({
    required this.movements,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    final showFooter = hasMore || loadingMore;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: movements.length + (showFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == movements.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: loadingMore
                  ? SizedBox(
                      height: 28,
                      width: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AppColors.primary,
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: onLoadMore,
                      icon: const Icon(Icons.expand_more_rounded, size: 18),
                      label: const Text('Cargar más'),
                    ),
            ),
          );
        }
        return _MovementCard(movement: movements[index]);
      },
    );
  }
}

class _MovementCard extends StatelessWidget {
  final KardexMovement movement;
  const _MovementCard({required this.movement});

  Color _typeColor() {
    if (movement.isInbound) return const Color(0xFF059669);
    if (movement.movementType == 'adjustment') {
      return movement.quantity >= 0
          ? const Color(0xFF2563EB)
          : const Color(0xFFB45309);
    }
    return const Color(0xFFDC2626);
  }

  IconData _typeIcon() {
    switch (movement.movementType) {
      case 'purchase':
        return Icons.shopping_cart_outlined;
      case 'sale':
        return Icons.point_of_sale_outlined;
      case 'transfer_in':
        return Icons.south_east_rounded;
      case 'transfer_out':
        return Icons.north_east_rounded;
      case 'waste':
        return Icons.delete_outline_rounded;
      case 'return':
        return Icons.assignment_return_outlined;
      case 'adjustment':
      default:
        return Icons.tune_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd/MM/yyyy HH:mm');
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    final color = _typeColor();
    final signedQty = movement.quantity;
    final qtyText = (signedQty > 0 ? '+' : '') + qtyFmt.format(signedQty);
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.soft,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_typeIcon(), color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          movement.itemName,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.foreground,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _movementTypeLabel(movement.movementType),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: color,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${movement.warehouseName}'
                    '${movement.createdByName != null ? ' · ${movement.createdByName}' : ''}'
                    '${movement.createdAt != null ? ' · ${dateFmt.format(movement.createdAt!.toLocal())}' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  if (movement.notes != null && movement.notes!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      movement.notes!,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: AppColors.mutedForeground,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$qtyText ${movement.itemUnit}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Saldo: ${qtyFmt.format(movement.runningBalance)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
