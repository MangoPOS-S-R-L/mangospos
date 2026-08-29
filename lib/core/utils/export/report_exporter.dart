// Sprint 5 Inventario (Fase C) — Helper de exportación de reportes.
//
// Centraliza la generación y descarga de archivos en 3 formatos:
//   - CSV: descarga directa (file_picker.saveFile) con fallback a clipboard
//   - Excel (.xlsx): paquete `excel`, descarga vía file_picker
//   - PDF: paquete `pdf` + `printing.sharePdf` para diálogo nativo cross-platform
//
// Diseñado para tablas tabulares simples. Para layouts más complejos
// (varias tablas, totales agregados) usar el patrón directamente con `pw.`.

import 'dart:convert';

import 'package:excel/excel.dart' as xlsx;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Una fila lista para exportar: lista de strings (una columna por elemento).
typedef ExportRow = List<String>;

class ReportExporter {
  /// Construye un CSV (RFC 4180) y lo descarga como archivo.
  /// Si el download falla (mobile sin soporte), cae a copiar al portapapeles.
  /// Devuelve `true` si se descargó, `false` si se copió al portapapeles.
  static Future<bool> exportCsv({
    required String filename,
    required ExportRow headers,
    required List<ExportRow> rows,
  }) async {
    final csv = _buildCsv(headers, rows);

    // UTF-8 con BOM. Antes iba `String.codeUnits`, que trunca cada unidad a
    // un byte: "Piña" llegaba al archivo como Latin-1 y cualquier lector
    // UTF-8 la mostraba rota. El BOM es además lo que hace que Excel en
    // Windows abra el CSV en UTF-8 y no en la página de códigos del sistema.
    final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);

