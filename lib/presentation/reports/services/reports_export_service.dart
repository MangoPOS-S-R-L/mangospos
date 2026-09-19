import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:excel/excel.dart' as xlsx;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/fiscal/ncf_types.dart';
import '../../../data/models/table_deposit_report.dart';
import '../model/report_column.dart';
import '../model/report_table_data.dart';
import '../viewmodel/reports_viewmodel.dart';
import 'reports_csv_export_service.dart';

/// Formatos del botón Exportar de la tabla personalizable.
enum ReportExportFormat {
  xlsx,
  csv,
  txt,
  json,
  pdf;

  String get extension => name;
}

class ReportsExportService {
  // ---------------------------------------------------------------------------
  // Tabla personalizable: el export refleja el estado de la tabla (columnas
  // visibles, su orden, el orden de filas, subtotales y la fila de total).
  // ---------------------------------------------------------------------------

  static Future<void> exportTable(
    ReportTableExport export,
    ReportExportFormat format,
  ) async {
    switch (format) {
      case ReportExportFormat.csv:
        await ReportsCsvExportService.exportTable(export);
      case ReportExportFormat.xlsx:
        final bytes = buildTableXlsx(export);
        if (bytes == null) {
          throw StateError('No se pudo generar el archivo de Excel.');
        }
        await _saveBytes('${export.fileStem}.xlsx', bytes, 'Guardar Excel');
      case ReportExportFormat.txt:
        await _saveBytes(
          '${export.fileStem}.txt',
          Uint8List.fromList(utf8.encode(buildTableTxt(export))),
          'Guardar texto plano',
        );
      case ReportExportFormat.json:
        await _saveBytes(
          '${export.fileStem}.json',
          Uint8List.fromList(utf8.encode(buildTableJson(export))),
          'Guardar JSON',
        );
      case ReportExportFormat.pdf:
        await deliverPdf(await buildTablePdf(export), '${export.fileStem}.pdf');
    }
  }

