// Conduce de salidas de inventario en PDF: tiene que salir en A4 (pedido del
// dueño) y aguantar una o varias salidas, incluso muchas (pasa de página).

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/services/printing/waste_exit_pdf.dart';

String _mediaBox(List<int> bytes) {
  final text = String.fromCharCodes(bytes);
  final match = RegExp(r'/MediaBox\s*\[[^\]]*\]').firstMatch(text);
  return match?.group(0) ?? '';
}

WasteExitPdfLine _line(int i) => WasteExitPdfLine(
  date: DateTime(2026, 9, 28, 14, i % 60),
  itemName: 'Heineken Botella $i',
  quantity: 2,
  unit: 'ud',
  reason: 'Rotura / dañado',
  notes: 'Se cayó la caja',
  costPerUnit: 95.5,
);

void main() {
  test('por defecto la hoja es A4', () async {
    final bytes = await WasteExitPdf.build(
      lines: [_line(1)],
      businessName: '1/2 Medio Tiempo Bar',
      warehouseName: 'Principal',
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    // A4 = 595.28 x 841.89 puntos; carta sería 612.
    final box = _mediaBox(bytes);
    expect(box, contains('595'));
    expect(box, isNot(contains('612')));
  });

  test('muchas salidas pasan de página sin romper', () async {
    final bytes = await WasteExitPdf.build(
      lines: [for (var i = 0; i < 120; i++) _line(i)],
      businessName: 'Negocio',
      warehouseName: 'Principal',
    );
    final pages = RegExp(r'/Type\s*/Page\b').allMatches(
      String.fromCharCodes(bytes),
    );
    expect(pages.length, greaterThan(1));
  });

  test('una nota con emoji o raya larga no tumba el PDF', () async {
    final bytes = await WasteExitPdf.build(
      lines: const [],
      businessName: 'Negocio — Centro 🍺',
      warehouseName: 'Barra “principal”',
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    final withNote = await WasteExitPdf.build(
      lines: [
        WasteExitPdfLine(
          date: DateTime(2026, 9, 28),
          itemName: 'Limón 🍋',
          quantity: 1,
          unit: 'lb',
          reason: 'Vencido',
          notes: 'Se dañó — nevera 2 😬',
        ),
      ],
      businessName: 'Negocio',
      warehouseName: 'Principal',
    );
    expect(String.fromCharCodes(withNote.take(4)), '%PDF');
  });

  test('el costo de una línea es cantidad por costo unitario', () {
    expect(_line(1).totalCost, 191);
  });
}
