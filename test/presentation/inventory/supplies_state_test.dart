// Gastables y menaje: cómo se lee el panel de `fn_inventory_supplies_overview`
// (20260930_0051) y qué se considera «por reponer».

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/supplies_state.dart';

Map<String, dynamic> _row(
  String id,
  String name,
  String cls, {
  double stock = 0,
  double min = 0,
  double cost = 10,
  double used = 0,
  double sold = 0,
  double broken = 0,
  double lost = 0,
  double countAdjust = 0,
}) => {
  'item_id': id,
  'item_name': name,
  'item_unit': 'u',
  'classification': cls,
  'unit_cost': cost,
  'stock': stock,
  'min_stock': min,
  'min_source': 'insumo',
  'used_qty': used,
  'used_value': used * cost,
  'sold_qty': sold,
  'sold_value': sold * cost,
  'broken_qty': broken,
  'broken_value': broken * cost,
  'lost_qty': lost,
  'lost_value': lost * cost,
  'count_adjust_qty': countAdjust,
  'count_adjust_value': countAdjust * cost,
  'by_warehouse': [
    {
      'warehouse_id': 'w1',
      'warehouse_name': 'Principal',
      'qty': stock,
      'min_stock': null,
    },
  ],
};

void main() {
  test('lee el panel: pestañas, áreas y bodegas', () {
    final report = SuppliesReport.fromMap({
      'days': 30,
      'items': [
        _row('p', 'Papel', 'supply', stock: 50, used: 30),
        _row('c', 'Copa', 'smallware', stock: 100, min: 120, broken: 6),
      ],
      'by_destination': [
        {'destination': 'Baños', 'value': 480, 'count': 3},
        {'destination': null, 'value': 60, 'count': 1},
      ],
    });
    expect(report.supplies.map((i) => i.name), ['Papel']);
    expect(report.smallware.map((i) => i.name), ['Copa']);
    expect(report.byDestination.map((d) => d.label), ['Baños', 'Sin área']);
    expect(report.items.first.byWarehouse.single.warehouseName, 'Principal');
    expect(report.items.first.byWarehouse.single.minStock, isNull);
  });

  test('consumo = interno + ventas; pérdida suma lo que faltó al contar', () {
    final item = SupplyItem.fromMap(
      _row(
        'v',
        'Vaso para llevar',
        'supply',
        stock: 40,
        used: 5,
        sold: 25,
        broken: 2,
        countAdjust: -3,
      ),
    );
    expect(item.consumedQty, 30);
    expect(item.consumedValue, 300);
    expect(item.lossQty, 5);
    expect(item.lossValue, 50);
    // Un conteo que SOBRÓ no es pérdida.
    final extra = SupplyItem.fromMap(
      _row('x', 'X', 'supply', stock: 1, countAdjust: 4),
    );
    expect(extra.lossQty, 0);
  });

  test('para cuántos días alcanza, al ritmo del período', () {
    final item = SupplyItem.fromMap(
      _row('p', 'Papel', 'supply', stock: 20, used: 60),
    );
    // 60 en 30 días = 2 por día → 20 alcanzan para 10 días.
    expect(item.dailyUse(30), 2);
    expect(item.daysLeft(30), 10);
    expect(item.attention(30), isFalse);
    // Sin uso no hay ritmo.
    final idle = SupplyItem.fromMap(_row('i', 'Idle', 'supply', stock: 5));
    expect(idle.daysLeft(30), isNull);
    // Sin existencia y con uso: se acabó.
    final out = SupplyItem.fromMap(_row('o', 'Out', 'supply', used: 3));
    expect(out.daysLeft(30), 0);
    expect(out.attention(30), isTrue);
  });

  test('menaje: bajo el par y cuántas faltan; no mira días', () {
    final copa = SupplyItem.fromMap(
      _row('c', 'Copa', 'smallware', stock: 100, min: 120),
    );
    expect(copa.belowMin, isTrue);
    expect(copa.missingToMin, 20);
    expect(copa.attention(30), isTrue);
    final plato = SupplyItem.fromMap(
      _row('pl', 'Plato', 'smallware', stock: 80, min: 60, broken: 50),
    );
    expect(plato.belowMin, isFalse);
    expect(plato.attention(30), isFalse);
    // Justo en el par no falta nada.
    final olla = SupplyItem.fromMap(
      _row('o', 'Olla', 'smallware', stock: 2, min: 2),
    );
    expect(olla.belowMin, isFalse);
    // Un gastable en su mínimo sí se repone (regla de las alertas de stock).
    final papel = SupplyItem.fromMap(
      _row('p', 'Papel', 'supply', stock: 48, min: 48),
    );
    expect(papel.belowMin, isTrue);
  });

  test('la tabla pone primero lo que hay que reponer y filtra', () {
    final state = SuppliesState(
      report: SuppliesReport.fromMap({
        'days': 30,
        'items': [
          _row('a', 'Cloro', 'supply', stock: 100, used: 90),
          _row('b', 'Papel', 'supply', stock: 1, min: 10, used: 5),
          _row('c', 'Servilletas', 'supply', stock: 500, used: 300),
          _row('d', 'Copa', 'smallware', stock: 1),
        ],
      }),
    );
    // Papel (bajo mínimo) primero; después por lo que más se usa.
    expect(state.visibleItems.map((i) => i.name), [
      'Papel',
      'Servilletas',
      'Cloro',
    ]);
    expect(state.attentionCount, 1);
    expect(
      state.copyWith(onlyAttention: true).visibleItems.map((i) => i.name),
      ['Papel'],
    );
    expect(
      state.copyWith(search: 'serv').visibleItems.map((i) => i.name),
      ['Servilletas'],
    );
    expect(
      state.copyWith(tab: SuppliesTab.smallware).visibleItems.map((i) => i.name),
      ['Copa'],
    );
  });
}