  /// Entrega un PDF de reporte. En macOS se GUARDA con "Guardar como": ahí
  /// `sharePdf` abre el menú Compartir del sistema pegado a la esquina de la
  /// ventana, sin Guardar ni Imprimir, y parece que el botón no hizo nada. En
  /// el resto se comparte como siempre (Windows lo abre en el visor de PDF;
  /// Android/iOS, hoja de compartir con Imprimir y Guardar).
  static Future<void> deliverPdf(Uint8List bytes, String filename) async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      await _saveBytes(filename, bytes, 'Guardar PDF');
      return;
    }
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }

  static Future<void> _saveBytes(
    String fileName,
    Uint8List bytes,
    String dialogTitle,
  ) async {
    await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: bytes,
    );
  }

  static String _generatedAt() =>
      DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now());

  /// Texto plano: columnas alineadas a ancho fijo, cifras a la derecha.
  static String buildTableTxt(ReportTableExport export) {
    final table = export.table;
    final columns = table.columns;
    final lines = <List<String>>[
      [for (final column in columns) column.label],
    ];
    final widths = [for (final column in columns) column.label.length];
    void measure(List<String> cells) {
      for (var c = 0; c < cells.length; c++) {
        widths[c] = math.max(widths[c], cells[c].length);
      }
    }

    final body = <Object>[];
    for (final row in table.rows) {
      if (row.type == ReportTableRowType.groupHeader) {
        body.add('» ${row.groupLabel} (${row.groupSize} '
            '${row.groupSize == 1 ? 'fila' : 'filas'})');
        continue;
      }
      final cells = [for (final cell in row.cells) cell.text];
      measure(cells);
      body.add(cells);
    }
    final totals = [for (final cell in table.totals) cell.text];
    measure(totals);
    measure(lines.first);

    String render(List<String> cells) {
      final out = <String>[];
      for (var c = 0; c < columns.length; c++) {
        out.add(columns[c].kind.isNumeric
            ? cells[c].padLeft(widths[c])
            : cells[c].padRight(widths[c]));
      }
      return out.join('  ').trimRight();
    }

    final rule = [for (final w in widths) '-' * w].join('  ');
    final buffer = StringBuffer()
      ..writeln(export.title)
      ..writeln('Rango: ${export.rangeLabel}')
      ..writeln('Generado: ${_generatedAt()}')
      ..writeln()
      ..writeln(render(lines.first))
      ..writeln(rule);
    for (final item in body) {
      buffer.writeln(item is String ? item : render(item as List<String>));
    }
    buffer
      ..writeln(rule)
      ..writeln(render(totals));
    if (export.notes.isNotEmpty) {
      buffer.writeln();
      for (final note in export.notes) {
        buffer.writeln(note);
      }
    }
    return buffer.toString();
  }

  static Object? _jsonValue(ReportCell cell, int decimals) {
    final raw = cell.raw;
    if (raw is DateTime) return raw.toIso8601String();
    if (raw is double) {
      return double.parse(raw.toStringAsFixed(math.max(decimals, 4)));
    }
    return raw;
  }

  /// JSON para integrar con otro sistema: filas como objetos por id de
  /// columna, con el catálogo de columnas (tipo y campo de origen).
  static String buildTableJson(ReportTableExport export) {
    final table = export.table;
    final columns = table.columns;
    Map<String, Object?> values(List<ReportCell> cells) => {
          for (var c = 0; c < columns.length; c++)
            columns[c].id: _jsonValue(cells[c], export.currencyDecimals),
        };

    String? group;
    final rows = <Map<String, Object?>>[];
    final subtotals = <Map<String, Object?>>[];
    for (final row in table.rows) {
      switch (row.type) {
        case ReportTableRowType.groupHeader:
          group = row.groupLabel;
        case ReportTableRowType.subtotal:
          subtotals.add({'group': row.groupLabel, 'values': values(row.cells)});
        case ReportTableRowType.data:
          rows.add({
            ...values(row.cells),
            '_group': ?group,
            if (row.excluded) '_excluded': true,
          });
      }
    }
    final payload = <String, Object?>{
      'report': export.title,
      'key': table.definition.key,
      'source': table.definition.source,
      'range': {
        'from': DateFormat('yyyy-MM-dd').format(export.from),
        'to': DateFormat('yyyy-MM-dd').format(export.to),
      },
      'generated_at': DateTime.now().toIso8601String(),
      'currency': export.currencyCode,
      'columns': [
        for (final column in columns)
          {
            'id': column.id,
            'label': column.label,
            'type': column.kind.name,
            'source': column.source,
            'total': column.total.name,
          },
      ],
      'sort': table.config.sortColumn == null
          ? null
          : {
              'column': table.config.sortColumn,
              'ascending': table.config.sortAscending,
            },
      'group_by': table.config.groupBy,
      'rows': rows,
      if (subtotals.isNotEmpty) 'subtotals': subtotals,
      'total': {
        'label': table.totalLabel,
        'valid_rows': table.validRowCount,
        'excluded_rows': table.excludedRowCount,
        'values': values(table.totals),
      },
      if (export.notes.isNotEmpty) 'notes': export.notes,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Excel con formato: encabezado, cifras como número (no texto), subtotales
  /// y fila de total resaltada.
  static Uint8List? buildTableXlsx(ReportTableExport export) {
    final table = export.table;
    final columns = table.columns;
    final excel = xlsx.Excel.createExcel();
    var sheetName = export.title.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ');
    if (sheetName.length > 31) sheetName = sheetName.substring(0, 31);
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != sheetName) {
      excel.rename(defaultSheet, sheetName);
    }
    final sheet = excel[sheetName];

    final secondary = xlsx.ExcelColor.fromHexString('#F5F1EE');
    final totalFill = xlsx.ExcelColor.fromHexString('#FFF7F1');
    final orange = xlsx.ExcelColor.fromHexString('#F97316');
    final muted = xlsx.ExcelColor.fromHexString('#7D726D');
    final moneyFormat = export.currencyDecimals <= 0
        ? '#,##0'
        : '#,##0.${'0' * export.currencyDecimals}';

    xlsx.NumFormat? numFormat(ReportColumnKind kind) => switch (kind) {
          ReportColumnKind.money =>
            xlsx.CustomNumericNumFormat(formatCode: moneyFormat),
          ReportColumnKind.integer =>
            const xlsx.CustomNumericNumFormat(formatCode: '#,##0'),
          ReportColumnKind.decimal =>
            const xlsx.CustomNumericNumFormat(formatCode: '#,##0.##'),
          ReportColumnKind.percent =>
            const xlsx.CustomNumericNumFormat(formatCode: '0.0%'),
          ReportColumnKind.date =>
            const xlsx.CustomDateTimeNumFormat(formatCode: 'dd/mm/yyyy hh:mm'),
          _ => null,
        };

    xlsx.CellIndex at(int column, int row) =>
        xlsx.CellIndex.indexByColumnRow(columnIndex: column, rowIndex: row);

    sheet.updateCell(at(0, 0), xlsx.TextCellValue(export.title),
        cellStyle: xlsx.CellStyle(bold: true, fontSize: 14));
    sheet.updateCell(at(0, 1), xlsx.TextCellValue('Rango: ${export.rangeLabel}'),
        cellStyle: xlsx.CellStyle(fontColorHex: muted));

    const headerRow = 3;
    for (var c = 0; c < columns.length; c++) {
      sheet.updateCell(
        at(c, headerRow),
        xlsx.TextCellValue(columns[c].label),
        cellStyle: xlsx.CellStyle(
          bold: true,
          backgroundColorHex: secondary,
          horizontalAlign: columns[c].kind.isNumeric
              ? xlsx.HorizontalAlign.Right
              : xlsx.HorizontalAlign.Left,
        ),
      );
    }

    void writeCells(
      int rowIndex,
      List<ReportCell> cells, {
      bool bold = false,
      xlsx.ExcelColor? fill,
      bool topBorder = false,
    }) {
      for (var c = 0; c < columns.length; c++) {
        final column = columns[c];
        final cell = cells[c];
        final raw = cell.raw;
        final border = topBorder
            ? xlsx.Border(
                borderStyle: xlsx.BorderStyle.Medium, borderColorHex: orange)
            : null;
        xlsx.CellStyle style({xlsx.NumFormat? format, bool right = false}) =>
            xlsx.CellStyle(
              bold: bold,
              backgroundColorHex: fill ?? xlsx.ExcelColor.none,
              topBorder: border,
              horizontalAlign:
                  right ? xlsx.HorizontalAlign.Right : xlsx.HorizontalAlign.Left,
              numberFormat: format ?? xlsx.NumFormat.standard_0,
            );
        final format = numFormat(column.kind);
        if (raw is num && format != null && column.kind.isNumeric) {
          final value = column.kind == ReportColumnKind.percent
              ? raw / 100
              : raw;
          final cellValue = column.kind == ReportColumnKind.integer
              ? xlsx.IntCellValue(value.round())
              : xlsx.DoubleCellValue(value.toDouble());
          sheet.updateCell(at(c, rowIndex), cellValue,
              cellStyle: style(format: format, right: true));
        } else if (raw is DateTime && format != null) {
          sheet.updateCell(
            at(c, rowIndex),
            xlsx.DateTimeCellValue(
              year: raw.year,
              month: raw.month,
              day: raw.day,
              hour: raw.hour,
              minute: raw.minute,
            ),
            cellStyle: style(format: format),
          );
        } else if (cell.text.isNotEmpty) {
          sheet.updateCell(at(c, rowIndex), xlsx.TextCellValue(cell.text),
              cellStyle: style(right: column.kind.isNumeric));
        } else if (fill != null || topBorder) {
          sheet.updateCell(at(c, rowIndex), xlsx.TextCellValue(''),
              cellStyle: style());
        }
      }
    }

    var rowIndex = headerRow + 1;
    for (final row in table.rows) {
      switch (row.type) {
        case ReportTableRowType.groupHeader:
          sheet.updateCell(
            at(0, rowIndex),
            xlsx.TextCellValue('${row.groupLabel} (${row.groupSize})'),
            cellStyle:
                xlsx.CellStyle(bold: true, backgroundColorHex: secondary),
          );
        case ReportTableRowType.subtotal:
          writeCells(rowIndex, row.cells, bold: true);
        case ReportTableRowType.data:
          writeCells(rowIndex, row.cells);
      }
      rowIndex++;
    }
    writeCells(rowIndex, table.totals,
        bold: true, fill: totalFill, topBorder: true);
    rowIndex += 2;
    for (final note in export.notes) {
      sheet.updateCell(at(0, rowIndex++), xlsx.TextCellValue(note),
          cellStyle: xlsx.CellStyle(fontColorHex: muted));
    }

    for (var c = 0; c < columns.length; c++) {
      var width = columns[c].label.length;
      for (final row in table.rows) {
        if (row.cells.isEmpty) continue;
        width = math.max(width, row.cells[c].text.length);
      }
      width = math.max(width, table.totals[c].text.length);
      sheet.setColumnWidth(c, (width + 3).clamp(8, 48).toDouble());
    }

    final encoded = excel.encode();
    return encoded == null ? null : Uint8List.fromList(encoded);
  }

  static const Map<int, String> _pdfReplacements = {
    0x2014: '-', // — guion largo (el "sin dato" de la tabla)
    0x2013: '-', // – rango
    0x2026: '...',
    0x2018: "'",
    0x2019: "'",
    0x201C: '"',
    0x201D: '"',
    0x20AC: 'EUR ', // €
    0x20A1: 'CRC ', // ₡
    0x20B2: 'PYG ', // ₲
  };

  /// La fuente base del PDF (Helvetica) solo acepta U+0000–U+00FF: cualquier
  /// otro caracter (€, un nombre de cliente con Š, un emoji) hace que el
  /// paquete lance excepción. Se reemplaza por un equivalente o por '?'.
  static String _pdfSafe(String value) {
    final out = StringBuffer();
    for (final rune in value.runes) {
      if (rune <= 0xFF) {
        out.writeCharCode(rune);
      } else {
        out.write(_pdfReplacements[rune] ?? '?');
      }
    }
    return out.toString();
  }

  /// PDF listo para imprimir o enviar. Apaisado cuando la tabla es ancha.
  static Future<Uint8List> buildTablePdf(ReportTableExport export) async {
    final table = export.table;
    final columns = table.columns;
    final landscape = columns.length > 6;
    final small = columns.length > 9;
    final fontSize = small ? 7.0 : 8.5;
    final totalFill = PdfColor.fromHex('#FFF7F1');
    final secondary = PdfColor.fromHex('#F5F1EE');
    final border = PdfColor.fromHex('#E0DBD9');

    pw.Widget text(String value, {bool bold = false, bool right = false}) =>
        pw.Align(
          alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
          child: pw.Text(
            _pdfSafe(value),
            style: pw.TextStyle(
              fontSize: fontSize,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        );

    final data = <List<pw.Widget>>[];
    final emphasized = <int>{};
    final groupRows = <int>{};
    for (final row in table.rows) {
      if (row.type == ReportTableRowType.groupHeader) {
        groupRows.add(data.length);
        data.add([
          for (var c = 0; c < columns.length; c++)
            c == 0
                ? text('${row.groupLabel} (${row.groupSize})', bold: true)
                : pw.SizedBox(),
        ]);
        continue;
      }
      final bold = row.type == ReportTableRowType.subtotal;
      if (bold) emphasized.add(data.length);
      data.add([
        for (var c = 0; c < columns.length; c++)
          text(row.cells[c].text,
              bold: bold, right: columns[c].kind.isNumeric),
      ]);
    }
    final totalRow = data.length;
    data.add([
      for (var c = 0; c < columns.length; c++)
        text(table.totals[c].text,
            bold: true, right: columns[c].kind.isNumeric),
    ]);

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat:
            landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        maxPages: 500,
        margin: const pw.EdgeInsets.all(24),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              _pdfSafe(export.title),
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              _pdfSafe('Rango: ${export.rangeLabel} · '
                  '${columns.length} columnas · ${table.dataRowCount} filas'),
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 10),
          ],
        ),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Página ${context.pageNumber} de ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: [
              for (final column in columns)
                text(column.label,
                    bold: true, right: column.kind.isNumeric),
            ],
            data: data,
            headerDecoration: pw.BoxDecoration(color: secondary),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            border: pw.TableBorder(
              horizontalInside: pw.BorderSide(color: border, width: 0.5),
              bottom: pw.BorderSide(color: border, width: 0.5),
              top: pw.BorderSide(color: border, width: 0.5),
            ),
            cellDecoration: (index, cell, rowNum) {
              // rowNum cuenta el encabezado como fila 0.
              final dataRow = rowNum - 1;
              if (dataRow == totalRow) {
                return pw.BoxDecoration(color: totalFill);
              }
              if (groupRows.contains(dataRow) ||
                  emphasized.contains(dataRow)) {
                return pw.BoxDecoration(color: secondary);
              }
              return const pw.BoxDecoration();
            },
          ),
          if (export.notes.isNotEmpty) ...[
            pw.SizedBox(height: 8),
            for (final note in export.notes)
              pw.Text(
                _pdfSafe(note),
                style:
                    const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
              ),
          ],
        ],
      ),
    );
    return doc.save();
  }

  // ---------------------------------------------------------------------------
  // Export por categoría (resto de reportes y "Vista general" de ventas).
  // ---------------------------------------------------------------------------

  static Future<void> exportCurrentReport({
    required ReportCategory category,
    required ReportsState state,
    required ReportsViewModel viewModel,
  }) async {
    final filename =
        'reporte_${category.name}_${DateTime.now().millisecondsSinceEpoch}.pdf';
    await deliverPdf(
      await buildCurrentReportPdf(
        category: category,
        state: state,
        viewModel: viewModel,
      ),
      filename,
    );
  }

  /// Bytes del PDF por categoría, separado de la entrega para poder probar
  /// que el documento se arma sin lanzar.
  static Future<Uint8List> buildCurrentReportPdf({
    required ReportCategory category,
    required ReportsState state,
    required ReportsViewModel viewModel,
  }) async {
    final pdf = pw.Document();
    final dateFormat = DateFormat('dd/MM/yyyy');
    final from = dateFormat.format(state.salesFrom);
    final to = dateFormat.format(
      state.salesTo.subtract(const Duration(days: 1)),
    );

    final title =
        category == ReportCategory.sales &&
            state.salesSubReport == SalesSubReport.byReceipt
        ? 'Reporte de comprobantes'
        : viewModel.getCategoryTitle(category);

    // Reportes con detalle de comprobantes (fiscal, byReceipt) suelen
    // tener tablas anchas (NCF + cliente + RNC + N columnas de impuestos
    // + total + estado + fecha) y muchas filas. Landscape + maxPages
    // alto evita TooManyPagesException cuando el rango cubre semanas
    // de operación. Las otras categorías mantienen retrato y márgenes
    // estándar.
    final useLandscape =
        category == ReportCategory.fiscal ||
        category == ReportCategory.deposits ||
        (category == ReportCategory.sales &&
            state.salesSubReport == SalesSubReport.byReceipt);
    final pageFormat = useLandscape
        ? PdfPageFormat.a4.landscape
        : PdfPageFormat.a4;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        maxPages: 500,
        margin: const pw.EdgeInsets.all(24),
        build: (context) => [
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text('Rango: $from - $to'),
          pw.SizedBox(height: 16),
          ..._buildCategoryContent(category, state, viewModel),
        ],
      ),
    );
    return pdf.save();
  }

  static List<pw.Widget> _buildCategoryContent(
    ReportCategory category,
    ReportsState state,
    ReportsViewModel viewModel,
  ) {
    switch (category) {
      case ReportCategory.sales:
        // Sub-reporte "Por comprobante" sale enfocado al estilo del
        // PDF de impuestos: solo métricas + tabla de comprobantes.
        // El dump completo de ventas (categorías, empleados, productos,
        // etc.) solo se exporta en "Vista general".
        if (state.salesSubReport == SalesSubReport.byReceipt) {
          return [
            _metricsTable(viewModel.getSalesMetricCards()),
            pw.SizedBox(height: 16),
            ..._breakdownTable(
              'Ventas por recibo / comprobante',
              viewModel.getReceiptRows(),
            ),
            pw.SizedBox(height: 16),
            // Cada comprobante listado individualmente con su estado
            // (Activo/Anulado), igual que el reporte fiscal. Respeta el
            // toggle "Ver anulados": por defecto el PDF sale solo con los
            // válidos, que son los que suman a los totales de arriba.
            ..._fiscalDocumentsTable(
              viewModel.getVisibleFiscalDocuments(),
              _serviceFeeLabelOf(state),
            ),
          ];
        }
        return [
          _metricsTable(viewModel.getSalesMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Ventas por tipo de pago',
            viewModel.getPaymentMethodRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Ventas por categoría',
            viewModel.getCategoryRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Ventas por empleado', viewModel.getEmployeeRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Ventas por recibo / comprobante',
            viewModel.getReceiptRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Ventas por modificadores',
            viewModel.getModifierRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Descuentos y cortesías',
            viewModel.getDiscountRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._productSalesTable(viewModel.getFilteredProductSalesRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Top productos',
            viewModel.getTopProductRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Ventas por zona', viewModel.getZoneRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Ventas por hora', viewModel.getHourlyRows()),
        ];
      case ReportCategory.offers:
        return [
          ..._offerProductTotalsTable(viewModel),
          pw.SizedBox(height: 16),
          ..._offersDetailTable(viewModel),
        ];
      case ReportCategory.delivery:
        return _deliveryDetailTable(viewModel);
      case ReportCategory.deposits:
        return _depositsTables(
          state.depositsReport ?? TableDepositReport.empty,
        );
      case ReportCategory.finances:
        return [
          _metricsTable(viewModel.getFinanceMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Movimientos por tipo',
            viewModel.getFinanceTypeRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Sesiones', viewModel.getFinanceSessionRows()),
        ];
      case ReportCategory.inventory:
        return [
          _metricsTable(viewModel.getInventoryMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Top stock',
            viewModel.getInventoryTopStockRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Alertas',
            viewModel.getInventoryAlertRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable('Movimientos', viewModel.getInventoryMovementRows()),
        ];
      case ReportCategory.purchases:
        return [
          _metricsTable(viewModel.getPurchaseMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable('Estados', viewModel.getPurchaseStatusRows()),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Top proveedores',
            viewModel.getPurchaseSupplierRows(),
          ),
        ];
      case ReportCategory.taxes:
        // FUENTE: fiscalSummary (tabla fiscal_documents = NCFs emitidos).
        // ANTES usaba getTaxMetricCards/getTaxTypeRows (reconstrucción Dart
        // desde payments+items) y daba números distintos a los del view
        // (delta 30%+). Ahora ambos toman de la misma fuente.
        return [
          _metricsTable(viewModel.getTaxReportMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Total facturado por tipo de comprobante',
            viewModel.getTaxReportTypeRows(),
            showQuantity: true,
          ),
        ];
      case ReportCategory.fiscal:
        return [
          _metricsTable(viewModel.getFiscalMetricCards()),
          pw.SizedBox(height: 16),
          ..._breakdownTable(
            'Comprobantes por tipo de NCF',
            viewModel.getFiscalTypeRows(),
          ),
          pw.SizedBox(height: 12),
          ..._breakdownTable(
            'Desglose por tipo de impuesto',
            viewModel.getFiscalTaxBreakdownRows(),
            showQuantity: true,
          ),
          pw.SizedBox(height: 16),
          // Respeta el toggle "Ver anulados" (el filtro de tipo se deja fuera
          // a propósito: el PDF fiscal siempre exportó el rango completo).
          ..._fiscalDocumentsTable(
              viewModel.getVisibleFiscalDocuments(),
              _serviceFeeLabelOf(state),
            ),
        ];
    }
  }

  static pw.Widget _metricsTable(List<SalesMetricCardData> metrics) {
    return pw.TableHelper.fromTextArray(
      headers: const ['Métrica', 'Valor', 'Detalle'],
      data: metrics
          .map((m) => [m.title, m.value, m.subtitle])
          .toList(growable: false),
    );
  }

  /// Pivote: cantidad despachada por producto, con la suma total al final.
  static List<pw.Widget> _offerProductTotalsTable(ReportsViewModel viewModel) {
    final rows = viewModel.getOfferProductTotals();
    if (rows.isEmpty) return [];
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');
    final data = rows
        .map((row) => [row.productName, qtyFormat.format(row.quantity)])
        .toList();
    data.add(['Suma total', qtyFormat.format(viewModel.offersTotalQuantity)]);
    return [
      pw.Text(
        'Productos en oferta',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const ['Producto', 'Cantidad'],
        data: data,
      ),
    ];
  }

  /// Listado detallado: una fila por cada vez que se aplicó una oferta.
  static List<pw.Widget> _deliveryDetailTable(ReportsViewModel viewModel) {
    final rows = viewModel.getDeliveryFeeRows();
    if (rows.isEmpty) return [];
    final moneyFormat = NumberFormat('#,##0.00', 'en_US');
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
    return [
      pw.Text(
        'Fees de delivery cobrados',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const [
          'Fecha de cobro',
          'Cliente',
          'Total de la orden',
          'Fee de delivery',
        ],
        data: [
          ...rows.map(
            (row) => [
              row.paidAt != null ? dateFormat.format(row.paidAt!) : '',
              row.customerName,
              moneyFormat.format(row.orderTotal),
              moneyFormat.format(row.deliveryFee),
            ],
          ),
          [
            'Total',
            '${viewModel.deliveryOrdersCount} órdenes',
            moneyFormat.format(viewModel.deliveryTotalOrdersAmount),
            moneyFormat.format(viewModel.deliveryTotalFees),
          ],
        ],
      ),
    ];
  }

  /// Reporte de abonos: saldos vigentes por mesa + movimientos del rango.
  /// Nombres, referencias y notas los escribe la gente: pasan por
  /// [_pdfSafe] o un emoji tumba el PDF entero.
  static List<pw.Widget> _depositsTables(TableDepositReport report) {
    final money = NumberFormat('#,##0.00', 'en_US');
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm');
    String text(String? value) => _pdfSafe(value ?? '');
    final heading = pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold);

    return [
      pw.TableHelper.fromTextArray(
        headers: const [
          'Saldo vigente',
          'Mesas con saldo',
          'Abonado en el rango',
          'Consumido en el rango',
          'Devuelto en el rango',
        ],
        data: [
          [
            money.format(report.outstandingBalance),
            '${report.accountsWithBalance}',
            money.format(report.periodDeposited),
            money.format(report.periodConsumed),
            money.format(report.periodRefunded),
          ],
        ],
      ),
      pw.SizedBox(height: 16),
      pw.Text('Saldos por mesa', style: heading),
      pw.SizedBox(height: 2),
      pw.Text(
        'Balance al momento de exportar. Abonado y consumido son del abono '
        'vigente de cada mesa.',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 6),
      if (report.accounts.isEmpty)
        pw.Text('No hay mesas con saldo ni movimientos en el rango.')
      else
        pw.TableHelper.fromTextArray(
          headers: const [
            'Mesa',
            'A nombre de',
            'Referencia',
            'Abonado',
            'Consumido',
            'Devuelto',
            'Balance',
          ],
          data: [
            for (final a in report.accounts)
              [
                text(a.tableLabel),
                text(a.holderName ?? '-'),
                text(a.references.isEmpty ? '-' : a.referenceLabel),
                money.format(a.deposited),
                money.format(a.consumed),
                money.format(a.returned),
                money.format(a.balance),
              ],
            [
              'Total',
              '',
              '',
              '',
              '',
              '',
              money.format(report.outstandingBalance),
            ],
          ],
        ),
      pw.SizedBox(height: 16),
      pw.Text('Movimientos del rango', style: heading),
      pw.SizedBox(height: 6),
      if (report.movements.isEmpty)
        pw.Text('Sin movimientos en el rango.')
      else
        pw.TableHelper.fromTextArray(
          headers: const [
            'Fecha',
            'Mesa',
            'A nombre de',
            'Tipo',
            'Referencia',
            'Método',
            'Monto',
            'Balance',
            'Registrado por',
          ],
          data: [
            for (final m in report.movements)
              [
                dateFormat.format(m.createdAt),
                text(m.tableLabel),
                text(m.holderName ?? '-'),
                text(m.typeLabel),
                text(m.reference ?? m.note ?? '-'),
                text(m.methodName ?? '-'),
                money.format(m.amount),
                money.format(m.balanceAfter),
                text(m.createdByName ?? '-'),
              ],
          ],
        ),
    ];
  }

  static List<pw.Widget> _offersDetailTable(ReportsViewModel viewModel) {
    final rows = viewModel.getOfferDetailRows();
    if (rows.isEmpty) return [];
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');
    final moneyFormat = NumberFormat('#,##0.00', 'en_US');
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
    return [
      pw.Text(
        'Detalle de ofertas',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const [
          'Fecha',
          'Oferta',
          'Producto',
          'Cantidad',
          'Valor a precio de menú',
          'Descuento otorgado',
        ],
        data: [
          ...rows.map(
            (row) => [
              row.dateTime != null ? dateFormat.format(row.dateTime!) : '',
              row.offerName,
              row.productName,
              qtyFormat.format(row.quantity),
              moneyFormat.format(row.valorMenu),
              moneyFormat.format(row.descuento),
            ],
          ),
          [
            'Total',
            '',
            '',
            qtyFormat.format(viewModel.offersTotalQuantity),
            moneyFormat.format(viewModel.offersTotalValorMenu),
            moneyFormat.format(viewModel.offersTotalDescuento),
          ],
        ],
      ),
    ];
  }

  static List<pw.Widget> _productSalesTable(List<ProductSalesReportRow> rows) {
    if (rows.isEmpty) return [];
    final numberFormat = NumberFormat('#,##0.00', 'en_US');
    return [
      pw.Text(
        'Ventas por producto',
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        cellStyle: const pw.TextStyle(fontSize: 8),
        headers: const [
          'Producto',
          'Categoría',
          'Cant.',
          'Brutas',
          'Desc.',
          'Cortesías',
          'Netas',
          'Costo',
          'Gan. bruta',
          'Margen %',
        ],
        data: rows
            .map(
              (row) => [
                row.product,
                row.category,
                numberFormat.format(row.quantitySold),
                numberFormat.format(row.grossSales),
                numberFormat.format(row.discounts),
                numberFormat.format(row.courtesies),
                numberFormat.format(row.netSales),
                numberFormat.format(row.cost),
                numberFormat.format(row.grossProfit),
                row.marginPct == null
                    ? '--'
                    : '${row.marginPct!.toStringAsFixed(1)}%',
              ],
            )
            .toList(growable: false),
      ),
    ];
  }

  // _ncfTypeName eliminado: ahora se usa `ncfTypeName(code)` de
  // core/fiscal/ncf_types.dart (catálogo único para toda la app).

  // Skip "Impuesto X%" entries — fallback que produce el repositorio
  // cuando el tax_rate combinado (ej. 28% = ITBIS+Propina) no pudo
  // desdoblarse, y crea una columna extra que rompe el layout.
  static final RegExp _kUnmappedTaxLabelRe = RegExp(r'^Impuesto\s');

  /// Label del service fee derivado de la config del comercio
  /// (`fiscalSummary.service_fee_label`). Fallback genérico — antes era
  /// "Propina de ley" hardcoded en varios lugares.
  static String _serviceFeeLabelOf(ReportsState state) {
    final raw =
        (state.fiscalSummary?['service_fee_label'] as String?)?.trim();
    return (raw?.isNotEmpty ?? false) ? raw! : 'Cargo de servicio';
  }

  static List<String> _collectTaxLabels(
    List<Map<String, dynamic>> documents,
    String serviceFeeLabel,
  ) {
    final labels = <String>{};
    for (final doc in documents) {
      final breakdown = doc['tax_breakdown'];
      if (breakdown is List) {
        for (final item in breakdown) {
          final m = item is Map<String, dynamic>
              ? item
              : Map<String, dynamic>.from(item as Map);
          final label = m['label']?.toString() ?? '';
          if (_kUnmappedTaxLabelRe.hasMatch(label)) continue;
          final rate = (m['rate'] as num?)?.toDouble() ?? 0;
          final display = rate > 0
              ? '$label (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
              : label;
          if (display.isNotEmpty) labels.add(display);
        }
      }
      final sf = (doc['service_fee'] as num?)?.toDouble() ?? 0;
      if (sf > 0) labels.add(serviceFeeLabel);
    }
    return labels.toList(growable: false);
  }

  static double _taxAmountForLabel(
    Map<String, dynamic> doc,
    String label,
    String serviceFeeLabel,
  ) {
    if (label == serviceFeeLabel) {
      return (doc['service_fee'] as num?)?.toDouble() ?? 0;
    }
    final breakdown = doc['tax_breakdown'];
    if (breakdown is! List) return 0;
    for (final item in breakdown) {
      final m = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item as Map);
      final itemLabel = m['label']?.toString() ?? '';
      final rate = (m['rate'] as num?)?.toDouble() ?? 0;
      final display = rate > 0
          ? '$itemLabel (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
          : itemLabel;
      if (display == label) {
        return (m['tax_amount'] as num?)?.toDouble() ?? 0;
      }
    }
    return 0;
  }

  static List<pw.Widget> _fiscalDocumentsTable(
    List<Map<String, dynamic>> documents,
    String serviceFeeLabel,
  ) {
    if (documents.isEmpty) {
      return [
        pw.Text('No hay comprobantes fiscales en el rango seleccionado.'),
      ];
    }

    final dateFormat = DateFormat('dd/MM/yyyy');
    final numberFormat = NumberFormat('#,##0.00', 'en_US');
    final taxLabels = _collectTaxLabels(documents, serviceFeeLabel);

    return [
      pw.Text(
        'Detalle de comprobantes fiscales (DGII)',
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14),
      ),
      pw.SizedBox(height: 8),
      pw.Text(
        'Total: ${documents.length} comprobantes',
        style: const pw.TextStyle(fontSize: 10),
      ),
      pw.SizedBox(height: 8),
      pw.TableHelper.fromTextArray(
        cellAlignment: pw.Alignment.centerLeft,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8),
        cellStyle: const pw.TextStyle(fontSize: 7),
        headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#E5E7EB')),
        headers: [
          'NCF',
          'Tipo',
          'Cliente',
          'RNC/Cédula',
          'Subtotal',
          ...taxLabels,
          'Total',
          'Estado',
          'Fecha',
        ],
        data: documents
            .map((doc) {
              final ncfNumber = doc['ncf_number']?.toString() ?? '';
              final ncfType = doc['ncf_type']?.toString() ?? '';
              final customerName =
                  doc['customer_name']?.toString() ?? 'CONSUMIDOR FINAL';
              final customerRnc = doc['customer_rnc']?.toString() ?? '-';
              final subtotal = (doc['subtotal'] as num?)?.toDouble() ?? 0;
              final total = (doc['total'] as num?)?.toDouble() ?? 0;
              final status = doc['status']?.toString() ?? 'active';
              final issuedAt =
                  DateTime.tryParse(doc['issued_at']?.toString() ?? '') ??
                  DateTime.now();

              return [
                ncfNumber,
                ncfTypeName(ncfType),
                customerName.length > 25
                    ? '${customerName.substring(0, 25)}...'
                    : customerName,
                customerRnc.isEmpty ? '-' : customerRnc,
                numberFormat.format(subtotal),
                ...taxLabels.map((label) {
                  final amount =
                      _taxAmountForLabel(doc, label, serviceFeeLabel);
                  return amount > 0 ? numberFormat.format(amount) : '-';
                }),
                numberFormat.format(total),
                status == 'active' ? 'Activo' : 'Anulado',
                dateFormat.format(issuedAt.toLocal()),
              ];
            })
            .toList(growable: false),
      ),
    ];
  }

  static List<pw.Widget> _breakdownTable(
    String title,
    List<SalesBreakdownRow> rows, {
    bool showQuantity = false,
  }) {
    if (rows.isEmpty) return [];
    final numberFormat = NumberFormat('#,##0.00', 'en_US');
    final intFormat = NumberFormat('#,##0', 'en_US');
    return [
      pw.Text(title, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: showQuantity
            ? const ['Concepto', 'Monto', 'Cantidad', 'Conteo']
            : const ['Concepto', 'Monto', 'Conteo'],
        data: rows
            .map(
              (r) => showQuantity
                  ? [
                      r.label,
                      numberFormat.format(r.amount),
                      numberFormat.format(r.quantity),
                      intFormat.format(r.count),
                    ]
                  : [
                      r.label,
                      numberFormat.format(r.amount),
                      intFormat.format(r.count),
                    ],
            )
            .toList(growable: false),
      ),
    ];
  }
}
