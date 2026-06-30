// Sprint 5 Inventario (Fase B) — Vista de análisis de rotación.
//
// Lista insumos con métricas de rotación en una ventana configurable
// (7/30/60/90 días). Clasifica como star/active/slow/dormant según el
// outflow del período. Permite filtrar por clase y exportar CSV.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/export/report_exporter.dart';
import '../state/rotation_state.dart';
import '../viewmodel/rotation_viewmodel.dart';
import 'widgets/inventory_back_button.dart';

class InventoryRotationView extends ConsumerStatefulWidget {
  const InventoryRotationView({super.key});

  @override
  ConsumerState<InventoryRotationView> createState() =>
      _InventoryRotationViewState();
}

class _InventoryRotationViewState
    extends ConsumerState<InventoryRotationView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rotationViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(rotationViewModelProvider);
    final state = vm.state;

    final filtered = state.classFilter == null
        ? state.rows
        : state.rows
              .where((r) => r.rotationClass == state.classFilter)
              .toList(growable: false);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            daysBack: state.daysBack,
            countStar: state.countClass(RotationClass.star),
            countActive: state.countClass(RotationClass.active),
            countSlow: state.countClass(RotationClass.slow),
            countDormant: state.countClass(RotationClass.dormant),
            totalOutflow: state.totalOutflow,
            totalOutflowValue: state.totalOutflowValue,
            onDaysChange: (d) => vm.setDaysBack(d),
            onRefresh: state.loading ? null : () => vm.refresh(),
            onExportCsv: () => _exportCsv(state, filtered),
            onExportExcel: () => _exportExcel(state, filtered),
            onExportPdf: () => _exportPdf(state, filtered),
          ),
          _FiltersBar(
            currentFilter: state.classFilter,
            countStar: state.countClass(RotationClass.star),
            countActive: state.countClass(RotationClass.active),
            countSlow: state.countClass(RotationClass.slow),
            countDormant: state.countClass(RotationClass.dormant),
            onChanged: (cls) => vm.setClassFilter(cls),
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
            child: state.loading && state.rows.isEmpty
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : filtered.isEmpty
                ? _emptyState(state.classFilter != null)
                : _RotationList(
                    rows: filtered,
                    periodDays: state.daysBack,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(bool hasFilter) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.trending_up_rounded,
              size: 56,
              color: AppColors.mutedForeground,
            ),
            const SizedBox(height: 12),
            Text(
              hasFilter
                  ? 'Sin insumos en esta clase'
                  : 'Sin movimientos en el período',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasFilter
                  ? 'Cambia el filtro o el período para ver más.'
                  : 'Prueba con un período más largo si tu negocio recién '
                        'empieza a operar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.mutedForeground, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  ({List<String> headers, List<List<String>> rowsData, List<int> numericCols})
  _buildExportData(RotationState state, List<RotationRow> rows) {
    final headers = <String>[
      'SKU',
      'Insumo',
      'Unidad',
      'Stock actual',
      'Outflow (${state.daysBack}d)',
      'Inflow',
      'Velocidad/día',
      'Días de supply',
      'Movimientos',
      'Valor consumido',
      'Clase',
    ];
    final rowsData = rows
        .map(
          (r) => <String>[
            r.itemSku,
            r.itemName,
            r.itemUnit,
            r.currentStock.toStringAsFixed(2),
            r.outflowQty.toStringAsFixed(2),
            r.inflowQty.toStringAsFixed(2),
            r.outflowPerDay.toStringAsFixed(2),
            r.daysOfSupply?.toStringAsFixed(1) ?? '',
            r.movementCount.toString(),
            r.outflowValue.toStringAsFixed(2),
            _classLabel(r.rotationClass),
          ],
        )
        .toList(growable: false);
    return (
      headers: headers,
      rowsData: rowsData,
      numericCols: const [3, 4, 5, 6, 7, 8, 9],
    );
  }

  String _exportBaseFilename(RotationState state) {
    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    return 'rotacion_${state.daysBack}d_$stamp';
  }

  Future<void> _exportCsv(RotationState state, List<RotationRow> rows) async {
    final data = _buildExportData(state, rows);
    final saved = await ReportExporter.exportCsv(
      filename: _exportBaseFilename(state),
      headers: data.headers,
      rows: data.rowsData,
    );
    if (!mounted) return;
    AppToast.info(
      context,
      saved
          ? 'CSV exportado'
          : 'No se pudo descargar — copiado al portapapeles',
    );
  }

  Future<void> _exportExcel(
    RotationState state,
    List<RotationRow> rows,
  ) async {
    final data = _buildExportData(state, rows);
    final saved = await ReportExporter.exportExcel(
      filename: _exportBaseFilename(state),
      sheetName: 'Rotación',
      headers: data.headers,
      rows: data.rowsData,
    );
    if (!mounted) return;
    AppToast.info(
      context,
      saved
          ? 'Excel exportado'
          : 'No se pudo descargar — CSV copiado al portapapeles',
    );
  }

  Future<void> _exportPdf(
    RotationState state,
    List<RotationRow> rows,
  ) async {
    final data = _buildExportData(state, rows);
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    final subtitle =
        'Período: últimos ${state.daysBack} días  ·  '
        '${rows.length} insumo(s)  ·  '
        'Total consumido ${qtyFmt.format(state.totalOutflow)} unid';
    await ReportExporter.exportPdf(
      filename: _exportBaseFilename(state),
      title: 'Análisis de Rotación',
      subtitle: subtitle,
      headers: data.headers,
      rows: data.rowsData,
      landscape: true,
      columnNumericIndices: data.numericCols,
    );
  }
}

String _classLabel(RotationClass cls) {
  switch (cls) {
    case RotationClass.star:
      return 'Estrella';
    case RotationClass.active:
      return 'Activo';
    case RotationClass.slow:
      return 'Lento';
    case RotationClass.dormant:
      return 'Estancado';
    case RotationClass.unknown:
      return '—';
  }
}

({Color color, IconData icon, String description}) _classInfo(
  RotationClass cls,
) {
  switch (cls) {
    case RotationClass.star:
      return (
        color: const Color(0xFFCA8A04),
        icon: Icons.star_rounded,
        description: 'Top 20% por consumo en el período — mantén stock alto',
      );
    case RotationClass.active:
      return (
        color: const Color(0xFF059669),
        icon: Icons.trending_up_rounded,
        description: 'Movimiento regular — saludable',
      );
    case RotationClass.slow:
      return (
        color: const Color(0xFF2563EB),
        icon: Icons.timelapse_rounded,
        description: 'Movimiento bajo — revisa si conviene reducir compras',
      );
    case RotationClass.dormant:
      return (
        color: const Color(0xFFDC2626),
        icon: Icons.bedtime_outlined,
        description: 'Sin movimientos en el período — capital amarrado',
      );
    case RotationClass.unknown:
      return (
        color: AppColors.mutedForeground,
        icon: Icons.help_outline_rounded,
        description: '—',
      );
  }
}

class _Header extends StatelessWidget {
  final int daysBack;
  final int countStar;
  final int countActive;
  final int countSlow;
  final int countDormant;
  final double totalOutflow;
  final double totalOutflowValue;
  final ValueChanged<int> onDaysChange;
  final VoidCallback? onRefresh;
  final VoidCallback onExportCsv;
  final VoidCallback onExportExcel;
  final VoidCallback onExportPdf;

  const _Header({
    required this.daysBack,
    required this.countStar,
    required this.countActive,
    required this.countSlow,
    required this.countDormant,
    required this.totalOutflow,
    required this.totalOutflowValue,
    required this.onDaysChange,
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
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
                      'Análisis de Rotación',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Velocidad de consumo y clasificación de insumos según '
                      'movimientos en los últimos $daysBack días.',
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
          const SizedBox(height: 12),
          _PeriodSelector(daysBack: daysBack, onChange: onDaysChange),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard(
                label: 'Total consumido',
                value:
                    '${qtyFmt.format(totalOutflow)} unid · ${currency.format(totalOutflowValue)}',
                color: AppColors.primary,
                icon: Icons.outbox_outlined,
              ),
              _StatCard(
                label: 'Estrellas',
                value: '$countStar',
                description: 'Top 20% por consumo',
                color: const Color(0xFFCA8A04),
                icon: Icons.star_rounded,
              ),
              _StatCard(
                label: 'Activos',
                value: '$countActive',
                description: 'Movimiento regular',
                color: const Color(0xFF059669),
                icon: Icons.trending_up_rounded,
              ),
              _StatCard(
                label: 'Estancados',
                value: '$countDormant',
                description: 'Sin movimientos',
                color: const Color(0xFFDC2626),
                icon: Icons.bedtime_outlined,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  final int daysBack;
  final ValueChanged<int> onChange;
  const _PeriodSelector({required this.daysBack, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 7, label: Text('7 días')),
        ButtonSegment(value: 30, label: Text('30 días')),
        ButtonSegment(value: 60, label: Text('60 días')),
        ButtonSegment(value: 90, label: Text('90 días')),
      ],
      selected: {daysBack},
      onSelectionChanged: (s) => onChange(s.first),
      showSelectedIcon: false,
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
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
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
              fontSize: 15,
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

class _FiltersBar extends StatelessWidget {
  final RotationClass? currentFilter;
  final int countStar;
  final int countActive;
  final int countSlow;
  final int countDormant;
  final ValueChanged<RotationClass?> onChanged;

  const _FiltersBar({
    required this.currentFilter,
    required this.countStar,
    required this.countActive,
    required this.countSlow,
    required this.countDormant,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Chip(
            label: 'Todos',
            selected: currentFilter == null,
            onTap: () => onChanged(null),
          ),
          _Chip(
            label: 'Estrellas ($countStar)',
            color: const Color(0xFFCA8A04),
            selected: currentFilter == RotationClass.star,
            onTap: () => onChanged(RotationClass.star),
          ),
          _Chip(
            label: 'Activos ($countActive)',
            color: const Color(0xFF059669),
            selected: currentFilter == RotationClass.active,
            onTap: () => onChanged(RotationClass.active),
          ),
          _Chip(
            label: 'Lentos ($countSlow)',
            color: const Color(0xFF2563EB),
            selected: currentFilter == RotationClass.slow,
            onTap: () => onChanged(RotationClass.slow),
          ),
          _Chip(
            label: 'Estancados ($countDormant)',
            color: const Color(0xFFDC2626),
            selected: currentFilter == RotationClass.dormant,
            onTap: () => onChanged(RotationClass.dormant),
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

class _RotationList extends StatelessWidget {
  final List<RotationRow> rows;
  final int periodDays;

  const _RotationList({required this.rows, required this.periodDays});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) =>
          _RotationCard(row: rows[index], periodDays: periodDays),
    );
  }
}

class _RotationCard extends StatelessWidget {
  final RotationRow row;
  final int periodDays;

  const _RotationCard({required this.row, required this.periodDays});

  @override
  Widget build(BuildContext context) {
    final info = _classInfo(row.rotationClass);
    final qtyFmt = NumberFormat.decimalPattern('es_DO');
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    final dos = row.daysOfSupply;
    final needsReplenish = row.needsReplenishAlert(periodDays);
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.cardElevated,
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
                          row.itemName,
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
                          _classLabel(row.rotationClass).toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: info.color,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      if (needsReplenish) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Días de supply menor al período — '
                              'considera reponer',
                          child: Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.red.shade600,
                            size: 16,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${row.itemSku.isNotEmpty ? 'SKU ${row.itemSku} · ' : ''}'
                    'Stock: ${qtyFmt.format(row.currentStock)} ${row.itemUnit}'
                    '${row.outflowValue > 0 ? '  ·  Valor consumido ${currency.format(row.outflowValue)}' : ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      _Metric(
                        label: 'Outflow ${periodDays}d',
                        value:
                            '${qtyFmt.format(row.outflowQty)} ${row.itemUnit}',
                      ),
                      _Metric(
                        label: 'Velocidad',
                        value:
                            '${row.outflowPerDay.toStringAsFixed(2)} /día',
                      ),
                      _Metric(
                        label: 'Días de supply',
                        value: dos == null
                            ? '—'
                            : dos > 999
                                ? '999+'
                                : dos.toStringAsFixed(1),
                        emphasized: needsReplenish,
                      ),
                      _Metric(
                        label: 'Movimientos',
                        value: row.movementCount.toString(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasized;
  const _Metric({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.mutedForeground,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: emphasized ? Colors.red.shade700 : AppColors.foreground,
            fontSize: 13,
            fontWeight: emphasized ? FontWeight.w800 : FontWeight.w700,
          ),
        ),
      ],
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
