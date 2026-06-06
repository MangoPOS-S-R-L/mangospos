// Sprint 5 Inventario (Fase A) — Vista de valoración de existencias + ABC.
//
// Dos modos:
//   - Por item (default): tabla agregada por insumo con clasificación ABC.
//   - Por bodega: detalle (item × bodega) para drilldown.
//
// Exportación: copia los datos visibles al portapapeles en formato CSV.
// El usuario los pega en Excel/Sheets. Una exportación a archivo real
// (paquetes `excel` / `pdf`) queda para Fase C del Sprint 5.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/export/report_exporter.dart';
import '../state/inventory_state.dart';
import '../state/valuation_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../viewmodel/valuation_viewmodel.dart';

class InventoryValuationView extends ConsumerStatefulWidget {
  const InventoryValuationView({super.key});

  @override
  ConsumerState<InventoryValuationView> createState() =>
      _InventoryValuationViewState();
}

class _InventoryValuationViewState
    extends ConsumerState<InventoryValuationView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(inventoryViewModelProvider).init();
      await ref.read(valuationViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(valuationViewModelProvider);
    final ivm = ref.watch(inventoryViewModelProvider);
    final state = vm.state;
    final istate = ivm.state;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            totalValue: state.totalValue,
            filteredValue: state.filteredValue,
            countA: state.countAbc(AbcClass.a),
            countB: state.countAbc(AbcClass.b),
            countC: state.countAbc(AbcClass.c),
            onRefresh: state.loading ? null : () => vm.refresh(),
            onExportCsv: () => _exportCsv(state),
            onExportExcel: () => _exportExcel(state),
            onExportPdf: () => _exportPdf(state),
          ),
          _ModeAndFilters(
            viewMode: state.viewMode,
            filters: state.filters,
            warehouses: istate.warehouses,
            onModeChanged: (m) => vm.setViewMode(m),
            onFiltersChanged: (f) => vm.applyFilters(f),
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
            child: state.loading &&
                    state.summary.isEmpty &&
                    state.details.isEmpty
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : state.viewMode == ValuationViewMode.byItem
                ? state.summary.isEmpty
                      ? _emptyState(filtered: !state.filters.isEmpty)
                      : _SummaryTable(rows: state.summary)
                : state.details.isEmpty
                ? _emptyState(filtered: state.filters.warehouseId != null)
                : _DetailsTable(rows: state.details),
          ),
        ],
      ),
    );
  }

  Widget _emptyState({required bool filtered}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.assessment_outlined,
              size: 56,
              color: AppColors.mutedForeground,
            ),
            const SizedBox(height: 12),
            Text(
              filtered
                  ? 'Sin resultados para este filtro'
                  : 'Aún no hay stock valorizable',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              filtered
                  ? 'Cambia los filtros para ver más resultados.'
                  : 'Cuando registres entradas con costo, el inventario se valuará automáticamente.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.mutedForeground, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  /// Construye headers + rows según el modo de vista actual. Reutilizado
  /// por las 3 funciones de export (CSV/Excel/PDF) para que el contenido
  /// sea idéntico entre formatos.
  ({List<String> headers, List<List<String>> rows, List<int> numericCols})
  _buildExportData(ValuationState state) {
    if (state.viewMode == ValuationViewMode.byItem) {
      final headers = const [
        'SKU',
        'Insumo',
        'Unidad',
        'Costo Unitario',
        'Cantidad Total',
        'Valor Total',
        '% del Total',
        'Clase ABC',
        'Bodegas con stock',
      ];
      final rows = state.summary
          .map(
            (row) => <String>[
              row.itemSku,
              row.itemName,
              row.itemUnit,
              row.unitCost.toStringAsFixed(2),
              row.totalQuantity.toStringAsFixed(2),
              row.totalValue.toStringAsFixed(2),
              (row.valuePct * 100).toStringAsFixed(2),
              _abcLabel(row.abcClass),
              row.warehousesWithStock.toString(),
            ],
          )
          .toList(growable: false);
      // Columnas numéricas (alineación derecha en PDF).
      return (headers: headers, rows: rows, numericCols: const [3, 4, 5, 6, 8]);
    } else {
      final headers = const [
        'SKU',
        'Insumo',
        'Bodega',
        'Cantidad',
        'Unidad',
        'Costo Unitario',
        'Valor',
      ];
      final rows = state.details
          .map(
            (row) => <String>[
              row.itemSku,
              row.itemName,
              row.warehouseName,
              row.quantity.toStringAsFixed(2),
              row.itemUnit,
              row.unitCost.toStringAsFixed(2),
              row.value.toStringAsFixed(2),
            ],
          )
          .toList(growable: false);
      return (headers: headers, rows: rows, numericCols: const [3, 5, 6]);
    }
  }

  String _exportBaseFilename(ValuationState state) {
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final mode = state.viewMode == ValuationViewMode.byItem
        ? 'por_insumo'
        : 'por_bodega';
    return 'valoracion_${mode}_$stamp';
  }

  Future<void> _exportCsv(ValuationState state) async {
    final data = _buildExportData(state);
    final saved = await ReportExporter.exportCsv(
      filename: _exportBaseFilename(state),
      headers: data.headers,
      rows: data.rows,
    );
    if (!mounted) return;
    AppToast.info(
      context,
      saved
          ? 'CSV exportado'
          : 'No se pudo descargar — copiado al portapapeles',
    );
  }

  Future<void> _exportExcel(ValuationState state) async {
    final data = _buildExportData(state);
    final saved = await ReportExporter.exportExcel(
      filename: _exportBaseFilename(state),
      sheetName: 'Valoración',
      headers: data.headers,
      rows: data.rows,
    );
    if (!mounted) return;
    AppToast.info(
      context,
      saved
          ? 'Excel exportado'
          : 'No se pudo descargar — CSV copiado al portapapeles',
    );
  }

  Future<void> _exportPdf(ValuationState state) async {
    final data = _buildExportData(state);
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final subtitle = state.viewMode == ValuationViewMode.byItem
        ? 'Valor total: ${currency.format(state.totalValue)}  ·  '
              '${state.summary.length} insumo(s)'
        : 'Detalle por bodega  ·  ${state.details.length} fila(s)';
    await ReportExporter.exportPdf(
      filename: _exportBaseFilename(state),
      title: 'Valoración de Existencias',
      subtitle: subtitle,
      headers: data.headers,
      rows: data.rows,
      landscape: state.viewMode == ValuationViewMode.byItem,
      columnNumericIndices: data.numericCols,
    );
  }
}

