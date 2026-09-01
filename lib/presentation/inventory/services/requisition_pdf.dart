// F2 — El documento de la requisición, en A4.
//
// No es un ticket térmico: es el papel que se firma y se archiva. Por eso
// A4, por eso la tabla completa con el faltante a la vista, y por eso las
// dos firmas al pie — la del encargado del área que pidió y la del encargado
// del almacén que despachó.

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../state/requisitions_state.dart';

/// La fuente base del PDF (Helvetica WinAnsi) no tiene glifos para em-dash,
/// flechas ni elipsis: saldrían como cuadros. Mismo criterio que
/// `ReportExporter`.
String _seguro(String v) => v
    .replaceAll('—', '-')
    .replaceAll('–', '-')
    .replaceAll('→', '->')
    .replaceAll('…', '...');

String _fmtCantidad(double? v) {
  if (v == null) return '-';
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2);
}

String _fmtFecha(DateTime? d) {
  if (d == null) return '-';
  final l = d.toLocal();
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(l.day)}/${dos(l.month)}/${l.year} ${dos(l.hour)}:${dos(l.minute)}';
}

/// Genera el documento y abre el diálogo nativo para imprimir o compartir.
Future<void> exportRequisitionPdf({
  required Requisition req,
  required List<RequisitionLine> lines,
  required String businessName,
  String? areaKeeperName,
  String? warehouseKeeperName,
}) async {
  final doc = pw.Document();

  // El faltante sólo tiene sentido después del despacho: antes, todas las
  // líneas figurarían como faltantes de su totalidad.
  final yaDespachada = req.status != RequisitionStatus.pending;

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 32, 36, 36),
      header: (context) => context.pageNumber == 1
          ? _encabezado(req, businessName)
          : pw.SizedBox(),
      footer: (context) => pw.Container(
        alignment: pw.Alignment.centerRight,
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Text(
          'Pagina ${context.pageNumber} de ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
      ),
      build: (context) => [
        _datos(req),
        pw.SizedBox(height: 14),
        _tabla(lines, yaDespachada),
        if ((req.notes ?? '').trim().isNotEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Text(
            'Notas',
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            _seguro(req.notes!.trim()),
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
        pw.SizedBox(height: 36),
        _firmas(
          areaKeeperName: areaKeeperName,
          warehouseKeeperName: warehouseKeeperName,
          areaWarehouse: req.toWarehouseName,
          sourceWarehouse: req.fromWarehouseName,
        ),
      ],
    ),
  );

  await Printing.sharePdf(
    bytes: await doc.save(),
    filename: '${req.code}.pdf',
  );
}

pw.Widget _encabezado(Requisition req, String businessName) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  _seguro(businessName),
                  style: pw.TextStyle(
                    fontSize: 15,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'REQUISICION DE MERCANCIA',
                  style: pw.TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: PdfColors.grey700,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                _seguro(req.code),
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 2),
              pw.Text(
                _seguro(req.status.label),
                style: const pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.grey700,
                ),
              ),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Divider(color: PdfColors.grey400, height: 1),
      pw.SizedBox(height: 12),
    ],
  );
}

pw.Widget _datos(Requisition req) {
  pw.Widget celda(String etiqueta, String valor) => pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              etiqueta.toUpperCase(),
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              _seguro(valor),
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      );

  return pw.Column(
    children: [
      pw.Row(
        children: [
          celda('Solicita (area)', req.toWarehouseName),
          celda('Despacha (almacen)', req.fromWarehouseName),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Row(
        children: [
          celda('Fecha del pedido', _fmtFecha(req.requestedAt)),
          celda('Fecha del despacho', _fmtFecha(req.dispatchedAt)),
          celda('Fecha de recepcion', _fmtFecha(req.receivedAt)),
        ],
      ),
    ],
  );
}

pw.Widget _tabla(List<RequisitionLine> lines, bool yaDespachada) {
  final headers = <String>[
    'Insumo',
    'Unidad',
    'Pedido',
    if (yaDespachada) 'Despachado',
    if (yaDespachada) 'Faltante',
    'Recibido',
  ];

  final rows = <List<String>>[
    for (final l in lines)
      <String>[
        _seguro(l.itemName),
        _seguro(l.unit),
        _fmtCantidad(l.requestedQty),
        if (yaDespachada) _fmtCantidad(l.dispatchedQty),
        // Sólo se imprime el faltante cuando lo hay: una columna llena de
        // ceros esconde justamente el renglón que hay que reclamar.
        if (yaDespachada) (l.tieneFaltante ? _fmtCantidad(l.faltante) : ''),
        _fmtCantidad(l.receivedQty),
      ],
  ];

  final numericas = <int>{2, if (yaDespachada) 3, if (yaDespachada) 4,
      yaDespachada ? 5 : 3};

  return pw.TableHelper.fromTextArray(
    headers: headers,
    data: rows,
    headerStyle: pw.TextStyle(
      fontWeight: pw.FontWeight.bold,
      fontSize: 10,
      color: PdfColors.grey800,
    ),
    headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
    cellStyle: const pw.TextStyle(fontSize: 9),
    cellAlignments: {
      for (var i = 0; i < headers.length; i++)
        i: numericas.contains(i)
            ? pw.Alignment.centerRight
            : pw.Alignment.centerLeft,
    },
    cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
    columnWidths: {
      0: const pw.FlexColumnWidth(4),
      1: const pw.FlexColumnWidth(1.2),
      for (var i = 2; i < headers.length; i++)
        i: const pw.FlexColumnWidth(1.4),
    },
  );
}

/// Las dos firmas. Van juntas y al pie para que el papel valga como
/// constancia: quién pidió y recibió, y quién entregó.
pw.Widget _firmas({
  required String? areaKeeperName,
  required String? warehouseKeeperName,
  required String areaWarehouse,
  required String sourceWarehouse,
}) {
  pw.Widget firma(String cargo, String? nombre, String lugar) => pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Container(
              height: 1,
              color: PdfColors.grey700,
              margin: const pw.EdgeInsets.symmetric(horizontal: 12),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              _seguro(cargo),
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 2),
            // El nombre se imprime cuando la bodega tiene responsable
            // asignado. Si no, la linea queda en blanco para escribirlo a
            // mano: el documento no puede depender de que este configurado.
            pw.Text(
              _seguro(nombre?.trim().isNotEmpty == true ? nombre!.trim() : lugar),
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          ],
        ),
      );

  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      firma('Encargado de area', areaKeeperName, areaWarehouse),
      pw.SizedBox(width: 24),
      firma(
        'Encargado de almacen principal',
        warehouseKeeperName,
        sourceWarehouse,
      ),
    ],
  );
}