    final saved = await _saveBytes(
      filename: _ensureExt(filename, '.csv'),
      bytes: bytes,
      mimeType: 'text/csv',
    );
    if (saved) return true;
    // Fallback: portapapeles (sin BOM — ahí es texto, no archivo).
    await Clipboard.setData(ClipboardData(text: csv));
    return false;
  }

  /// Construye un archivo Excel (.xlsx) con una hoja y descarga.
  /// Cae a clipboard si la descarga falla.
  ///
  /// [numericColumns] (cantidades) y [moneyColumns] (importes, 2 decimales)
  /// son los índices de columna que deben llegar a Excel como NÚMERO y no
  /// como texto: sin eso quien recibe el archivo no puede sumar, ordenar ni
  /// filtrar por costo. Todo lo demás se escribe como texto A PROPÓSITO —
  /// un código de barras o un SKU numérico pierde los ceros a la izquierda y
  /// sale en notación científica en cuanto Excel lo toma por número.
  static Future<bool> exportExcel({
    required String filename,
    required String sheetName,
    required ExportRow headers,
    required List<ExportRow> rows,
    List<int> numericColumns = const [],
    List<int> moneyColumns = const [],
  }) async {
    final bytes = buildXlsxBytes(
      sheetName: sheetName,
      headers: headers,
      rows: rows,
      numericColumns: numericColumns,
      moneyColumns: moneyColumns,
    );
    if (bytes == null) return false;

    final saved = await _saveBytes(
      filename: _ensureExt(filename, '.xlsx'),
      bytes: bytes,
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    if (saved) return true;
    // Fallback: si la descarga falla, copia CSV al portapapeles como respaldo.
    await Clipboard.setData(ClipboardData(text: _buildCsv(headers, rows)));
    return false;
  }

  /// Arma el .xlsx en memoria. Separado de [exportExcel] porque esta parte
  /// —la que decide qué celda es número y cuál texto— es la que hay que poder
  /// probar sin `file_picker` ni portapapeles de por medio.
  /// Devuelve `null` si el paquete no logra codificar el libro.
  static Uint8List? buildXlsxBytes({
    required String sheetName,
    required ExportRow headers,
    required List<ExportRow> rows,
    List<int> numericColumns = const [],
    List<int> moneyColumns = const [],
  }) {
    final excel = xlsx.Excel.createExcel();
    // Eliminar la hoja "Sheet1" auto-creada y crear la nuestra.
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != sheetName) {
      excel.rename(defaultSheet, sheetName);
    }
    final sheet = excel[sheetName];

    final moneySet = moneyColumns.toSet();
    final numberSet = numericColumns.toSet()..removeAll(moneySet);

    // Headers con estilo bold.
    xlsx.CellStyle headerStyle(bool rightAligned) => xlsx.CellStyle(
      bold: true,
      backgroundColorHex: xlsx.ExcelColor.fromHexString('#F1F5F9'),
      horizontalAlign: rightAligned
          ? xlsx.HorizontalAlign.Right
          : xlsx.HorizontalAlign.Left,
    );

    for (var c = 0; c < headers.length; c++) {
      sheet.updateCell(
        xlsx.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0),
        xlsx.TextCellValue(headers[c]),
        cellStyle: headerStyle(moneySet.contains(c) || numberSet.contains(c)),
      );
    }

    final moneyStyle = xlsx.CellStyle(
      horizontalAlign: xlsx.HorizontalAlign.Right,
      numberFormat: const xlsx.CustomNumericNumFormat(formatCode: '#,##0.00'),
    );
    final numberStyle = xlsx.CellStyle(
      horizontalAlign: xlsx.HorizontalAlign.Right,
      numberFormat: const xlsx.CustomNumericNumFormat(formatCode: '#,##0.####'),
    );

    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        final index = xlsx.CellIndex.indexByColumnRow(
          columnIndex: c,
          rowIndex: r + 1,
        );
        final isMoney = moneySet.contains(c);
        final parsed = (isMoney || numberSet.contains(c))
            ? _parseNumber(row[c])
            : null;
        if (parsed == null) {
          sheet.updateCell(index, xlsx.TextCellValue(row[c]));
          continue;
        }
        // Entero exacto en columna de cantidad → sin decimales colgando.
        final value = (!isMoney && parsed == parsed.roundToDouble())
            ? xlsx.IntCellValue(parsed.toInt())
            : xlsx.DoubleCellValue(parsed);
        sheet.updateCell(
          index,
          value,
          cellStyle: isMoney ? moneyStyle : numberStyle,
        );
      }
    }

    // Ancho por contenido. El paquete no auto-ajusta al abrir, así que sin
    // esto un maestro de artículos sale con todas las columnas a 8 caracteres
    // y hay que arrastrar 20 bordes antes de poder leerlo.
    for (var c = 0; c < headers.length; c++) {
      var width = headers[c].length.toDouble();
      for (final row in rows) {
        if (c >= row.length) continue;
        final len = row[c].length.toDouble();
        if (len > width) width = len;
      }
      sheet.setColumnWidth(c, (width + 2.5).clamp(9.0, 46.0));
    }

    final encoded = excel.encode();
    if (encoded == null) return null;
    return Uint8List.fromList(encoded);
  }

  /// Construye un PDF tabular y abre el diálogo nativo de impresión/compartir.
  /// El parámetro [subtitle] aparece debajo del título (ej. "Período: 30 días").
  ///
  /// [columnFlex] (opcional) fija el ancho relativo de cada columna
  /// (`FlexColumnWidth`). Sin él, la tabla auto-ajusta por contenido, lo que
  /// con muchas columnas parte headers y números letra por letra.
  static Future<void> exportPdf({
    required String filename,
    required String title,
    String? subtitle,
    required ExportRow headers,
    required List<ExportRow> rows,
    bool landscape = false,
    List<int>? columnNumericIndices,
    List<double>? columnFlex,
    List<String>? summaryLines,
  }) async {
    final doc = pw.Document();
    final pageFormat = landscape
        ? PdfPageFormat.a4.landscape
        : PdfPageFormat.a4;
    final numericSet = (columnNumericIndices ?? const []).toSet();
    // La fuente base (Helvetica WinAnsi) no tiene glifos para em-dash,
    // flechas, etc. — saldrían como ⊠ en el documento.
    title = _pdfSafe(title);
    subtitle = subtitle == null ? null : _pdfSafe(subtitle);
    headers = headers.map(_pdfSafe).toList(growable: false);
    rows = rows
        .map((r) => r.map(_pdfSafe).toList(growable: false))
        .toList(growable: false);

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        maxPages: 200,
        margin: const pw.EdgeInsets.all(24),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            if (subtitle != null) ...[
              pw.SizedBox(height: 2),
              pw.Text(
                subtitle,
                style: const pw.TextStyle(
                  fontSize: 11,
                  color: PdfColors.grey700,
                ),
              ),
            ],
            pw.SizedBox(height: 12),
          ],
        ),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Página ${context.pageNumber} de ${context.pagesCount}',
            style: const pw.TextStyle(
              fontSize: 9,
              color: PdfColors.grey600,
            ),
          ),
        ),
        build: (context) => [
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: rows,
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 10,
              color: PdfColors.grey800,
            ),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColors.grey200,
            ),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignments: {
              for (var i = 0; i < headers.length; i++)
                i: numericSet.contains(i)
                    ? pw.Alignment.centerRight
                    : pw.Alignment.centerLeft,
            },
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 3,
            ),
            border: pw.TableBorder.all(
              color: PdfColors.grey300,
              width: 0.5,
            ),
            columnWidths: columnFlex == null
                ? null
                : {
                    for (var i = 0; i < columnFlex.length; i++)
                      i: pw.FlexColumnWidth(columnFlex[i]),
                  },
          ),
          if (summaryLines != null && summaryLines.isNotEmpty) ...[
            pw.SizedBox(height: 10),
            pw.Container(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  for (final line in summaryLines)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 2),
                      child: pw.Text(
                        _pdfSafe(line),
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: _ensureExt(filename, '.pdf'),
    );
  }

  /// Guarda los `bytes` con el `filename` usando el dialog nativo de
  /// `file_picker`. En web triggerea download. En desktop abre Save As.
  /// Retorna `true` si se completó, `false` si falló o el user canceló.
  static Future<bool> _saveBytes({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    try {
      final result = await FilePicker.saveFile(
        fileName: filename,
        bytes: bytes,
      );
      // En web `saveFile` retorna null cuando el download se gatilló (sin
      // dialog). En desktop retorna la ruta elegida. Tratamos ambos como éxito
      // si no hubo excepción.
      return result != null || _isWebPlatform();
    } catch (_) {
      return false;
    }
  }

  /// Detecta si estamos en web sin importar `dart:html`. Usa una heurística
  /// segura: `Uri.base.scheme` es 'http' o 'https' en web.
  static bool _isWebPlatform() {
    return identical(0, 0.0); // true solo en JS (web). false en VM.
  }

  static String _ensureExt(String filename, String ext) {
    if (filename.toLowerCase().endsWith(ext)) return filename;
    return '$filename$ext';
  }

  /// Reemplaza caracteres sin glifo en las fuentes base-14 del PDF
  /// (Helvetica/WinAnsi) por equivalentes ASCII. Solo para el contenido
  /// PDF — CSV/Excel son UTF-8 y no lo necesitan.
  static String _pdfSafe(String value) => value
      .replaceAll('—', '-') // — em-dash
      .replaceAll('–', '-') // – en-dash
      .replaceAll('→', '->') // → flecha
      .replaceAll('…', '...'); // … elipsis

  static String _buildCsv(ExportRow headers, List<ExportRow> rows) {
    final buffer = StringBuffer();
    buffer.writeln(headers.map(_csvCell).join(','));
    for (final row in rows) {
      buffer.writeln(row.map(_csvCell).join(','));
    }
    return buffer.toString();
  }

  /// Convierte una celda ya formateada ("RD$ 1,234.50") al número que va en
  /// la hoja. Devuelve `null` si no hay un número adentro — la celda se
  /// escribe como texto y el archivo no se rompe.
  static double? _parseNumber(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    final negative = value.startsWith('-') || value.startsWith('(');
    // Fuera símbolo de moneda, espacios (incluido el fino de NumberFormat) y
    // separador de miles. es_DO y en_US usan coma para miles y punto para
    // decimales, que es como salen todas las celdas de la app.
    value = value.replaceAll(RegExp(r'[^0-9.]'), '');
    if (value.isEmpty) return null;
    final parsed = double.tryParse(value);
    if (parsed == null) return null;
    return negative ? -parsed : parsed;
  }

  static String _csvCell(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
