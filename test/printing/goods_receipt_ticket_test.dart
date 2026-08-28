// Conduce de recepción de mercancía.
//
// Lo que se prueba acá es lo que un contable reclamaría si faltara: que el
// documento diga su número, el suplidor, QUÉ entró de cada producto y cuánto
// suma; que una entrega parcial se declare como parcial; y que en 58mm el
// papel no corte una sola línea.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/state/goods_receipt.dart';
import 'package:mangopos/services/printing/goods_receipt_ticket.dart';

GoodsReceipt _receipt({
  String status = 'complete',
  String number = 'RM-00007',
  List<GoodsReceiptLine>? lines,
}) {
  return GoodsReceipt(
    id: 'a1b2c3d4-0000-0000-0000-000000000000',
    number: number,
    date: DateTime(2026, 8, 28),
    createdAt: DateTime(2026, 8, 28, 15, 12),
    status: status,
    orderId: 'order-1',
    orderNumber: 'PO-00012',
    invoiceNumber: 'F-9987',
    ncf: 'B0100000284',
    supplierName: 'Ferreteria Bellon SRL',
    supplierRnc: '130012345',
    warehouseName: 'Bodega Principal',
    receivedByName: 'Juan Perez',
    notes: '',
    lines: lines ??
        const [
          GoodsReceiptLine(
            code: '000004',
            reference: 'BLK6',
            description: 'Blocks de 6 pulgadas',
            quantity: 500,
            unit: 'unidad',
            unitCost: 48.35,
          ),
          GoodsReceiptLine(
            code: '000002',
            reference: '',
            description: 'Varilla construccion 3/8x20 pies',
            quantity: 100,
            unit: 'unidad',
            unitCost: 264.95,
          ),
        ],
  );
}

void main() {
  group('GoodsReceipt', () {
    test('total e unidades salen de las líneas', () {
      final receipt = _receipt();
      // 500 * 48.35 + 100 * 264.95
      expect(receipt.total, closeTo(24175 + 26495, 0.001));
      expect(receipt.totalUnits, 600);
    });

    test('parcial y cierre corto se declaran parciales', () {
      expect(_receipt(status: 'partial').isPartial, isTrue);
      expect(_receipt(status: 'short_closed').isPartial, isTrue);
      expect(_receipt(status: 'complete').isPartial, isFalse);
    });
  });

  group('GoodsReceiptLine.fromMap', () {
    test('el snapshot de la línea gana sobre el maestro del insumo', () {
      // El insumo se renombró después de recibir: el conduce reimpreso tiene
      // que salir con el nombre que tenía el día que se firmó.
      final line = GoodsReceiptLine.fromMap({
        'item_name': 'Cemento gris Cibao',
        'item_sku': '000006',
        'item_unit': 'funda',
        'description': 'CEM-GRIS',
        'quantity_received': 1000,
        'actual_unit_cost': 493.63,
        'inventory_items': {
          'name': 'Cemento Titan (renombrado)',
          'sku': 'NUEVO-SKU',
          'unit': 'saco',
        },
      });

      expect(line.description, 'Cemento gris Cibao');
      expect(line.code, '000006');
      expect(line.unit, 'funda');
      expect(line.reference, 'CEM-GRIS');
      expect(line.amount, closeTo(493630, 0.01));
    });

    test('sin snapshot cae al maestro vinculado', () {
      // Recepciones anteriores a la migración del conduce: el maestro es lo
      // único que queda.
      final line = GoodsReceiptLine.fromMap({
        'quantity_received': 3,
        'actual_unit_cost': 100,
        'inventory_items': {'name': 'Aceite', 'sku': 'AC-1', 'unit': 'litro'},
      });

      expect(line.description, 'Aceite');
      expect(line.code, 'AC-1');
      expect(line.unit, 'litro');
    });

    test('sin snapshot ni maestro no imprime una línea en blanco', () {
      final line = GoodsReceiptLine.fromMap({
        'quantity_received': 1,
        'actual_unit_cost': 0,
      });
      expect(line.description, 'Artículo');
      expect(line.unit, 'unidad');
    });
  });

  group('GoodsReceiptTicket', () {
    test('imprime número, suplidor, productos y total', () {
      final ticket = GoodsReceiptTicket.build(
        receipt: _receipt(),
        businessName: 'Contabilidad por Igualas SRL',
        businessRnc: '103001238',
      );
      final text = ticket.rawText ?? '';

      expect(ticket.type, 'goods_receipt');
      expect(text, contains('RM-00007'));
      expect(text, contains('FERRETERIA BELLON SRL'));
      expect(text, contains('130012345'));
      expect(text, contains('Blocks de 6 pulgadas'));
      expect(text, contains('500 unidad'));
      expect(text, contains('PO-00012'));
      expect(text, contains('B0100000284'));
      // Las dos firmas: sin ellas el papel no prueba la entrega.
      expect(text, contains('Entregado por'));
      expect(text, contains('Recibido por'));
    });

    test('una entrega parcial lo dice en la cara del documento', () {
      final ticket = GoodsReceiptTicket.build(
        receipt: _receipt(status: 'partial'),
        businessName: 'Mi Negocio',
      );
      expect(ticket.rawText, contains('ENTREGA PARCIAL'));
    });

    test('la reimpresión se identifica como tal', () {
      final ticket = GoodsReceiptTicket.build(
        receipt: _receipt(),
        businessName: 'Mi Negocio',
        isReprint: true,
      );
      expect(ticket.rawText, contains('REIMPRESION'));
    });

    test('en 58mm ninguna línea excede las 32 columnas', () {
      final ticket = GoodsReceiptTicket.build(
        receipt: _receipt(
          lines: const [
            GoodsReceiptLine(
              code: '000002',
              reference: '',
              description:
                  'Varilla de construccion de 3/8 por 20 pies importada',
              quantity: 100,
              unit: 'unidad',
              unitCost: 264.95,
            ),
          ],
        ),
        businessName: 'Un Nombre De Negocio Bastante Largo SRL',
        businessAddress: 'Calle Duarte esquina Mella, La Vega, Rep. Dom.',
        paperWidth: 58,
      );

      for (final line in (ticket.rawText ?? '').split('\n')) {
        expect(
          line.length,
          lessThanOrEqualTo(32),
          reason: 'línea que se sale del papel de 58mm: "$line"',
        );
      }
    });

    test('sin número imprime "s/n" en vez de un hueco', () {
      final ticket = GoodsReceiptTicket.build(
        receipt: _receipt(number: ''),
        businessName: 'Mi Negocio',
      );
      expect(ticket.rawText, contains('s/n'));
    });
  });
}
