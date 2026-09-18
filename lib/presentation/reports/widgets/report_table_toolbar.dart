import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/model/report_column.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/state/report_view_preferences.dart';
import 'package:mangopos/presentation/reports/widgets/customizable_report_table.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

/// Rótulo de fila de la barra ("NIVEL", "VISTA").
class ReportToolbarLabel extends StatelessWidget {
  const ReportToolbarLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }
}

class _ToolbarRow extends StatelessWidget {
  const _ToolbarRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ReportToolbarLabel(label),
        ),
        Expanded(
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// Fila NIVEL del reporte por comprobante.
class ReportLevelBar extends StatelessWidget {
  const ReportLevelBar({
    super.key,
    required this.detail,
    required this.onDetail,
    required this.showVoided,
    required this.voidedCount,
    required this.onToggleVoided,
  });

  final bool detail;
  final ValueChanged<bool> onDetail;
  final bool showVoided;
  final int voidedCount;
  final ValueChanged<bool> onToggleVoided;

  @override
  Widget build(BuildContext context) {
    return _ToolbarRow(
      label: 'NIVEL',
      children: [
        ReportRangeChip(
          label: 'Resumen por tipo',
          selected: !detail,
          onTap: () => onDetail(false),
        ),
        ReportRangeChip(
          label: 'Detalle por comprobante',
          selected: detail,
          onTap: () => onDetail(true),
        ),
        if (detail && voidedCount > 0)
          OutlinedButton.icon(
            onPressed: () => onToggleVoided(!showVoided),
            icon: Icon(
              showVoided
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 16,
            ),
            label: Text(
              showVoided
                  ? 'Ocultar anulados ($voidedCount)'
                  : 'Mostrar anulados ($voidedCount)',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.destructive,
              side: BorderSide(
                color: AppColors.destructive.withValues(alpha: 0.35),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(reportRadius),
              ),
              textStyle:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
      ],
    );
  }
}

/// Fila VISTA: vistas predefinidas, las guardadas y "Guardar vista" cuando
/// la tabla ya no coincide con la vista elegida.
class ReportViewPresetBar extends StatelessWidget {
  const ReportViewPresetBar({
    super.key,
    required this.definition,
    required this.selectedViewId,
    required this.modified,
    required this.savedViews,
    required this.onSelect,
    required this.onSave,
    required this.onDelete,
  });

  final ReportDefinition definition;
  final String selectedViewId;
  final bool modified;
  final List<SavedReportView> savedViews;
  final ValueChanged<String> onSelect;
  final VoidCallback onSave;
  final ValueChanged<SavedReportView> onDelete;

  @override
  Widget build(BuildContext context) {
    return _ToolbarRow(
      label: 'VISTA',
      children: [
        for (final preset in definition.presets)
          ReportRangeChip(
            label: preset.label,
            selected: !modified && selectedViewId == preset.id,
            onTap: () => onSelect(preset.id),
          ),
        for (final view in savedViews)
          _SavedViewChip(
            label: view.name,
            selected: !modified &&
                selectedViewId == '$savedViewPrefix${view.id}',
            onTap: () => onSelect('$savedViewPrefix${view.id}'),
            onDelete: () => onDelete(view),
          ),
        if (modified) _SaveViewChip(onTap: onSave),
      ],
    );
  }
}

class _SavedViewChip extends StatelessWidget {
  const _SavedViewChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : AppColors.foreground;
    return Material(
      color: selected ? MangoColors.primaryOrange : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(reportRadius),
        side: BorderSide(
          color:
              selected ? MangoColors.primaryOrange : MangoColors.cardBorder,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: MangoColors.primaryOrange.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark_outline_rounded, size: 15, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: foreground,
                ),
              ),
              const SizedBox(width: 2),
              IconButton(
                tooltip: 'Eliminar vista',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 26, height: 26),
                onPressed: onDelete,
                icon: Icon(Icons.close_rounded, size: 15, color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Guardar vista": borde punteado naranja.
class _SaveViewChip extends StatelessWidget {
  const _SaveViewChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(color: AppColors.primary),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(reportRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: AppColors.primary.withValues(alpha: 0.08),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bookmark_add_outlined,
                    size: 15, color: AppColors.primary),
                SizedBox(width: 6),
                Text(
                  'Guardar vista',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.6),
      const Radius.circular(reportRadius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 5.0;
    const gap = 4.0;
    for (final PathMetric metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, distance + dash),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Barra de acciones: rango · Columnas · densidad · agrupar · Exportar.
class ReportTableActionBar extends StatelessWidget {
  const ReportTableActionBar({
    super.key,
    required this.rangeLabel,
    required this.visibleColumns,
    required this.onColumns,
    required this.density,
    required this.onDensity,
    required this.groupableColumns,
    required this.groupBy,
    required this.onGroupBy,
    required this.exportButton,
  });

  final String rangeLabel;
  final int visibleColumns;
  final VoidCallback onColumns;
  final ReportDensity density;
  final ValueChanged<ReportDensity> onDensity;

  /// Columnas visibles por las que se puede agrupar. Vacío = sin control.
  final List<ReportColumn> groupableColumns;
  final String? groupBy;
  final ValueChanged<String?> onGroupBy;
  final Widget exportButton;

  @override
  Widget build(BuildContext context) {
    final range = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.calendar_today,
              size: 14, color: AppColors.mutedForeground),
          const SizedBox(width: AppSpacing.sm),
          Text(
            rangeLabel,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
    final columns = OutlinedButton(
      style: reportOutlineButtonStyle(),
      onPressed: onColumns,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.view_column_outlined, size: 18),
          const SizedBox(width: 8),
          const Text('Columnas'),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(reportRadius),
            ),
            child: Text(
              '$visibleColumns',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    final densityToggle = _SegmentedToggle<ReportDensity>(
      value: density,
      options: const {
        ReportDensity.comfortable: 'Cómoda',
        ReportDensity.compact: 'Compacta',
      },
      onChanged: onDensity,
    );
    final group = groupableColumns.isEmpty
        ? null
        : _GroupByButton(
            columns: groupableColumns,
            groupBy: groupBy,
            onChanged: onGroupBy,
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final controls = <Widget>[
          columns,
          densityToggle,
          ?group,
          exportButton,
        ];
        if (constraints.maxWidth < 760) {
          return Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [range, ...controls],
          );
        }
        return Row(
          children: [
            range,
            const Spacer(),
            for (var i = 0; i < controls.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              controls[i],
            ],
          ],
        );
      },
    );
  }
}

class _SegmentedToggle<T> extends StatelessWidget {
  const _SegmentedToggle({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(reportRadius),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in options.entries)
            InkWell(
              onTap: () => onChanged(entry.key),
              borderRadius: BorderRadius.circular(reportRadius - 2),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: entry.key == value
                      ? MangoColors.primaryOrange
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(reportRadius - 2),
                ),
                child: Text(
                  entry.value,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: entry.key == value
                        ? Colors.white
                        : AppColors.foreground,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupByButton extends StatelessWidget {
  const _GroupByButton({
    required this.columns,
    required this.groupBy,
    required this.onChanged,
  });

  final List<ReportColumn> columns;
  final String? groupBy;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    String current = 'Sin agrupar';
    for (final column in columns) {
      if (column.id == groupBy) current = 'Por ${column.label.toLowerCase()}';
    }
    return MenuAnchor(
      style: _menuStyle,
      builder: (context, controller, _) => OutlinedButton.icon(
        style: reportOutlineButtonStyle(),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.segment_outlined, size: 18),
        label: Text('Agrupar: $current'),
      ),
      menuChildren: [
        MenuItemButton(
          onPressed: () => onChanged(null),
          leadingIcon: Icon(
            groupBy == null ? Icons.check_rounded : null,
            size: 16,
            color: AppColors.primary,
          ),
          child: const Text('Sin agrupar'),
        ),
        for (final column in columns)
          MenuItemButton(
            onPressed: () => onChanged(column.id),
            leadingIcon: Icon(
              groupBy == column.id ? Icons.check_rounded : null,
              size: 16,
              color: AppColors.primary,
            ),
            child: Text('Por ${column.label.toLowerCase()}'),
          ),
      ],
    );
  }
}

final MenuStyle _menuStyle = MenuStyle(
  backgroundColor: const WidgetStatePropertyAll(Colors.white),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.white),
  side: const WidgetStatePropertyAll(BorderSide(color: AppColors.border)),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(reportRadius),
    ),
  ),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
);

class _ExportFormatStyle {
  const _ExportFormatStyle(this.label, this.hint, this.icon, this.color);

  final String label;
  final String hint;
  final IconData icon;
  final Color color;
}

// PDF y CSV conservan los colores de `_ExportButton` del ReportScaffold.
const Map<ReportExportFormat, _ExportFormatStyle> _formatStyles = {
  ReportExportFormat.xlsx: _ExportFormatStyle('Excel',
      'Con formato y fila de total', Icons.grid_on_outlined, Color(0xFF059669)),
  ReportExportFormat.csv: _ExportFormatStyle('CSV',
      'Separado por comas, sin formato', Icons.table_view_outlined,
      Color(0xFF059669)),
  ReportExportFormat.txt: _ExportFormatStyle('Texto plano',
      'Columnas alineadas, ancho fijo', Icons.notes_outlined,
      AppColors.mutedForeground),
  ReportExportFormat.json: _ExportFormatStyle('JSON',
      'Para integrar con otro sistema', Icons.data_object_outlined,
      AppColors.mutedForeground),
  ReportExportFormat.pdf: _ExportFormatStyle('PDF',
      'Listo para imprimir o enviar', Icons.picture_as_pdf_outlined,
      Color(0xFFDC2626)),
};

/// Un solo botón Exportar. El encabezado del menú recuerda qué se exporta.
class ReportExportMenuButton extends StatelessWidget {
  const ReportExportMenuButton({
    super.key,
    required this.headline,
    required this.detail,
    required this.onExport,
    this.formats = ReportExportFormat.values,
  });

  final String headline;
  final String detail;
  final List<ReportExportFormat> formats;
  final Future<void> Function(ReportExportFormat format) onExport;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: _menuStyle,
      alignmentOffset: const Offset(0, 6),
      builder: (context, controller, _) => FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: MangoColors.primaryOrange,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(reportRadius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.file_download_outlined, size: 18),
        label: const Text('Exportar'),
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Exportar $headline',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: AppColors.border),
        for (final format in formats)
          MenuItemButton(
            onPressed: () => onExport(format),
            leadingIcon: Icon(
              _formatStyles[format]!.icon,
              size: 18,
              color: _formatStyles[format]!.color,
            ),
            trailingIcon: Text(
              '.${format.extension}',
              style: const TextStyle(
                fontFamily: reportNumberFontFamily,
                fontSize: 12,
                color: AppColors.mutedForeground,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatStyles[format]!.label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: AppColors.foreground,
                    ),
                  ),
                  Text(
                    _formatStyles[format]!.hint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Pide el nombre de la vista a guardar. Null si se cancela.
Future<String?> showSaveReportViewDialog(
  BuildContext context, {
  required String reportTitle,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final name = controller.text.trim();
        if (name.isNotEmpty) Navigator.of(context).pop(name);
      }

      return AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(reportRadius),
        ),
        title: const Text(
          'Guardar vista',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Guarda las columnas, su orden, la agrupación y la densidad '
                'de "$reportTitle". El rango de fechas no se guarda.',
                style: const TextStyle(
                  color: AppColors.mutedForeground,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: AppSpacing.itemGap),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 40,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  hintText: 'Ej.: Cierre del mes',
                  counterText: '',
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(color: AppColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(reportRadius),
                    borderSide: const BorderSide(color: AppColors.primary),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.mutedForeground,
            ),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: submit,
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(reportRadius),
              ),
            ),
            child: const Text('Guardar'),
          ),
        ],
      );
    },
  ).whenComplete(controller.dispose);
}
