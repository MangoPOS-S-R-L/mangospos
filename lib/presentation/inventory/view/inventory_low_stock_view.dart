// Sprint 4 Inventario — Vista de alertas de stock bajo.
//
// Lista los insumos cuyo stock total está en o por debajo del min_stock
// configurado, agrupados por nivel (agotados / críticos / bajos). Permite
// filtrar por nivel y abrir un drilldown con el desglose por bodega.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../state/low_stock_state.dart';
import '../viewmodel/low_stock_viewmodel.dart';

class InventoryLowStockView extends ConsumerStatefulWidget {
  const InventoryLowStockView({super.key});

  @override
  ConsumerState<InventoryLowStockView> createState() =>
      _InventoryLowStockViewState();
}

class _InventoryLowStockViewState
    extends ConsumerState<InventoryLowStockView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(lowStockViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(lowStockViewModelProvider);
    final state = vm.state;

    final outOfStock = state.countOf(LowStockAlertLevel.outOfStock);
    final critical = state.countOf(LowStockAlertLevel.critical);
    final low = state.countOf(LowStockAlertLevel.low);

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            count: state.alerts.length,
            totalShortfallValue: state.totalShortfallValue,
            onRefresh: state.loading ? null : () => vm.refresh(),
          ),
          _FiltersBar(
            currentFilter: state.alertLevelFilter,
            outOfStockCount: outOfStock,
            criticalCount: critical,
            lowCount: low,
            onChanged: (level) => vm.applyLevelFilter(level),
          ),
          if (state.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red.shade50,
              child: Text(
                state.error!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          Expanded(
            child: state.loading && state.alerts.isEmpty
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : state.alerts.isEmpty
                ? _EmptyState(
                    hasFilter: state.alertLevelFilter != null,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    itemCount: state.alerts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return _AlertCard(
                        alert: state.alerts[index],
                        onTap: () => _openDetail(state.alerts[index]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(LowStockAlert alert) async {
    final breakdown = await ref
        .read(lowStockViewModelProvider)
        .loadWarehousesForItem(alert.itemId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _AlertDetailDialog(alert: alert, breakdown: breakdown),
    );
  }
}

class _Header extends StatelessWidget {
  final int count;
  final double totalShortfallValue;
  final VoidCallback? onRefresh;

  const _Header({
    required this.count,
    required this.totalShortfallValue,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
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
                  'Alertas de Stock',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Insumos cuyo stock total está en o por debajo del mínimo configurado.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count alerta(s)  ·  Valor estimado de reposición: '
                  '${currency.format(totalShortfallValue)}',
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

class _FiltersBar extends StatelessWidget {
  final String? currentFilter;
  final int outOfStockCount;
  final int criticalCount;
  final int lowCount;
  final ValueChanged<String?> onChanged;

  const _FiltersBar({
    required this.currentFilter,
    required this.outOfStockCount,
    required this.criticalCount,
    required this.lowCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        children: [
          _FilterChip(
            label: 'Todas',
            selected: currentFilter == null,
            onSelected: () => onChanged(null),
          ),
          _FilterChip(
            label: 'Agotados ($outOfStockCount)',
            color: const Color(0xFFDC2626),
            selected: currentFilter == 'out_of_stock',
            onSelected: () => onChanged('out_of_stock'),
          ),
          _FilterChip(
            label: 'Críticos ($criticalCount)',
            color: const Color(0xFFEA580C),
            selected: currentFilter == 'critical',
            onSelected: () => onChanged('critical'),
          ),
          _FilterChip(
            label: 'Bajos ($lowCount)',
            color: const Color(0xFFCA8A04),
            selected: currentFilter == 'low',
            onSelected: () => onChanged('low'),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? color;
  final VoidCallback onSelected;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppColors.primary;
    return InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
              Icons.check_circle_outline_rounded,
              size: 56,
              color: AppColors.primary.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              hasFilter
                  ? 'Sin alertas en este nivel'
                  : 'Todo bajo control',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasFilter
                  ? 'Cambia el filtro para ver alertas de otros niveles.'
                  : 'No hay insumos por debajo del mínimo configurado.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final LowStockAlert alert;
  final VoidCallback onTap;

  const _AlertCard({required this.alert, required this.onTap});

  ({Color color, String label, IconData icon}) _levelInfo() {
    switch (alert.alertLevel) {
      case LowStockAlertLevel.outOfStock:
        return (
          color: const Color(0xFFDC2626),
          label: 'AGOTADO',
          icon: Icons.error_outline_rounded,
        );
      case LowStockAlertLevel.critical:
        return (
          color: const Color(0xFFEA580C),
          label: 'CRÍTICO',
          icon: Icons.warning_amber_rounded,
        );
      case LowStockAlertLevel.low:
        return (
          color: const Color(0xFFCA8A04),
          label: 'BAJO',
          icon: Icons.notifications_active_outlined,
        );
      case LowStockAlertLevel.unknown:
        return (
          color: AppColors.mutedForeground,
          label: '—',
          icon: Icons.help_outline_rounded,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _levelInfo();
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
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
                            alert.name,
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
                      alert.sku.isNotEmpty
                          ? 'SKU: ${alert.sku}  ·  ${alert.warehousesWithStock} bodega(s) con stock'
                          : '${alert.warehousesWithStock} bodega(s) con stock',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.mutedForeground,
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
                    '${qtyFmt.format(alert.totalStock)} / ${qtyFmt.format(alert.minStock)} ${alert.unit}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: info.color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Faltan ${qtyFmt.format(alert.shortfall)} ${alert.unit}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.mutedForeground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertDetailDialog extends StatelessWidget {
  final LowStockAlert alert;
  final List<StockByWarehouse> breakdown;
  const _AlertDetailDialog({required this.alert, required this.breakdown});

  @override
  Widget build(BuildContext context) {
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    return AlertDialog(
      title: Text(alert.name),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DetailRow(
              label: 'Stock total',
              value:
                  '${qtyFmt.format(alert.totalStock)} / ${qtyFmt.format(alert.minStock)} ${alert.unit}',
            ),
            _DetailRow(
              label: 'Faltante',
              value: '${qtyFmt.format(alert.shortfall)} ${alert.unit}',
            ),
            _DetailRow(
              label: 'Costo unitario',
              value: currency.format(alert.cost),
            ),
            _DetailRow(
              label: 'Valor estimado de reposición',
              value: currency.format(alert.shortfallValue),
            ),
            const SizedBox(height: 12),
            Text(
              'Desglose por bodega',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 6),
            if (breakdown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Sin stock registrado en ninguna bodega.',
                  style: TextStyle(
                    color: AppColors.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: breakdown.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final row = breakdown[index];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          if (row.warehouseIsMain)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                Icons.star_rounded,
                                size: 14,
                                color: Colors.amber.shade700,
                              ),
                            ),
                          Expanded(
                            child: Text(
                              row.warehouseName,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppColors.foreground,
                              ),
                            ),
                          ),
                          Text(
                            '${qtyFmt.format(row.quantity)} ${row.unit}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: row.quantity <= 0
                                  ? const Color(0xFFDC2626)
                                  : AppColors.foreground,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 13,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
