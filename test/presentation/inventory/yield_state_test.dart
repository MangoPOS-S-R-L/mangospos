// Cálculos del rendimiento por insumo.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/yield_state.dart';

Map<String, dynamic> _item(
  String name, {
  double consumed = 0,
  double waste = 0,
  double wasteValue = 0,
  double consumedValue = 0,
  Map<String, dynamic> byReason = const {},
}) => {
  'item_id': name.toLowerCase(),
  'item_name': name,
  'item_sku': '',
  'item_unit': 'lb',
  'purchased_qty': 10,
  'purchased_value': 1000,
  'consumed_qty': consumed,
  'consumed_value': consumedValue,
  'waste_qty': waste,
  'waste_value': wasteValue,
  'count_adjust_qty': 0,
  'count_adjust_value': 0,
  'waste_by_reason': byReason,
};

YieldReport _report() => YieldReport.fromMap({
  'days': 30,
  'from': '2026-09-01',
  'to': '2026-09-30',
  'items': [
    _item(
      'Pollo',
      consumed: 8,
      waste: 2,
      consumedValue: 800,
      wasteValue: 200,
      byReason: {
        'expiration': {'qty': 1.5, 'value': 150, 'count': 2},
        'breakage': {'qty': 0.5, 'value': 50, 'count': 1},
      },
    ),
    _item(
      'Queso',
      consumed: 9,
      waste: 1,
      consumedValue: 900,
      wasteValue: 100,
      byReason: {
        'breakage': {'qty': 1, 'value': 100, 'count': 1},
      },
    ),
    _item('Azúcar', consumed: 5, consumedValue: 50),
  ],
  'by_reason': [
    {'reason': 'expiration', 'qty': 1.5, 'value': 150, 'count': 2},
    {'reason': 'breakage', 'qty': 1.5, 'value': 150, 'count': 2},
  ],
  'daily': [
    {'day': '2026-09-29', 'consumed_value': 10, 'waste_value': 5},
    {'day': '2026-09-30', 'consumed_value': 20, 'waste_value': 0},
  ],
});

void main() {
  test('de lo que salió, qué parte fue merma', () {
    final pollo = _report().items.first;
    expect(pollo.wasteShare(), closeTo(0.2, 1e-9));
    expect(pollo.yieldShare, closeTo(0.8, 1e-9));
    // Solo por vencido: 1.5 de 10 que salieron.
    expect(pollo.wasteShare(reason: 'expiration'), closeTo(0.15, 1e-9));
    expect(pollo.wasteFor('expiration').value, 150);
    expect(pollo.wasteFor('cleaning').qty, 0);
  });

  test('sin salidas no hay porcentaje (no un 0 falso)', () {
    final item = YieldItem.fromMap(_item('Nada'));
    expect(item.wasteShare(), isNull);
    expect(item.yieldShare, isNull);
  });

  test('totales del reporte, en dinero', () {
    final r = _report();
    expect(r.consumedValue, 1750);
    expect(r.wasteValue, 300);
    expect(r.wasteShare, closeTo(300 / 2050, 1e-9));
    expect(r.daily.first.day, DateTime(2026, 9, 29));
  });

  test('filtro por motivo, búsqueda y orden', () {
    final state = YieldState(report: _report());
    expect(state.visibleItems.map((i) => i.name), ['Pollo', 'Queso', 'Azúcar']);

    final expiration = state.copyWith(reasonFilter: 'expiration');
    expect(expiration.visibleItems.map((i) => i.name), ['Pollo']);

    final breakage = state.copyWith(reasonFilter: 'breakage');
    // Rotura: Queso 100 > Pollo 50.
    expect(breakage.visibleItems.map((i) => i.name), ['Queso', 'Pollo']);

    expect(state.copyWith(search: 'que').visibleItems.single.name, 'Queso');
    expect(
      state.copyWith(sort: YieldSort.name).visibleItems.map((i) => i.name),
      ['Azúcar', 'Pollo', 'Queso'],
    );
    expect(
      state.copyWith(clearReason: true, reasonFilter: null).reasonFilter,
      isNull,
    );
  });
}
