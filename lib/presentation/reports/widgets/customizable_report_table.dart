import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/presentation/reports/model/report_column.dart';
import 'package:mangopos/presentation/reports/model/report_table_data.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

/// Roboto Mono empacada con la app (la misma de los tickets Star). Cifras en
/// monoespaciada para poder compararlas en columna, en todas las plataformas.
const String reportNumberFontFamily = 'RobotoTicketMono';

/// Avance de Roboto Mono: 0.6 em por caracter, regular y negrita. Permite
/// medir el ancho de una cifra sin maquetarla.
const double _monoAdvance = 0.6;

// Valores fijados por el diseño de la tabla (regla 6 y 8).
const Color _rowHover = Color(0xFFFFF8F2);
const Color _positive = Color(0xFF047857);
const Color _negative = Color(0xFFDC2626);
const Color _caution = Color(0xFFB45309);

// Regla de ancho: etiqueta + flecha de orden (15) + gap (6) + padding (28).
const double _sortIcon = 15;
const double _sortGap = 6;
const double _cellPadding = 14;

class ReportTableMetrics {
  const ReportTableMetrics._({
    required this.headerHeight,
    required this.rowHeight,
    required this.totalHeight,
    required this.fontSize,
    required this.headerFontSize,
  });

  static const comfortable = ReportTableMetrics._(
    headerHeight: 44,
    rowHeight: 46,
    totalHeight: 50,
    fontSize: 13,
    headerFontSize: 12,
  );

  static const compact = ReportTableMetrics._(
    headerHeight: 36,
    rowHeight: 34,
    totalHeight: 40,
    fontSize: 12,
    headerFontSize: 11.5,
  );

  static ReportTableMetrics of(ReportDensity density) =>
      density == ReportDensity.compact ? compact : comfortable;

  final double headerHeight;
  final double rowHeight;
  final double totalHeight;
  final double fontSize;
  final double headerFontSize;

  TextStyle headerStyle() => TextStyle(
        fontSize: headerFontSize,
        fontWeight: FontWeight.w700,
        color: AppColors.mutedForeground,
      );
}

double _kindFloor(ReportColumn column) {
  if (column.minWidth != null) return column.minWidth!;
  switch (column.kind) {
    // Un total de siete dígitos con centavos necesita ~130 px de texto.
    case ReportColumnKind.money:
      return 172;
    case ReportColumnKind.integer:
      return 96;
    case ReportColumnKind.decimal:
    case ReportColumnKind.percent:
      return 112;
    case ReportColumnKind.date:
      return 176;
    case ReportColumnKind.status:
      return 112;
    case ReportColumnKind.text:
      return column.locked ? 220 : 150;
  }
}

