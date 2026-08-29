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

  group('PurchaseOrderLine — desglose de la línea', () {
    PurchaseOrderLine line({
      double quantity = 6,
      double unitCost = 1000,
      double taxRate = 18,
      double? total,
      double discount = 0,
      double received = 6,
    }) {
      return PurchaseOrderLine.fromMap({
        'id': 'poi-1',
        'inventory_item_id': 'item-1',
        'description': 'Cerveza',
        'quantity_ordered': quantity,
        'quantity_received': received,
        'unit_cost': unitCost,
        'tax_rate': taxRate,
        'total': total ?? quantity * unitCost,
        'discount': discount,
      });
    }

    test('el ITBIS sale de la tasa efectiva guardada', () {
      expect(line().taxValue, closeTo(1080, 0.001));
      expect(line().grossTotal, closeTo(7080, 0.001));
    });

    test('una línea exenta no inventa impuesto', () {
      final l = line(taxRate: 0);
      expect(l.taxValue, 0);
      expect(l.grossTotal, closeTo(l.netTotal, 0.001));
    });

    test('una tasa no redonda reconstruye el ITBIS que se pagó', () {
      // El registro guarda `tax_rate` como tasa efectiva cuando el ITBIS se
      // digitó en dinero: 6 × 1000 con ITBIS 950 → 15.8333%.
      final l = line(taxRate: 950 / 6000 * 100);
      expect(l.taxValue, closeTo(950, 0.001));
    });

    test('el precio de lista se reconstruye desde el descuento', () {
      // 6 unidades a 1000 con 600 de descuento: la lista era 1100.
      final l = line(discount: 600);
      expect(l.listUnitCost, closeTo(1100, 0.001));
    });

    test('sin descuento, el precio de lista es el costo pagado', () {
      expect(line().listUnitCost, closeTo(1000, 0.001));
    });

    test('sin la columna discount (migración sin aplicar) el descuento es 0', () {
      final l = PurchaseOrderLine.fromMap({
        'id': 'poi-2',
        'quantity_ordered': 2,
        'quantity_received': 0,
        'unit_cost': 500,
        'tax_rate': 18,
        'total': 1000,
      });
      expect(l.discount, 0);
      expect(l.listUnitCost, closeTo(500, 0.001));
    });
  });

  group('PurchaseOrderDetail — desglose de la factura', () {
    PurchaseOrderDetail detail({
      double total = 7080,
      double discount = 0,
      double lineDiscount = 0,
    }) {
      final line = PurchaseOrderLine.fromMap({
        'id': 'poi-1',
        'quantity_ordered': 6,
        'quantity_received': 6,
        'unit_cost': 1000,
        'tax_rate': 18,
        'total': 6000,
        'discount': lineDiscount,
      });
      return PurchaseOrderDetail(
        order: PurchaseOrderSummary.fromMap(
          {
            'id': 'po-1',
            'order_number': 'PO-00004',
            'status': 'received',
            'total': total,
          },
          supplierName: 'Bravo Distribución',
          warehouseName: 'Principal',
        ),
        subtotal: 6000,
        tax: 1080,
        discount: discount,
        lines: [line],
      );
    }

    test('las líneas cuadran con el total guardado', () {
      expect(detail().totalsAgree, isTrue);
    });

    test('el descuento global explica la diferencia con las líneas', () {
      expect(detail(total: 6580, discount: 500).totalsAgree, isTrue);
    });

    test('un total que no cuadra se detecta en vez de taparse', () {
      final d = detail(total: 5000);
      expect(d.totalsAgree, isFalse);
      expect(d.totalsMismatch, closeTo(2080, 0.001));
    });

    test('los descuentos de línea se suman aparte, sin restarse al total', () {
      final d = detail(lineDiscount: 600);
      expect(d.lineDiscounts, closeTo(600, 0.001));
      expect(d.totalsAgree, isTrue);
    });
  });
}
