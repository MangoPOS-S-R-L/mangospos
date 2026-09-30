// Activos fijos en papel, A4. Dos documentos:
//
//   · «Inventario de activos fijos»: lo que está en pantalla, agrupado por
//     ubicación, con subtotales, total y las firmas de quien responde por el
//     área y de la administración. Es la hoja que se firma en cada conteo.
//   · «Acta de asignación»: UN activo con su responsable. La firma «Recibe»
//     es la del empleado que desde ese día responde por el equipo.
//
// Se imprime con `printWithOsDialog` (NUNCA `Printing.layoutPdf` directo: en
// Mac y iPad congela la app — ver os_print_dialog.dart).

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/currency/business_currency.dart';
import '../../../core/printing/os_print_dialog.dart';
import '../state/fixed_assets_state.dart';

/// La fuente base del PDF (Helvetica, WinAnsi) no tiene glifos más allá de
/// Latin-1 y el `pdf` LANZA al encontrarlos. Los nombres y notas los escribe
/// el usuario (rayas largas, comillas curvas, emojis…): se cambian los que
/// tienen equivalente y se descarta lo demás, para que una nota rara nunca
/// tumbe la impresión. Mismo criterio que el conduce de salidas.
@visibleForTesting
String fixedAssetsPdfSafe(String value) {
  final replaced = value
      .replaceAll('—', '-')
      .replaceAll('–', '-')
      .replaceAll('→', '->')
      .replaceAll('…', '...')
      .replaceAll('“', '"')
      .replaceAll('”', '"')
      .replaceAll('‘', "'")
      .replaceAll('’', "'")
      .replaceAll('€', 'EUR ');
  return String.fromCharCodes(replaced.runes.where((r) => r <= 0xFF));
}

String _s(String v) => fixedAssetsPdfSafe(v);

String _two(int n) => n.toString().padLeft(2, '0');

String _date(DateTime? d) {
  if (d == null) return '-';
  final l = d.isUtc ? d.toLocal() : d;
  return '${_two(l.day)}/${_two(l.month)}/${l.year}';
}

String _dateTime(DateTime d) =>
    '${_date(d)} ${_two(d.hour)}:${_two(d.minute)}';

/// Grupos del inventario: por bodega, en orden alfabético, y «Sin ubicación»
/// al final (es lo que hay que ir a buscar). Dentro, por código.
@visibleForTesting
List<MapEntry<String, List<FixedAsset>>> groupFixedAssetsByLocation(
  List<FixedAsset> assets,
) {
  final groups = <String, List<FixedAsset>>{};
  for (final a in assets) {
    groups.putIfAbsent(a.locationGroup, () => []).add(a);
  }
  const sinUbicacion = 'Sin ubicación';
  final keys = groups.keys.toList()
    ..sort((a, b) {
      if (a == sinUbicacion) return 1;
      if (b == sinUbicacion) return -1;
      return foldFixedAssetText(a).compareTo(foldFixedAssetText(b));
    });
  return [
    for (final k in keys) MapEntry(k, sortFixedAssetsByCode(groups[k]!)),
  ];
}

class FixedAssetsPdf {
  const FixedAssetsPdf._();

  static String inventoryFileName(DateTime now) =>
      'activos_fijos_${now.year}${_two(now.month)}${_two(now.day)}_'
      '${_two(now.hour)}${_two(now.minute)}.pdf';

  static String assignmentFileName(FixedAsset asset) =>
      'acta_asignacion_${asset.code}.pdf';

  // ── Inventario ───────────────────────────────────────────────────────────

