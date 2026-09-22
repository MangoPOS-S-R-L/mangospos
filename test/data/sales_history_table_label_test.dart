// Columna "Mesa" del Historial de ventas.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/utils/sales_history_table_label.dart';

void main() {
  test('la mesa de la vista manda', () {
    expect(
      salesHistoryTableLabel(
        viewLabel: 'MUEBLE12',
        tableLabel: 'Otra',
        tableCode: 'M12',
      ),
      'MUEBLE12',
    );
  });

  test('sin la migración, usa la etiqueta y si no el código', () {
    expect(
      salesHistoryTableLabel(tableLabel: 'MUEBLE12', tableCode: 'M12'),
      'MUEBLE12',
    );
    expect(salesHistoryTableLabel(tableLabel: '  ', tableCode: 'M12'), 'M12');
  });

  test('sin mesa dice qué fue, no un guion', () {
    expect(salesHistoryTableLabel(origin: 'quick'), 'Venta rápida');
    expect(salesHistoryTableLabel(origin: 'quick_sale'), 'Venta rápida');
    expect(salesHistoryTableLabel(origin: 'manual'), 'Venta manual');
    expect(salesHistoryTableLabel(origin: 'delivery'), 'Delivery');
    expect(salesHistoryTableLabel(), '—');
  });
}