String _abcLabel(AbcClass cls) {
  switch (cls) {
    case AbcClass.a:
      return 'A';
    case AbcClass.b:
      return 'B';
    case AbcClass.c:
      return 'C';
    case AbcClass.noData:
      return 'Sin datos';
    case AbcClass.unknown:
      return '—';
  }
}

({Color color, String description}) _abcInfo(AbcClass cls) {
  switch (cls) {
    case AbcClass.a:
      return (
        color: const Color(0xFFDC2626),
        description: '20% del valor — alta prioridad',
      );
    case AbcClass.b:
      return (
        color: const Color(0xFFCA8A04),
        description: '30% del valor — prioridad media',
      );
    case AbcClass.c:
      return (
        color: const Color(0xFF059669),
        description: '50% del valor — baja prioridad',
      );
    case AbcClass.noData:
      return (
        color: const Color(0xFF6B7280),
        description: 'Sin valor (cantidad o costo en 0)',
      );
    case AbcClass.unknown:
      return (color: const Color(0xFF6B7280), description: '—');
  }
}

class _Header extends StatelessWidget {
  final double totalValue;
  final double filteredValue;
  final int countA;
  final int countB;
  final int countC;
  final VoidCallback? onRefresh;
  final VoidCallback onExportCsv;
  final VoidCallback onExportExcel;
  final VoidCallback onExportPdf;