  static Future<Uint8List> buildInventory({
    required List<FixedAsset> assets,
    required String businessName,
    /// Qué se está imprimiendo («Bodega: Cocina · Sin bajas»). Vacío = todo.
    String scopeLabel = '',
    String? printedBy,
    BusinessCurrency? currency,
    DateTime? printedAt,
    PdfPageFormat pageFormat = PdfPageFormat.a4,
  }) async {
    final money = currency ?? BusinessCurrency.fallbackDop;
    final now = printedAt ?? DateTime.now();
    final groups = groupFixedAssetsByLocation(assets);
    final kpis = FixedAssetsKpis.from(assets);
    final total = assets.fold<double>(0, (s, a) => s + (a.purchaseCost ?? 0));
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 30),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text(
            'Página ${context.pageNumber} de ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          _header(
            businessName: businessName,
            title: 'INVENTARIO DE ACTIVOS FIJOS',
            right: [
              'Impreso: ${_dateTime(now)}',
              if ((printedBy ?? '').trim().isNotEmpty)
                'Por: ${printedBy!.trim()}',
            ],
          ),
          if (scopeLabel.trim().isNotEmpty) ...[
            pw.Text(
              _s(scopeLabel.trim()),
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 6),
          ],
          if (assets.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 24),
              child: pw.Text(
                'No hay activos para imprimir.',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ),
          for (final g in groups) ...[
            _groupHeader(g.key, g.value, money),
            _inventoryTable(g.value, money),
            pw.SizedBox(height: 12),
          ],
          if (assets.isNotEmpty) _totals(assets.length, total, kpis, money),
          pw.SizedBox(height: 56),
          _signatures(
            left: 'Responsable del área',
            right: 'Administración',
          ),
        ],
      ),
    );
    return doc.save();
  }

  static Future<void> printInventory({
    required List<FixedAsset> assets,
    required String businessName,
    String scopeLabel = '',
    String? printedBy,
    BusinessCurrency? currency,
  }) async {
    final now = DateTime.now();
    await printWithOsDialog(
      format: PdfPageFormat.a4,
      name: inventoryFileName(now),
      onLayout: (format) => buildInventory(
        assets: assets,
        businessName: businessName,
        scopeLabel: scopeLabel,
        printedBy: printedBy,
        currency: currency,
        printedAt: now,
        pageFormat: format,
      ),
    );
  }

  // ── Acta de asignación ───────────────────────────────────────────────────

  static Future<Uint8List> buildAssignmentAct({
    required FixedAsset asset,
    required String businessName,
    /// Quien entrega (normalmente quien imprime). Vacío = línea en blanco.
    String? deliveredBy,
    BusinessCurrency? currency,
    DateTime? printedAt,
    PdfPageFormat pageFormat = PdfPageFormat.a4,
  }) async {
    final money = currency ?? BusinessCurrency.fallbackDop;
    final now = printedAt ?? DateTime.now();
    final doc = pw.Document();
    final responsable = asset.employeeName.trim();

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        margin: const pw.EdgeInsets.fromLTRB(40, 36, 40, 36),
        build: (context) => [
          _header(
            businessName: businessName,
            title: 'ACTA DE ASIGNACIÓN DE ACTIVO FIJO',
            right: [asset.code, 'Fecha: ${_date(now)}'],
          ),
          _sectionTitle('Datos del activo'),
          _fieldGrid([
            ('Código', asset.code),
            ('Nombre', asset.name),
            ('Categoría', asset.category ?? '-'),
            ('Marca', asset.brand ?? '-'),
            ('Modelo', asset.model ?? '-'),
            ('Número de serie', asset.serialNumber ?? '-'),
            ('Fecha de compra', _date(asset.purchaseDate)),
            (
              'Costo de compra',
              asset.purchaseCost == null
                  ? '-'
                  : money.formatAmount(asset.purchaseCost!),
            ),
            ('Proveedor', asset.supplierName ?? '-'),
            ('Garantía hasta', _date(asset.warrantyUntil)),
            ('Estado', asset.status.label),
          ]),
          pw.SizedBox(height: 14),
          _sectionTitle('Asignación'),
          _fieldGrid([
            ('Responsable', responsable.isEmpty ? '-' : responsable),
            ('Ubicación', asset.locationLabel),
          ]),
          pw.SizedBox(height: 16),
          pw.Text(
            _s(
              'Quien recibe declara que recibe el activo descrito en el estado '
              'indicado, y se compromete a darle un uso adecuado, reportar de '
              'inmediato cualquier daño, falla o pérdida, y devolverlo cuando '
              'la administración lo solicite o al terminar su relación con el '
              'negocio.',
            ),
            style: const pw.TextStyle(fontSize: 10, lineSpacing: 2),
            textAlign: pw.TextAlign.justify,
          ),
          pw.SizedBox(height: 16),
          _sectionTitle('Observaciones'),
          if ((asset.notes ?? '').isNotEmpty) ...[
            pw.Text(_s(asset.notes!), style: const pw.TextStyle(fontSize: 10)),
            pw.SizedBox(height: 6),
          ],
          // Renglones para escribir a mano lo que se vea al entregar
          // (rayones, piezas faltantes).
          for (var i = 0; i < 3; i++)
            pw.Container(
              height: 18,
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(width: 0.4, color: PdfColors.grey500),
                ),
              ),
            ),
          pw.SizedBox(height: 60),
          _signatures(
            left: 'Entrega',
            leftName: deliveredBy,
            right: 'Recibe',
            rightName: responsable,
          ),
        ],
      ),
    );
    return doc.save();
  }

  static Future<void> printAssignmentAct({
    required FixedAsset asset,
    required String businessName,
    String? deliveredBy,
    BusinessCurrency? currency,
  }) async {
    final now = DateTime.now();
    await printWithOsDialog(
      format: PdfPageFormat.a4,
      name: assignmentFileName(asset),
      onLayout: (format) => buildAssignmentAct(
        asset: asset,
        businessName: businessName,
        deliveredBy: deliveredBy,
        currency: currency,
        printedAt: now,
        pageFormat: format,
      ),
    );
  }

  // ── Piezas ───────────────────────────────────────────────────────────────

  static pw.Widget _header({
    required String businessName,
    required String title,
    required List<String> right,
  }) {
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
                    _s(businessName.trim().isEmpty ? 'Negocio' : businessName),
                    style: pw.TextStyle(
                      fontSize: 15,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    _s(title),
                    style: pw.TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.1,
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
                for (var i = 0; i < right.length; i++)
                  pw.Text(
                    _s(right[i]),
                    style: i == 0
                        ? pw.TextStyle(
                            fontSize: 11,
                            fontWeight: pw.FontWeight.bold,
                          )
                        : const pw.TextStyle(
                            fontSize: 9,
                            color: PdfColors.grey700,
                          ),
                  ),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Container(height: 0.8, color: PdfColors.black),
        pw.SizedBox(height: 10),
      ],
    );
  }

  static pw.Widget _groupHeader(
    String location,
    List<FixedAsset> assets,
    BusinessCurrency money,
  ) {
    final subtotal = assets.fold<double>(
      0,
      (s, a) => s + (a.purchaseCost ?? 0),
    );
    return pw.Container(
      color: PdfColors.grey200,
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: pw.Row(
        children: [
          pw.Expanded(
            child: pw.Text(
              _s(location.toUpperCase()),
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.Text(
            _s(
              '${assets.length} ${assets.length == 1 ? 'activo' : 'activos'}'
              ' · ${money.formatAmount(subtotal)}',
            ),
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );
  }

  static pw.Widget _inventoryTable(
    List<FixedAsset> assets,
    BusinessCurrency money,
  ) {
    final bold = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
    const cell = pw.TextStyle(fontSize: 8);
    const sub = pw.TextStyle(fontSize: 7, color: PdfColors.grey700);

    pw.Widget th(String text, {bool right = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: pw.Text(
            text,
            style: bold,
            textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
          ),
        );
    pw.Widget td(String text, {bool right = false, String? detail}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: pw.Column(
            crossAxisAlignment: right
                ? pw.CrossAxisAlignment.end
                : pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                _s(text),
                style: cell,
                textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
              ),
              if ((detail ?? '').isNotEmpty) pw.Text(_s(detail!), style: sub),
            ],
          ),
        );

    return pw.Table(
      columnWidths: const {
        0: pw.FlexColumnWidth(1.25),
        1: pw.FlexColumnWidth(3.6),
        2: pw.FlexColumnWidth(2.1),
        3: pw.FlexColumnWidth(2.0),
        4: pw.FlexColumnWidth(1.6),
        5: pw.FlexColumnWidth(1.7),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(width: 0.3, color: PdfColors.grey400),
        bottom: pw.BorderSide(width: 0.6),
      ),
      children: [
        pw.TableRow(
          children: [
            th('Código'),
            th('Activo'),
            th('Ubicación'),
            th('Responsable'),
            th('Estado'),
            th('Costo', right: true),
          ],
        ),
        for (final a in assets)
          pw.TableRow(
            children: [
              td(a.code),
              td(
                a.name,
                detail: [
                  if (a.brandModel.isNotEmpty) a.brandModel,
                  if ((a.serialNumber ?? '').isNotEmpty)
                    'Serie ${a.serialNumber}',
                ].join(' · '),
              ),
              td(a.locationNote ?? '-'),
              td(a.employeeName.isEmpty ? '-' : a.employeeName),
              td(a.status.label),
              td(
                a.purchaseCost == null
                    ? '-'
                    : money.formatAmount(a.purchaseCost!),
                right: true,
              ),
            ],
          ),
      ],
    );
  }

  static pw.Widget _totals(
    int count,
    double total,
    FixedAssetsKpis kpis,
    BusinessCurrency money,
  ) {
    final porEstado = [
      if (kpis.inUse > 0) 'En uso ${kpis.inUse}',
      if (kpis.needsRepair > 0) 'Necesita reparación ${kpis.needsRepair}',
      if (kpis.inRepair > 0) 'En reparación ${kpis.inRepair}',
      if (kpis.damaged > 0) 'Dañado ${kpis.damaged}',
      if (kpis.lost > 0) 'Perdido ${kpis.lost}',
      if (kpis.retired > 0) 'Dado de baja ${kpis.retired}',
    ].join(' · ');
    final sinCosto = kpis.withoutCost;
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(width: 0.8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text(
            _s(
              'Total: $count ${count == 1 ? 'activo' : 'activos'} · '
              'Valor de compra ${money.formatAmount(total)}',
            ),
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
          if (porEstado.isNotEmpty)
            pw.Text(
              _s(porEstado),
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          pw.Text(
            _s(
              'Costo histórico de compra, sin depreciación'
              '${sinCosto > 0 ? ' · $sinCosto sin costo registrado' : ''}.',
            ),
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 6),
        child: pw.Text(
          _s(text.toUpperCase()),
          style: pw.TextStyle(
            fontSize: 9,
            letterSpacing: 1,
            color: PdfColors.grey700,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      );

  /// Etiqueta/valor en dos columnas.
  static pw.Widget _fieldGrid(List<(String, String)> fields) {
    pw.Widget field((String, String) f) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 7, right: 12),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                _s(f.$1.toUpperCase()),
                style: const pw.TextStyle(
                  fontSize: 7.5,
                  color: PdfColors.grey600,
                ),
              ),
              pw.SizedBox(height: 1),
              pw.Text(
                _s(f.$2),
                style: pw.TextStyle(
                  fontSize: 10.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        );

    final rows = <pw.Widget>[];
    for (var i = 0; i < fields.length; i += 2) {
      rows.add(
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: field(fields[i])),
            pw.Expanded(
              child: i + 1 < fields.length
                  ? field(fields[i + 1])
                  : pw.SizedBox(),
            ),
          ],
        ),
      );
    }
    return pw.Column(children: rows);
  }

  /// Dos firmas al pie. El nombre sale cuando se conoce; si no, la línea
  /// queda para escribirlo a mano: el papel no puede depender de que todo
  /// esté configurado.
  static pw.Widget _signatures({
    required String left,
    required String right,
    String? leftName,
    String? rightName,
  }) {
    pw.Widget slot(String label, String? name) => pw.Expanded(
          child: pw.Column(
            children: [
              pw.Container(
                height: 0.7,
                color: PdfColors.black,
                margin: const pw.EdgeInsets.symmetric(horizontal: 16),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                _s(label),
                style: pw.TextStyle(
                  fontSize: 9.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if ((name ?? '').trim().isNotEmpty)
                pw.Text(
                  _s(name!.trim()),
                  style: const pw.TextStyle(
                    fontSize: 8.5,
                    color: PdfColors.grey700,
                  ),
                )
              else
                pw.Text(
                  'Nombre y cédula',
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: PdfColors.grey500,
                  ),
                ),
            ],
          ),
        );

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        slot(left, leftName),
        pw.SizedBox(width: 28),
        slot(right, rightName),
      ],
    );
  }
}