/// Ancho de cada columna visible. Ningún encabezado ni ninguna cifra queda
/// cortado: el encabezado se mide y las cifras (monoespaciadas) se calculan
/// por cantidad de caracteres, incluidos subtotales y total. El texto libre
/// se estima y tiene techo; si no cabe, lleva elipsis.
List<double> computeReportColumnWidths({
  required ReportTableData table,
  required ReportTableMetrics metrics,
  required TextStyle baseStyle,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final headerStyle = baseStyle.merge(metrics.headerStyle());
  final monoChar = textScaler.scale(metrics.fontSize) * _monoAdvance;
  final textChar = textScaler.scale(metrics.fontSize) * 0.56;

  double measure(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  final widths = <double>[];
  for (var c = 0; c < table.columns.length; c++) {
    final column = table.columns[c];
    var width = math.max(
      _kindFloor(column),
      measure(column.label, headerStyle) +
          _sortIcon +
          _sortGap +
          _cellPadding * 2,
    );
    var longest = 0;
    void consider(ReportCell cell) {
      if (cell.text.length > longest) longest = cell.text.length;
    }

    for (final row in table.rows) {
      if (row.cells.isNotEmpty) consider(row.cells[c]);
    }
    if (c != table.labelColumnIndex) consider(table.totals[c]);

    if (column.kind == ReportColumnKind.text) {
      final ceiling = column.locked ? 360.0 : 320.0;
      final estimate = longest * textChar + _cellPadding * 2;
      width = math.max(width, math.min(estimate, ceiling));
    } else if (column.kind != ReportColumnKind.status) {
      width = math.max(width, longest * monoChar + _cellPadding * 2 + 2);
    }
    if (c == table.labelColumnIndex) {
      // La fila de total pone su rótulo aquí: que se lea completo.
      final label = measure(
        table.totalLabel,
        baseStyle.merge(TextStyle(
          fontSize: metrics.fontSize,
          fontWeight: FontWeight.w800,
        )),
      );
      width = math.max(width, math.min(label + _cellPadding * 2, 380));
    }
    widths.add(width.ceilToDouble());
  }
  return widths;
}

/// Tabla única de los reportes de ventas. Encabezado y total fijos; el
/// cuerpo se virtualiza y hace scroll propio cuando pasa de [maxBodyHeight].
class CustomizableReportTable extends StatefulWidget {
  const CustomizableReportTable({
    super.key,
    required this.table,
    this.density = ReportDensity.comfortable,
    this.onSort,
    this.maxBodyHeight,
  });

  final ReportTableData table;
  final ReportDensity density;

  /// Null = encabezados sin orden (vistas previas).
  final ValueChanged<String>? onSort;
  final double? maxBodyHeight;

  @override
  State<CustomizableReportTable> createState() =>
      _CustomizableReportTableState();
}

class _CustomizableReportTableState extends State<CustomizableReportTable> {
  final _horizontal = ScrollController();
  final _vertical = ScrollController();

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final table = widget.table;
    final metrics = ReportTableMetrics.of(widget.density);
    final baseStyle = DefaultTextStyle.of(context).style;
    final widths = computeReportColumnWidths(
      table: table,
      metrics: metrics,
      baseStyle: baseStyle,
      textScaler: MediaQuery.textScalerOf(context),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final natural = widths.fold<double>(0, (sum, w) => sum + w);
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth - 2 : natural;
        // minmax(w, 1fr): la última columna absorbe el sobrante para no
        // dejar una franja vacía a la derecha.
        final resolved = [...widths];
        if (resolved.isNotEmpty && natural < available) {
          resolved[resolved.length - 1] += available - natural;
        }
        final contentWidth = math.max(natural, available);

        final maxBody = widget.maxBodyHeight ??
            math.max(280.0, MediaQuery.sizeOf(context).height * 0.6);
        final bodyExtent = table.rows.length * metrics.rowHeight;
        final scrolls = bodyExtent > maxBody;

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(reportRadius),
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Scrollbar(
            controller: _horizontal,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _HeaderRow(
                      table: table,
                      widths: resolved,
                      metrics: metrics,
                      onSort: widget.onSort,
                    ),
                    SizedBox(
                      height: math.min(bodyExtent, maxBody),
                      child: Scrollbar(
                        controller: _vertical,
                        child: ListView.builder(
                          controller: _vertical,
                          primary: false,
                          padding: EdgeInsets.zero,
                          physics: scrolls
                              ? const ClampingScrollPhysics()
                              : const NeverScrollableScrollPhysics(),
                          itemExtent: metrics.rowHeight,
                          itemCount: table.rows.length,
                          itemBuilder: (context, index) {
                            final row = table.rows[index];
                            switch (row.type) {
                              case ReportTableRowType.groupHeader:
                                return _GroupHeaderRow(
                                  row: row,
                                  metrics: metrics,
                                );
                              case ReportTableRowType.subtotal:
                                return _CellsRow(
                                  table: table,
                                  cells: row.cells,
                                  widths: resolved,
                                  metrics: metrics,
                                  style: _RowStyle.subtotal,
                                );
                              case ReportTableRowType.data:
                                return _DataRow(
                                  table: table,
                                  row: row,
                                  widths: resolved,
                                  metrics: metrics,
                                );
                            }
                          },
                        ),
                      ),
                    ),
                    _CellsRow(
                      table: table,
                      cells: table.totals,
                      widths: resolved,
                      metrics: metrics,
                      style: _RowStyle.total,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.table,
    required this.widths,
    required this.metrics,
    required this.onSort,
  });

  final ReportTableData table;
  final List<double> widths;
  final ReportTableMetrics metrics;
  final ValueChanged<String>? onSort;

  @override
  Widget build(BuildContext context) {
    final config = table.config;
    return Container(
      height: metrics.headerHeight,
      decoration: const BoxDecoration(
        color: AppColors.secondary,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          for (var c = 0; c < table.columns.length; c++)
            _HeaderCell(
              column: table.columns[c],
              width: widths[c],
              metrics: metrics,
              active: config.sortColumn == table.columns[c].id,
              ascending: config.sortAscending,
              onSort: onSort,
            ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.column,
    required this.width,
    required this.metrics,
    required this.active,
    required this.ascending,
    required this.onSort,
  });

  final ReportColumn column;
  final double width;
  final ReportTableMetrics metrics;
  final bool active;
  final bool ascending;
  final ValueChanged<String>? onSort;

  @override
  Widget build(BuildContext context) {
    final numeric = column.kind.isNumeric;
    final canSort = onSort != null && column.sortable;
    final Widget icon;
    if (!canSort) {
      icon = const SizedBox(width: _sortIcon);
    } else if (active) {
      icon = Icon(
        ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
        size: _sortIcon,
        color: AppColors.primary,
      );
    } else {
      icon = const Icon(
        Icons.unfold_more_rounded,
        size: _sortIcon,
        color: AppColors.mutedForeground,
      );
    }
    final label = Flexible(
      child: Text(
        column.label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: metrics.headerStyle().copyWith(
              color: active ? AppColors.foreground : null,
            ),
      ),
    );
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _cellPadding),
      child: Row(
        mainAxisAlignment:
            numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: numeric
            ? [icon, const SizedBox(width: _sortGap), label]
            : [label, const SizedBox(width: _sortGap), icon],
      ),
    );
    return SizedBox(
      width: width,
      height: double.infinity,
      child: canSort
          ? Tooltip(
              message: '${column.label} · ${column.source}',
              waitDuration: const Duration(milliseconds: 600),
              child: InkWell(
                onTap: () => onSort!(column.id),
                child: content,
              ),
            )
          : content,
    );
  }
}

class _GroupHeaderRow extends StatelessWidget {
  const _GroupHeaderRow({required this.row, required this.metrics});

  final ReportTableRow row;
  final ReportTableMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final size = row.groupSize;
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: _cellPadding),
      decoration: const BoxDecoration(
        color: AppColors.secondary,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Text(
        '${row.groupLabel} · $size ${size == 1 ? 'fila' : 'filas'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: metrics.fontSize,
          fontWeight: FontWeight.w800,
          color: AppColors.foreground,
        ),
      ),
    );
  }
}