  const _Header({
    required this.totalValue,
    required this.filteredValue,
    required this.countA,
    required this.countB,
    required this.countC,
    required this.onRefresh,
    required this.onExportCsv,
    required this.onExportExcel,
    required this.onExportPdf,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final isFiltered = (filteredValue - totalValue).abs() > 0.01;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Valoración de Existencias',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Stock × costo unitario, agregado por insumo con '
                      'clasificación Pareto (ABC).',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              _ExportMenu(
                onCsv: onExportCsv,
                onExcel: onExportExcel,
                onPdf: onExportPdf,
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refrescar',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard(
                label: isFiltered ? 'Valor filtrado' : 'Valor total',
                value: currency.format(
                  isFiltered ? filteredValue : totalValue,
                ),
                color: AppColors.primary,
                icon: Icons.attach_money_rounded,
              ),
              _StatCard(
                label: 'Clase A',
                value: '$countA',
                description: 'Top 20% del valor',
                color: const Color(0xFFDC2626),
                icon: Icons.priority_high_rounded,
              ),
              _StatCard(
                label: 'Clase B',
                value: '$countB',
                description: 'Siguientes 30%',
                color: const Color(0xFFCA8A04),
                icon: Icons.flag_outlined,
              ),
              _StatCard(
                label: 'Clase C',
                value: '$countC',
                description: '50% restante',
                color: const Color(0xFF059669),
                icon: Icons.check_circle_outline_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String? description;
  final Color color;
  final IconData icon;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 14),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: AppColors.mutedForeground,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (description != null) ...[
            const SizedBox(height: 2),
            Text(
              description!,
              style: TextStyle(
                color: AppColors.mutedForeground,
                fontSize: 10,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModeAndFilters extends StatelessWidget {
  final ValuationViewMode viewMode;
  final ValuationFilters filters;
  final List<InventoryWarehouse> warehouses;
  final ValueChanged<ValuationViewMode> onModeChanged;
  final ValueChanged<ValuationFilters> onFiltersChanged;

  const _ModeAndFilters({
    required this.viewMode,
    required this.filters,
    required this.warehouses,
    required this.onModeChanged,
    required this.onFiltersChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Row(
        children: [
          SegmentedButton<ValuationViewMode>(
            segments: const [
              ButtonSegment(
                value: ValuationViewMode.byItem,
                label: Text('Por insumo'),
                icon: Icon(Icons.format_list_bulleted_rounded, size: 18),
              ),
              ButtonSegment(
                value: ValuationViewMode.byWarehouse,
                label: Text('Por bodega'),
                icon: Icon(Icons.warehouse_outlined, size: 18),
              ),
            ],
            selected: {viewMode},
            onSelectionChanged: (s) => onModeChanged(s.first),
          ),
          const SizedBox(width: 16),
          if (viewMode == ValuationViewMode.byItem)
            Expanded(
              child: Wrap(
                spacing: 8,
                children: const [
                  _AbcChip(cls: AbcClass.a),
                  _AbcChip(cls: AbcClass.b),
                  _AbcChip(cls: AbcClass.c),
                ],
              ),
            )
          else
            Expanded(
              child: SizedBox(
                width: 240,
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
                  onChanged: (v) => onFiltersChanged(
                    filters.copyWith(
                      warehouseId: v == null || v.isEmpty ? null : v,
                      clearWarehouse: v == null || v.isEmpty,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AbcChip extends ConsumerWidget {
  final AbcClass cls;
  const _AbcChip({required this.cls});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(valuationViewModelProvider).state;
    final code = _classToCode(cls);
    final selected = state.filters.abcClass == code;
    final info = _abcInfo(cls);
    return Tooltip(
      message: info.description,
      child: InkWell(
        onTap: () => ref
            .read(valuationViewModelProvider)
            .applyFilters(
              state.filters.copyWith(
                abcClass: selected ? null : code,
                clearAbc: selected,
              ),
            ),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? info.color.withValues(alpha: 0.14)
                : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? info.color.withValues(alpha: 0.45)
                  : AppColors.border,
            ),
          ),
          child: Text(
            'Clase ${_abcLabel(cls)}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? info.color : AppColors.foreground,
            ),
          ),
        ),
      ),
    );
  }

  static String _classToCode(AbcClass cls) {
    switch (cls) {
      case AbcClass.a:
        return 'A';
      case AbcClass.b:
        return 'B';
      case AbcClass.c:
        return 'C';
      case AbcClass.noData:
        return 'no_data';
      case AbcClass.unknown:
        return '';
    }
  }
}

class _SummaryTable extends StatelessWidget {
  final List<ValuationSummaryRow> rows;
  const _SummaryTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final row = rows[index];
        final info = _abcInfo(row.abcClass);
        return Material(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.border),
              boxShadow: AppShadows.soft,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: info.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _abcLabel(row.abcClass),
                    style: TextStyle(
                      color: info.color,
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                  ),
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
                              row.itemName,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppColors.foreground,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (row.tracksLots)
                            Container(
                              margin: const EdgeInsets.only(left: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFEDD5),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'LOTE',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFFC2410C),
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${row.itemSku.isNotEmpty ? 'SKU ${row.itemSku} · ' : ''}'
                        '${qtyFmt.format(row.totalQuantity)} ${row.itemUnit} '
                        '× ${currency.format(row.unitCost)} c/u',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      if (row.cumulativePct != null) ...[
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: row.valuePct.clamp(0, 1),
                          backgroundColor: AppColors.border,
                          color: info.color,
                          minHeight: 4,
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
                      currency.format(row.totalValue),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '${(row.valuePct * 100).toStringAsFixed(1)}% del total',
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
      },
    );
  }
}

class _DetailsTable extends StatelessWidget {
  final List<ValuationRow> rows;
  const _DetailsTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final row = rows[index];
        return Material(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.border),
              boxShadow: AppShadows.soft,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.itemName,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (row.warehouseIsMain)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.star_rounded,
                                color: Colors.amber.shade700,
                                size: 14,
                              ),
                            ),
                          Text(
                            row.warehouseName,
                            style: TextStyle(
                              color: AppColors.mutedForeground,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Text(
                  '${qtyFmt.format(row.quantity)} ${row.itemUnit}',
                  style: TextStyle(
                    color: AppColors.foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 130,
                  child: Text(
                    currency.format(row.value),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ExportMenu extends StatelessWidget {
  final VoidCallback onCsv;
  final VoidCallback onExcel;
  final VoidCallback onPdf;

  const _ExportMenu({
    required this.onCsv,
    required this.onExcel,
    required this.onPdf,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Exportar',
      onSelected: (value) {
        switch (value) {
          case 'csv':
            onCsv();
            break;
          case 'excel':
            onExcel();
            break;
          case 'pdf':
            onPdf();
            break;
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'pdf',
          child: ListTile(
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text('Exportar PDF'),
            subtitle: Text(
              'Listo para imprimir o compartir',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'excel',
          child: ListTile(
            leading: Icon(Icons.table_chart_outlined),
            title: Text('Exportar Excel'),
            subtitle: Text(
              'Archivo .xlsx con formato',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
          ),
        ),
        PopupMenuItem(
          value: 'csv',
          child: ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('Exportar CSV'),
            subtitle: Text(
              'Compatible con todo',
              style: TextStyle(fontSize: 11),
            ),
            dense: true,
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.file_download_outlined, size: 18),
            SizedBox(width: 6),
            Text('Exportar'),
            SizedBox(width: 2),
            Icon(Icons.arrow_drop_down_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}
