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
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/export/report_exporter.dart';
import '../services/inventory_scan.dart';
import '../state/inventory_state.dart';
import '../state/kardex_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../viewmodel/kardex_viewmodel.dart';
import 'widgets/inventory_back_button.dart';
import 'widgets/item_search_field.dart';

class InventoryKardexView extends ConsumerStatefulWidget {
  const InventoryKardexView({super.key});

  @override
  ConsumerState<InventoryKardexView> createState() =>
      _InventoryKardexViewState();
}

class _InventoryKardexViewState extends ConsumerState<InventoryKardexView> {
  bool _exporting = false;

  /// Modo valorizado: muestra el valor de cada movimiento en base al costo
  /// (`total_value = |cantidad| × costo unitario` de la vista SQL). Solo
  /// presentación — el dato ya viene en cada fila, no recarga nada.
  bool _valued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // El kardex consume catálogo de items + bodegas para llenar dropdowns.
      await ref.read(inventoryViewModelProvider).init();
      await ref.read(kardexViewModelProvider).init();
    });
  }

  /// Describe los filtros activos para el subtítulo del PDF, así el
  /// documento es auto-explicativo ("de qué es este reporte").
  String _filtersSummary(KardexFilters filters, InventoryState istate) {
    final fmt = DateFormat('dd/MM/yyyy');
    final parts = <String>[];
    if (filters.itemId != null) {
      final item = istate.items
          .where((i) => i.id == filters.itemId)
          .firstOrNull;
      parts.add('Insumo: ${item?.name ?? filters.itemId}');
    }
    if (filters.warehouseId != null) {
      final wh = istate.warehouses
          .where((w) => w.id == filters.warehouseId)
          .firstOrNull;
      parts.add('Bodega: ${wh?.name ?? filters.warehouseId}');
    }
    if (filters.movementType != null) {
      parts.add('Tipo: ${_movementTypeLabel(filters.movementType!)}');
    }
    if (filters.from != null || filters.to != null) {
      final from = filters.from != null ? fmt.format(filters.from!) : 'inicio';
      final to = filters.to != null ? fmt.format(filters.to!) : 'hoy';
      parts.add('Período: $from a $to');
    }
    if (parts.isEmpty) return 'Todos los movimientos';
    return parts.join('  ·  ');
  }

  Future<void> _exportPdf() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final kvm = ref.read(kardexViewModelProvider);
      final istate = ref.read(inventoryViewModelProvider).state;
      final filters = kvm.state.filters;

      // Trae el set COMPLETO que matchea los filtros (la lista en pantalla
      // solo tiene las páginas ya scrolleadas).
      final result = await kvm.fetchAllForExport();
      if (!mounted) return;
      if (result.movements.isEmpty) {
        AppToast.info(context, 'No hay movimientos para exportar.');
        return;
      }

      // Fecha corta (yy) para que quepa en su columna sin partirse.
      final dateFmt = DateFormat('dd/MM/yy HH:mm');
      final qtyFmt = NumberFormat.decimalPattern('es_DO');
      final currency = currentBusinessCurrencyOrFallback(ref);
      final rows = result.movements
          .map(
            (m) => <String>[
              m.createdAt != null ? dateFmt.format(m.createdAt!.toLocal()) : '—',
              m.itemName,
              m.warehouseName,
              _movementTypeLabel(m.movementType),
              '${m.quantity > 0 ? '+' : ''}${qtyFmt.format(m.quantity)} ${m.itemUnit}',
              if (_valued) ...[
                m.costPerUnit != null
                    ? currency.formatAmount(m.costPerUnit!)
                    : '—',
                m.costPerUnit != null
                    ? currency.formatAmount(m.totalValue)
                    : '—',
              ],
              qtyFmt.format(m.runningBalance),
              m.createdByName ?? '—',
              m.notes ?? '',
            ],
          )
          .toList(growable: false);

      var subtitle =
          '${_filtersSummary(filters, istate)}  ·  ${result.movements.length} movimiento(s)';
      List<String>? summaryLines;
      if (_valued) {
        // Totales valorizados del set exportado. total_value viene sin signo
        // (|cantidad| × costo), así que separamos entradas y salidas.
        var inbound = 0.0;
        var outbound = 0.0;
        var withoutCost = 0;
        for (final m in result.movements) {
          if (m.costPerUnit == null) {
            withoutCost++;
            continue;
          }
          if (m.quantity > 0) {
            inbound += m.totalValue;
          } else {
            outbound += m.totalValue;
          }
        }
        summaryLines = [
          'Entradas: ${currency.formatAmount(inbound)}',
          'Salidas: ${currency.formatAmount(outbound)}',
          'Total neto: ${currency.formatAmount(inbound - outbound)}',
          if (withoutCost > 0) '($withoutCost movimiento(s) sin costo, excluidos)',
        ];
      }
      if (result.truncated) {
        subtitle += '  ·  TRUNCADO: solo los primeros ${result.movements.length}';
      }

      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      await ReportExporter.exportPdf(
        filename: 'kardex_$stamp',
        title: 'Kardex de Inventario',
        subtitle: subtitle,
        headers: [
          'Fecha',
          'Insumo',
          'Bodega',
          'Tipo',
          'Cantidad',
          if (_valued) ...['Costo Unit.', 'Valor'],
          'Saldo',
          'Usuario',
          'Notas',
        ],
        rows: rows,
        landscape: true,
        columnNumericIndices: _valued ? const [4, 5, 6, 7] : const [4, 5],
        // Anchos relativos fijos: sin esto la tabla auto-ajusta por contenido
        // y con tantas columnas parte headers y montos letra por letra.
        columnFlex: _valued
            ? const [1.3, 2.2, 1.3, 1.1, 1.2, 1.2, 1.4, 0.9, 1.3, 2.4]
            : const [1.4, 2.4, 1.4, 1.1, 1.2, 0.9, 1.4, 2.6],
        summaryLines: summaryLines,
      );
    } catch (e) {
      if (mounted) AppToast.info(context, 'No se pudo exportar: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kvm = ref.watch(kardexViewModelProvider);
    final ivm = ref.watch(inventoryViewModelProvider);
    final kstate = kvm.state;
    final istate = ivm.state;

    return InventoryScanListener(
      enabled: !kstate.loading,
      items: istate.items,
      // Escanear en el Kardex es "mostrame el historial de ESTE insumo":
      // filtra, no agrega nada.
      onItem: (item) => kvm.applyFilters(
        kstate.filters.copyWith(itemId: item.id),
      ),
      child: Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            onRefresh: kstate.loading ? null : () => kvm.refresh(),
            onExportPdf:
                (_exporting || kstate.loading) ? null : () => _exportPdf(),
            exporting: _exporting,
            count: kstate.movements.length,
            hasMore: kstate.hasMore,
          ),
          _FiltersBar(
            filters: kstate.filters,
            items: istate.items,
            warehouses: istate.warehouses,
            onChanged: (f) => kvm.applyFilters(f),
            valued: _valued,
            onValuedChanged: (v) => setState(() => _valued = v),
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
                    valued: _valued,
                    currency: currentBusinessCurrencyOrFallback(ref),
                  ),
          ),
        ],
      ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback? onRefresh;
  final VoidCallback? onExportPdf;
  final bool exporting;
  final int count;
  final bool hasMore;
  const _Header({
    required this.onRefresh,
    required this.onExportPdf,
    required this.exporting,
    required this.count,
    required this.hasMore,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 24, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: InventoryBackButton(),
          ),
          const SizedBox(width: 4),
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
            onPressed: onExportPdf,
            icon: exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Exportar PDF (respeta los filtros aplicados)',
          ),
          const SizedBox(width: 8),
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
  final bool valued;
  final ValueChanged<bool> onValuedChanged;

  const _FiltersBar({
    required this.filters,
    required this.items,
    required this.warehouses,
    required this.onChanged,
    required this.valued,
    required this.onValuedChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          ItemSearchField(
            items: items,
            selectedItemId: filters.itemId,
            onSelected: (id) => onChanged(
              filters.copyWith(itemId: id, clearItemId: id == null),
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
          FilterChip(
            selected: valued,
            onSelected: onValuedChanged,
            avatar: valued
                ? null
                : const Icon(Icons.attach_money_rounded, size: 18),
            label: const Text('Valorizado'),
            tooltip: 'Mostrar valor de cada movimiento en base al costo',
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
  final bool valued;
  final BusinessCurrency currency;

  const _MovementsList({
    required this.movements,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
    required this.valued,
    required this.currency,
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
        return _MovementCard(
          movement: movements[index],
          valued: valued,
          currency: currency,
        );
      },
    );
  }
}

class _MovementCard extends StatelessWidget {
  final KardexMovement movement;
  final bool valued;
  final BusinessCurrency currency;
  const _MovementCard({
    required this.movement,
    required this.valued,
    required this.currency,
  });

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
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          // El color va en el BoxDecoration, no en el Material: la sombra
          // del decoration se pinta como silueta completa del rect y sin
          // un fill opaco encima se transparenta (tarjetas grises).
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.cardElevated,
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
                    '${movement.createdAt != null ? ' · ${dateFmt.format(movement.createdAt!.toLocal())}' : ''}'
                    '${valued && movement.costPerUnit != null ? ' · Costo u.: ${currency.formatAmount(movement.costPerUnit!)}' : ''}',
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
                if (valued) ...[
                  const SizedBox(height: 2),
                  Text(
                    movement.costPerUnit == null
                        ? 'Sin costo'
                        : 'Valor: ${currency.formatAmount(movement.totalValue)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: movement.costPerUnit == null
                          ? AppColors.mutedForeground
                          : AppColors.foreground,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