class _DataRow extends StatefulWidget {
  const _DataRow({
    required this.table,
    required this.row,
    required this.widths,
    required this.metrics,
  });

  final ReportTableData table;
  final ReportTableRow row;
  final List<double> widths;
  final ReportTableMetrics metrics;

  @override
  State<_DataRow> createState() => _DataRowState();
}

class _DataRowState extends State<_DataRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final Color background;
    if (_hovered) {
      background = _rowHover;
    } else if (row.excluded) {
      background = AppColors.destructive.withValues(alpha: 0.06);
    } else {
      background = row.stripe.isOdd ? AppColors.background : Colors.white;
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: _CellsRow(
        table: widget.table,
        cells: row.cells,
        widths: widget.widths,
        metrics: widget.metrics,
        style: _RowStyle.data,
        background: background,
        excluded: row.excluded,
      ),
    );
  }
}

enum _RowStyle { data, subtotal, total }

class _CellsRow extends StatelessWidget {
  const _CellsRow({
    required this.table,
    required this.cells,
    required this.widths,
    required this.metrics,
    required this.style,
    this.background,
    this.excluded = false,
  });

  final ReportTableData table;
  final List<ReportCell> cells;
  final List<double> widths;
  final ReportTableMetrics metrics;
  final _RowStyle style;
  final Color? background;
  final bool excluded;

  @override
  Widget build(BuildContext context) {
    final BoxDecoration decoration;
    switch (style) {
      case _RowStyle.data:
        decoration = BoxDecoration(
          color: background,
          border: Border(
            bottom: BorderSide(
              color: AppColors.border.withValues(alpha: 0.6),
            ),
          ),
        );
      case _RowStyle.subtotal:
        decoration = const BoxDecoration(
          color: AppColors.background,
          border: Border(bottom: BorderSide(color: AppColors.border)),
        );
      case _RowStyle.total:
        // Fila de total fija al pie: naranja 6 %, borde superior 2 px al 25 %.
        decoration = BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.06),
          border: Border(
            top: BorderSide(
              color: AppColors.primary.withValues(alpha: 0.25),
              width: 2,
            ),
          ),
        );
    }
    return Container(
      height: style == _RowStyle.total ? metrics.totalHeight : null,
      decoration: decoration,
      child: Row(
        children: [
          for (var c = 0; c < table.columns.length; c++)
            SizedBox(
              width: widths[c],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: _cellPadding),
                child: _cell(table.columns[c], cells[c], c),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(ReportColumn column, ReportCell cell, int index) {
    final emphasized = style != _RowStyle.data;
    final isLabel = emphasized && index == table.labelColumnIndex;
    if (isLabel || column.kind == ReportColumnKind.text) {
      final strike = excluded && column.locked;
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          cell.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: metrics.fontSize,
            fontWeight: isLabel
                ? FontWeight.w800
                : column.locked || emphasized
                    ? FontWeight.w600
                    : FontWeight.w500,
            color: strike ? AppColors.destructive : AppColors.foreground,
            decoration: strike ? TextDecoration.lineThrough : null,
          ),
        ),
      );
    }
    if (column.kind == ReportColumnKind.status &&
        style == _RowStyle.data &&
        cell.raw != null) {
      final voided = excluded;
      return Align(
        alignment: Alignment.centerLeft,
        child: ReportStatusTag(
          label: cell.text,
          tone: voided ? AppColors.destructive : AppColors.success,
        ),
      );
    }

    Color color = AppColors.foreground;
    if (cell.raw == null) {
      color = AppColors.mutedForeground;
    } else if (column.tone == ReportCellTone.signed && cell.raw is num) {
      color = (cell.raw as num) >= 0 ? _positive : _negative;
    } else if (column.tone == ReportCellTone.cautionWhenPositive &&
        cell.raw is num &&
        (cell.raw as num) > 0) {
      color = _caution;
    }
    final strike = excluded && column.kind == ReportColumnKind.money;
    if (strike) color = AppColors.destructive;
    return Align(
      alignment: column.kind.isNumeric
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Text(
        cell.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: TextStyle(
          fontFamily: reportNumberFontFamily,
          fontSize: metrics.fontSize,
          fontWeight: emphasized ? FontWeight.w700 : FontWeight.w400,
          color: color,
          decoration: strike ? TextDecoration.lineThrough : null,
        ),
      ),
    );
  }
}
