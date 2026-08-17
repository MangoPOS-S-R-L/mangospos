import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';

PurchaseInventoryItem _item({
  String name = 'Cerveza Presidente',
  String sku = 'CERV-01',
  String barcode = '7460123456789',
}) {
  return PurchaseInventoryItem.fromMap({
    'id': 'item-1',
    'name': name,
    'sku': sku,
    'barcode': barcode,
    'unit': 'unidad',
    'cost': 1450,
    'is_active': true,
  });
}

void main() {
  group('PurchaseInventoryItem.matchesQuery', () {
    test('encuentra por nombre, como siempre', () {
      expect(_item().matchesQuery('presidente'), isTrue);
    });

    test('encuentra por SKU', () {
      expect(_item().matchesQuery('cerv-01'), isTrue);
    });

    test('encuentra escribiendo el código de barras completo a mano', () {
      expect(_item().matchesQuery('7460123456789'), isTrue);
    });

    test('no encuentra lo que no coincide', () {
      expect(_item().matchesQuery('ron brugal'), isFalse);
    });

    test('consulta vacía no coincide con nada', () {
      expect(_item().matchesQuery('   '), isFalse);
    });

    test('un insumo sin código de barras sigue buscándose por nombre', () {
      final it = _item(barcode: '');
      expect(it.matchesQuery('presidente'), isTrue);
      expect(it.matchesQuery('7460123456789'), isFalse);
    });
  });

  group('PurchaseInventoryItem.matchesCode', () {
    test('coincidencia exacta por código de barras', () {
      expect(_item().matchesCode('7460123456789'), isTrue);
    });

    test('coincidencia exacta por SKU', () {
      expect(_item().matchesCode('CERV-01'), isTrue);
    });

    test('una coincidencia PARCIAL no resuelve un escaneo', () {
      expect(_item().matchesCode('746012'), isFalse);
    });

    test('un insumo sin código no coincide con el código vacío', () {
      expect(_item(barcode: '', sku: '').matchesCode(''), isFalse);
    });
  });

  group('PurchaseOrderSummary', () {
    PurchaseOrderSummary order({String notes = '', String ncf = ''}) {
      return PurchaseOrderSummary.fromMap(
        {
          'id': 'po-1',
          'order_number': 'PO-00004',
          'invoice_number': '0004521',
          'ncf': ncf,
          'status': 'received',
          'total': 18508,
          'notes': notes,
        },
        supplierName: 'Bravo Distribución',
        warehouseName: 'Principal',
      );
    }

    test('factura y NCF quedan en campos distintos', () {
      final o = order(ncf: 'B0100000284');
      expect(o.invoiceNumber, '0004521');
      expect(o.ncf, 'B0100000284');
    });

    test('una orden sin NCF es legítima', () {
      expect(order().ncf, isEmpty);
    });

    test('la marca de CxP pendiente se detecta en las notas', () {
      expect(order(notes: 'Compra $kPendingPayableTag').payablePending, isTrue);
    });

    test('una orden normal no queda marcada', () {
      expect(order(notes: 'Compra de agosto').payablePending, isFalse);
    });
  });
}
