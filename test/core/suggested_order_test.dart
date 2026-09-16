import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/inventory/suggested_order.dart';

const _refresco = ProjectionLine(
  itemId: 'refresco',
  itemName: 'Refresco',
  unit: 'unidad',
  suggestedBase: 27,
  supplierId: 'sb',
  supplierName: 'SB',
  leadTimeDays: 5,
  leadTimeIsDefault: false,
  purchaseUnit: 'Caja',
  packSize: 24,
  unitCostBase: 22,
);

const _queso = ProjectionLine(
  itemId: 'queso',
  itemName: 'Queso',
  unit: 'lb',
  suggestedBase: 4.9,
  unitCostBase: 200,
);

const _pan = ProjectionLine(
  itemId: 'pan',
  itemName: 'Pan',
  unit: 'unidad',
  suggestedBase: 0,
  supplierId: 'sb',
  supplierName: 'SB',
  unitCostBase: 5,
);

void main() {
  group('ProjectionLine.fromMap', () {
    test('lee números que llegan como texto y marca origen del mínimo', () {
      final line = ProjectionLine.fromMap({
        'item_id': 'x',
        'item_name': 'Harina',
        'unit': 'lb',
        'stock': '12.5',
        'suggested_base': '3',
        'window_days': 10,
        'min_stock_source': 'almacen',
        'lead_time_days': 4,
        'lead_time_is_default': false,
        'pack_size': '0',
        'unit_cost_base': '15.5',
      });
      expect(line.stock, 12.5);
      expect(line.suggestedBase, 3);
      expect(line.windowDays, 10);
      expect(line.minStockFromWarehouse, isTrue);
      expect(line.leadTimeDays, 4);
      expect(line.leadTimeIsDefault, isFalse);
      expect(line.packSize, 1, reason: 'un contenido 0 no es empaque');
      expect(line.unitCostBase, 15.5);
      expect(line.baseIsCountable, isFalse);
    });
  });

  group('resolveOrderLine', () {
    test('sin editar: cajas completas hacia arriba, con lo que sobra', () {
      final d = resolveOrderLine(_refresco, null);
      expect(d.packs, 2);
      expect(d.baseQuantity, 48);
      expect(d.surplusBase, 21);
      expect(d.costPerOrderUnit, 528);
      expect(d.subtotal, 1056);
      expect(d.selected, isTrue);
      expect(_refresco.orderUnit, 'Caja');
    });

    test('libras sin empaque no se redondean', () {
      final d = resolveOrderLine(_queso, null);
      expect(d.packs, closeTo(4.9, 1e-9));
      expect(d.baseQuantity, closeTo(4.9, 1e-9));
      expect(d.surplusBase, 0);
    });

    test('editar cajas y costo por caja pasa a unidad base', () {
      final d = resolveOrderLine(
        _refresco,
        const LineEdit(packs: 3, costPerOrderUnit: 480),
      );
      expect(d.baseQuantity, 72);
      expect(d.unitCostBase, 20);
      expect(d.subtotal, 1440);
      expect(d.surplusBase, 45);
    });

    test('lo que no hace falta llega sin marcar y no se pide', () {
      final d = resolveOrderLine(_pan, null);
      expect(d.selected, isFalse);
      expect(d.willOrder, isFalse);
    });

    test('cero cajas no se pide aunque esté marcado', () {
      final d = resolveOrderLine(
        _refresco,
        const LineEdit(packs: 0, selected: true),
      );
      expect(d.willOrder, isFalse);
    });

    test('mínimo del suplidor sube la cantidad y lo dice', () {
      const line = ProjectionLine(
        itemId: 'a',
        itemName: 'Aceite',
        suggestedBase: 1,
        purchaseUnit: 'Galón',
        packSize: 4,
        minOrderQty: 3,
      );
      final d = resolveOrderLine(line, null);
      expect(d.packs, 3);
      expect(d.raisedToMinimum, isTrue);
      final edited = resolveOrderLine(line, const LineEdit(packs: 1));
      expect(edited.raisedToMinimum, isFalse);
    });
  });

  group('buildSupplierOrders', () {
    const suppliers = {
      'sb': SuggestedOrderSupplier(
        id: 'sb',
        name: 'Distribuidora SB',
        minOrderAmount: 2000,
        whatsapp: '809-555-0101',
      ),
      'sc': SuggestedOrderSupplier(id: 'sc', name: 'Colmado SC', leadTimeDays: 1),
    };

    test('agrupa por suplidor; sin suplidor al final y no se puede crear', () {
      final orders = buildSupplierOrders(
        lines: const [_queso, _refresco, _pan],
        suppliers: suppliers,
      );
      expect(orders.map((o) => o.supplierName), ['Distribuidora SB', 'Sin suplidor']);
      expect(orders.first.lines.length, 2);
      expect(orders.first.orderLineCount, 1, reason: 'el Pan no hace falta');
      expect(orders.first.canCreate, isTrue);
      expect(orders.last.canCreate, isFalse);
    });

    test('pedido mínimo: avisa cuánto falta, solo con líneas a pedir', () {
      final orders = buildSupplierOrders(
        lines: const [_refresco],
        suppliers: suppliers,
      );
      expect(orders.single.subtotal, 1056);
      expect(orders.single.missingForMinimum, 944);
      final nothing = buildSupplierOrders(
        lines: const [_refresco],
        edits: const {'refresco': LineEdit(selected: false)},
        suppliers: suppliers,
      );
      expect(nothing.single.missingForMinimum, 0);
    });

    test('cambiar de suplidor mueve la línea y toma su tiempo de entrega', () {
      final orders = buildSupplierOrders(
        lines: const [_refresco, _queso],
        edits: const {'queso': LineEdit(supplierId: 'sc')},
        suppliers: suppliers,
      );
      final sc = orders.firstWhere((o) => o.supplierId == 'sc');
      expect(sc.supplierName, 'Colmado SC');
      expect(sc.leadTimeDays, 1);
      expect(sc.leadTimeIsDefault, isFalse);
      expect(orders.any((o) => o.supplierId == null), isFalse);
    });

    test('tiempo de entrega: el del suplidor, el de la proyección o el de por defecto', () {
      final withLine = buildSupplierOrders(lines: const [_refresco]);
      expect(withLine.single.leadTimeDays, 5);
      expect(withLine.single.leadTimeIsDefault, isFalse);
      expect(withLine.single.supplierName, 'SB');

      final byDefault = buildSupplierOrders(
        lines: const [_queso],
        edits: const {'queso': LineEdit(supplierId: 'sx')},
        defaultLeadTimeDays: 3,
      );
      expect(byDefault.single.leadTimeDays, 3);
      expect(byDefault.single.leadTimeIsDefault, isTrue);
      expect(
        byDefault.single.expectedDate(DateTime(2026, 9, 15, 18, 30)),
        DateTime(2026, 9, 18),
      );
    });
  });

  group('mensaje y WhatsApp', () {
    test('lista solo lo que se pide, en cajas y en base, con la fecha', () {
      final order = buildSupplierOrders(
        lines: const [_refresco, _pan],
      ).single;
      final text = supplierOrderMessage(
        order: order,
        businessName: 'La Penda',
        orderNumber: 'PO-00012',
        expectedDate: DateTime(2026, 9, 20),
      );
      expect(text, contains('Pedido de La Penda (PO-00012):'));
      expect(text, contains('• 2 Caja — Refresco (48 unidad)'));
      expect(text, isNot(contains('Pan')));
      expect(text, contains('Para el 20/09/2026.'));
      expect(text, isNot(contains('528')), reason: 'al suplidor no se le mandan costos');
    });

    test('número de 10 dígitos lleva el 1; corto no da enlace', () {
      final uri = whatsappOrderLink('(809) 555-0101', 'Hola, SB. 2 cajas');
      expect(uri.toString(), 'https://wa.me/18095550101?text=Hola%2C%20SB.%202%20cajas');
      expect(whatsappOrderLink('555', 'x'), isNull);
      expect(whatsappOrderLink(null, 'x'), isNull);
    });
  });
}
