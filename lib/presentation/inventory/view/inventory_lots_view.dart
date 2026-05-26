// Sprint 4 Inventario — Vista de lotes y vencimientos (fase 1).
//
// Lista lotes registrados con su estado de vencimiento (fresh / warning /
// critical / expired / depleted / disposed). Permite filtrar por estado e
// insumo. Tap en una card abre el detail dialog con la opción "Disponer
// lote" (revierte saldo restante como ajuste negativo).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../state/inventory_state.dart';
import '../state/lots_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../viewmodel/lots_viewmodel.dart';

class InventoryLotsView extends ConsumerStatefulWidget {
  const InventoryLotsView({super.key});

  @override
  ConsumerState<InventoryLotsView> createState() =>
      _InventoryLotsViewState();
}

class _InventoryLotsViewState extends ConsumerState<InventoryLotsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // El catálogo de items/bodegas alimenta los dropdowns de filtros.
      await ref.read(inventoryViewModelProvider).init();
      await ref.read(lotsViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final lvm = ref.watch(lotsViewModelProvider);
    final ivm = ref.watch(inventoryViewModelProvider);
    final lstate = lvm.state;
    final istate = ivm.state;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            count: lstate.lots.length,
            hasMore: lstate.hasMore,
            onRefresh: lstate.loading ? null : () => lvm.refresh(),
          ),
          _FiltersBar(
            filters: lstate.filters,
            items: istate.items,
            warehouses: istate.warehouses,
            onChanged: (f) => lvm.applyFilters(f),
          ),
          if (lstate.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red.shade50,
              child: Text(
                lstate.error!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          Expanded(
            child: lstate.loading && lstate.lots.isEmpty
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : lstate.lots.isEmpty
                ? _EmptyState(hasFilter: !lstate.filters.isEmpty)
                : _LotsList(
                    lots: lstate.lots,
                    hasMore: lstate.hasMore,
                    loadingMore: lstate.loadingMore,
                    onLoadMore: () => lvm.loadMore(),
                    onTap: (l) => _openDetail(l),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(InventoryLot lot) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _LotDetailDialog(
        lot: lot,
        onDispose: lot.isActive ? () => _confirmDispose(lot) : null,
      ),
    );
  }

  Future<void> _confirmDispose(InventoryLot lot) async {
    Navigator.of(context).pop(); // cerrar el detail
    final reasonController = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disponer lote ${lot.lotNumber}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (lot.remainingQuantity > 0)
                Text(
                  'Se registrará un ajuste negativo de '
                  '${lot.remainingQuantity.toStringAsFixed(2)} ${lot.itemUnit} '
                  'en ${lot.warehouseName}. El lote queda como dispuesto.',
                  style: TextStyle(color: AppColors.mutedForeground),
                )
              else
                Text(
                  'El lote ya no tiene saldo. Solo se marcará como dispuesto '
                  'para auditoría.',
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Motivo (opcional)',
                  hintText: 'Ej: vencido, dañado, dado a empleado...',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sí, disponer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(lotsViewModelProvider)
          .disposeLot(
            lotId: lot.id,
            reason: reasonController.text.trim().isEmpty
                ? null
                : reasonController.text.trim(),
          );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('${lot.lotNumber} dispuesto')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

class _Header extends StatelessWidget {
  final int count;
  final bool hasMore;
  final VoidCallback? onRefresh;

  const _Header({
    required this.count,
    required this.hasMore,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lotes y vencimientos',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Insumos con tracking de lote (activar en el detalle del insumo).',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count lote(s)${hasMore ? ' · hay más por cargar' : ''}',
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

const _expiryFilters = <(String? code, String label, Color? color)>[
  (null, 'Todos', null),
  ('expired', 'Vencidos', Color(0xFFDC2626)),
  ('critical', 'Críticos (≤7d)', Color(0xFFEA580C)),
  ('warning', 'Por vencer (≤30d)', Color(0xFFCA8A04)),
  ('fresh', 'Frescos', Color(0xFF059669)),
  ('depleted', 'Agotados', null),
  ('disposed', 'Dispuestos', null),
];

class _FiltersBar extends ConsumerWidget {
  final LotsFilters filters;
  final List<InventoryItemSummary> items;
  final List<InventoryWarehouse> warehouses;
  final ValueChanged<LotsFilters> onChanged;

  const _FiltersBar({
    required this.filters,
    required this.items,
    required this.warehouses,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _expiryFilters
                .map(
                  (e) => _Chip(
                    label: e.$2,
                    selected: filters.expiryStatus == e.$1,
                    color: e.$3,
                    onTap: () => onChanged(
                      filters.copyWith(
                        expiryStatus: e.$1,
                        clearExpiryStatus: e.$1 == null,
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
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
                    ...items.where((i) => i.tracksLots).map(
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
              const SizedBox(width: 10),
              Expanded(
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
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.4)
                : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? accent : AppColors.foreground,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasFilter;
  const _EmptyState({required this.hasFilter});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inventory_outlined,
              size: 56,
              color: AppColors.mutedForeground,
            ),
            const SizedBox(height: 12),
            Text(
              hasFilter ? 'Sin lotes en este filtro' : 'Aún no hay lotes',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasFilter
                  ? 'Cambia los filtros para ver más resultados.'
                  : 'Activa el tracking de lotes en el detalle de un insumo, '
                        'después recibe mercancía con un número de lote y fecha '
                        'de vencimiento.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.mutedForeground, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _LotsList extends StatelessWidget {
  final List<InventoryLot> lots;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;
  final void Function(InventoryLot) onTap;

  const _LotsList({
    required this.lots,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final showFooter = hasMore || loadingMore;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: lots.length + (showFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == lots.length) {
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
        return _LotCard(lot: lots[index], onTap: () => onTap(lots[index]));
      },
    );
  }
}

({Color color, String label, IconData icon}) _expiryInfo(
  LotExpiryStatus status,
) {
  switch (status) {
    case LotExpiryStatus.expired:
      return (
        color: const Color(0xFFDC2626),
        label: 'VENCIDO',
        icon: Icons.error_rounded,
      );
    case LotExpiryStatus.critical:
      return (
        color: const Color(0xFFEA580C),
        label: 'CRÍTICO',
        icon: Icons.warning_amber_rounded,
      );
    case LotExpiryStatus.warning:
      return (
        color: const Color(0xFFCA8A04),
        label: 'POR VENCER',
        icon: Icons.schedule_rounded,
      );
    case LotExpiryStatus.fresh:
      return (
        color: const Color(0xFF059669),
        label: 'FRESCO',
        icon: Icons.check_circle_outline_rounded,
      );
    case LotExpiryStatus.depleted:
      return (
        color: const Color(0xFF6B7280),
        label: 'AGOTADO',
        icon: Icons.inventory_2_outlined,
      );
    case LotExpiryStatus.disposed:
      return (
        color: const Color(0xFF6B7280),
        label: 'DISPUESTO',
        icon: Icons.delete_outline_rounded,
      );
    case LotExpiryStatus.unknown:
      return (
        color: const Color(0xFF6B7280),
        label: '—',
        icon: Icons.help_outline_rounded,
      );
  }
}

class _LotCard extends StatelessWidget {
  final InventoryLot lot;
  final VoidCallback onTap;
  const _LotCard({required this.lot, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final info = _expiryInfo(lot.expiryStatus);
    final dateFmt = DateFormat('dd/MM/yyyy');
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
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
                  color: info.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(info.icon, color: info.color, size: 20),
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
                            lot.itemName,
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
                            color: info.color.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            info.label,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: info.color,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Lote ${lot.lotNumber}  ·  ${lot.warehouseName}',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      lot.expiryDate != null
                          ? 'Vence ${dateFmt.format(lot.expiryDate!)}'
                                '${lot.daysUntilExpiry != null ? ' (${lot.daysUntilExpiry} días)' : ''}'
                          : 'Sin fecha de vencimiento',
                      style: TextStyle(
                        fontSize: 12,
                        color: info.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${lot.remainingQuantity.toStringAsFixed(2)} ${lot.itemUnit}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'de ${lot.receivedQuantity.toStringAsFixed(2)}',
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
      ),
    );
  }
}

class _LotDetailDialog extends StatelessWidget {
  final InventoryLot lot;
  final VoidCallback? onDispose;
  const _LotDetailDialog({required this.lot, this.onDispose});

  @override
  Widget build(BuildContext context) {
    final info = _expiryInfo(lot.expiryStatus);
    final dateFmt = DateFormat('dd/MM/yyyy');
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    return AlertDialog(
      title: Row(
        children: [
          Icon(info.icon, color: info.color, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${lot.lotNumber}  ·  ${lot.itemName}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Row(label: 'Estado', value: info.label, valueColor: info.color),
            _Row(label: 'Bodega', value: lot.warehouseName),
            _Row(
              label: 'Fecha de vencimiento',
              value: lot.expiryDate != null
                  ? dateFmt.format(lot.expiryDate!)
                  : 'Sin fecha',
              valueColor: lot.isExpired ? info.color : null,
            ),
            if (lot.daysUntilExpiry != null)
              _Row(
                label: 'Días restantes',
                value: '${lot.daysUntilExpiry}',
                valueColor: lot.daysUntilExpiry! < 0 ? info.color : null,
              ),
            _Row(
              label: 'Recibido',
              value:
                  '${lot.receivedQuantity.toStringAsFixed(2)} ${lot.itemUnit}'
                  '${lot.receivedDate != null ? ' el ${dateFmt.format(lot.receivedDate!)}' : ''}',
            ),
            _Row(
              label: 'Saldo restante',
              value:
                  '${lot.remainingQuantity.toStringAsFixed(2)} ${lot.itemUnit}',
            ),
            if (lot.costPerUnit != null)
              _Row(
                label: 'Costo unitario',
                value: currency.format(lot.costPerUnit),
              ),
            if (lot.remainingValue > 0)
              _Row(
                label: 'Valor en stock',
                value: currency.format(lot.remainingValue),
              ),
            if (lot.createdByName != null)
              _Row(label: 'Registrado por', value: lot.createdByName!),
            if (lot.notes != null && lot.notes!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  lot.notes!,
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: AppColors.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ),
            if (lot.status == LotStatus.disposed) ...[
              const Divider(height: 20),
              _Row(
                label: 'Dispuesto',
                value: lot.disposedAt != null
                    ? dateFmt.format(lot.disposedAt!.toLocal())
                    : '—',
                valueColor: const Color(0xFFDC2626),
              ),
              if (lot.disposedByName != null)
                _Row(label: 'Dispuesto por', value: lot.disposedByName!),
              if (lot.disposedReason != null &&
                  lot.disposedReason!.isNotEmpty)
                _Row(label: 'Motivo', value: lot.disposedReason!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        if (onDispose != null)
          FilledButton.tonal(
            onPressed: onDispose,
            style: FilledButton.styleFrom(
              foregroundColor: const Color(0xFFDC2626),
            ),
            child: const Text('Disponer lote'),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _Row({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: valueColor ?? AppColors.foreground,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
