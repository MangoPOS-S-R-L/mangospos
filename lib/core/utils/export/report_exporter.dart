// Sprint 5 Inventario (Fase C) — Helper de exportación de reportes.
//
// Centraliza la generación y descarga de archivos en 3 formatos:
//   - CSV: descarga directa (file_picker.saveFile) con fallback a clipboard
//   - Excel (.xlsx): paquete `excel`, descarga vía file_picker
//   - PDF: paquete `pdf` + `printing.sharePdf` para diálogo nativo cross-platform
//
// Diseñado para tablas tabulares simples. Para layouts más complejos
// (varias tablas, totales agregados) usar el patrón directamente con `pw.`.

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
    final buffer = StringBuffer();
    buffer.writeln(headers.map(_csvCell).join(','));
    for (final r in rows) {
      buffer.writeln(r.map(_csvCell).join(','));
    }
    final bytes = Uint8List.fromList(buffer.toString().codeUnits);

    final saved = await _saveBytes(
      filename: _ensureExt(filename, '.csv'),
      bytes: bytes,
      mimeType: 'text/csv',
    );
    if (saved) return true;
    // Fallback: portapapeles.
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    return false;
  }

  /// Construye un archivo Excel (.xlsx) con una hoja y descarga.
  /// Cae a clipboard si la descarga falla.
  static Future<bool> exportExcel({
    required String filename,
    required String sheetName,
    required ExportRow headers,
    required List<ExportRow> rows,
  }) async {
    final excel = xlsx.Excel.createExcel();
    // Eliminar la hoja "Sheet1" auto-creada y crear la nuestra.
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != sheetName) {
      excel.rename(defaultSheet, sheetName);
    }
    final sheet = excel[sheetName];

    // Headers con estilo bold.
    final headerStyle = xlsx.CellStyle(
      bold: true,
      backgroundColorHex: xlsx.ExcelColor.fromHexString('#F1F5F9'),
      horizontalAlign: xlsx.HorizontalAlign.Left,
    );
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(
        xlsx.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0),
      );
      cell.value = xlsx.TextCellValue(headers[c]);
      cell.cellStyle = headerStyle;
    }

    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        final cell = sheet.cell(
          xlsx.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1),
        );
        cell.value = xlsx.TextCellValue(row[c]);
      }
    }

    final encoded = excel.encode();
    if (encoded == null) return false;
    final bytes = Uint8List.fromList(encoded);

    final saved = await _saveBytes(
      filename: _ensureExt(filename, '.xlsx'),
      bytes: bytes,
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    if (saved) return true;
    // Fallback: si la descarga falla, copia CSV al portapapeles como respaldo.
    final csvBuffer = StringBuffer();
    csvBuffer.writeln(headers.map(_csvCell).join(','));
    for (final row in rows) {
      csvBuffer.writeln(row.map(_csvCell).join(','));
    }
    await Clipboard.setData(ClipboardData(text: csvBuffer.toString()));
    return false;
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

  static String _csvCell(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
