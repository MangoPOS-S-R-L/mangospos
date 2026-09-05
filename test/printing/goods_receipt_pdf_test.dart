// La hoja del documento de compra (PDF carta / A4).
//
// Lo que se reclamaría si faltara: que el papel salga en el tamaño que la
// impresora tiene cargado. Antes se armaba SIEMPRE en carta y una impresora
// con A4 terminaba escalando la hoja; ahora el tamaño viaja como parámetro y
// al imprimir sale el que elige el usuario en el diálogo del sistema.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/state/goods_receipt.dart';
import 'package:mangopos/services/printing/goods_receipt_pdf.dart';
import 'package:pdf/pdf.dart';

GoodsReceipt _receipt() => GoodsReceipt(
      id: 'a1b2c3d4-0000-0000-0000-000000000000',
      number: 'RM-00007',
      date: DateTime(2026, 9, 5),
      createdAt: DateTime(2026, 9, 5, 15, 12),
      status: 'complete',
      orderId: 'order-1',
      orderNumber: 'PO-00012',
      invoiceNumber: 'F-9987',
      ncf: 'B0100000284',
      supplierName: 'Ferreteria Bellon SRL',
      supplierRnc: '130012345',
      warehouseName: 'Bodega Principal',
      receivedByName: 'Juan Perez',
      issuedByName: 'Ana Compradora',
      notes: '',
      lines: const [
        GoodsReceiptLine(
          code: '000004',
          reference: 'BLK6',
          description: 'Blocks de 6 pulgadas',
          quantity: 500,
          unit: 'unidad',
          unitCost: 48.35,
        ),
      ],
    );

/// El tamaño de la página vive en el `/MediaBox` del PDF, sin comprimir.
String _mediaBox(List<int> bytes) {
  final text = String.fromCharCodes(bytes);
  final match = RegExp(r'/MediaBox\s*\[[^\]]*\]').firstMatch(text);
  return match?.group(0) ?? '';
}

void main() {
  test('por defecto la hoja es carta', () async {
    final bytes = await GoodsReceiptPdf.build(
      receipt: _receipt(),
      businessName: 'Mi Negocio',
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    // Carta = 612 x 792 puntos.
    expect(_mediaBox(bytes), contains('612'));
  });

  test('en A4 la hoja sale en A4, no en carta escalada', () async {
    final bytes = await GoodsReceiptPdf.build(
      receipt: _receipt(),
      businessName: 'Mi Negocio',
      pageFormat: PdfPageFormat.a4,
    );
    // A4 = 595.28 x 841.89 puntos.
    final box = _mediaBox(bytes);
    expect(box, contains('595'));
    expect(box, isNot(contains('612')));
  });

  test('el nombre del archivo distingue orden de conduce', () {
    expect(GoodsReceiptPdf.fileName(_receipt()), 'conduce_RM-00007.pdf');
  });
}
