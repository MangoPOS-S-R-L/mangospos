// Franja horaria del reporte "Ventas por mesero" (mig 20260919_0004).
//
// La franja se aplica a CADA día del rango. Cuando la hora de fin es <= la de
// inicio, la ventana cruza la medianoche: es el caso de un negocio nocturno
// (20:00 → 03:00 = la noche completa de cada día del rango). La RPC hace la
// misma lectura en SQL; estas pruebas fijan el contrato del lado de la app.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/reports/view/sales_by_waiter_view.dart';

void main() {
  group('salesByWaiterCrossesMidnight', () {
    test('fin < inicio cruza la medianoche', () {
      expect(
        salesByWaiterCrossesMidnight(
          const TimeOfDay(hour: 20, minute: 0),
          const TimeOfDay(hour: 3, minute: 0),
        ),
        isTrue,
      );
    });

    test('fin > inicio no cruza (franja diurna)', () {
      expect(
        salesByWaiterCrossesMidnight(
          const TimeOfDay(hour: 12, minute: 0),
          const TimeOfDay(hour: 18, minute: 0),
        ),
        isFalse,
      );
    });

    test('fin == inicio cruza: ventana de 24 h desde esa hora', () {
      expect(
        salesByWaiterCrossesMidnight(
          const TimeOfDay(hour: 20, minute: 0),
          const TimeOfDay(hour: 20, minute: 0),
        ),
        isTrue,
      );
    });

    test('los minutos cuentan, no solo la hora', () {
      expect(
        salesByWaiterCrossesMidnight(
          const TimeOfDay(hour: 20, minute: 30),
          const TimeOfDay(hour: 20, minute: 45),
        ),
        isFalse,
      );
      expect(
        salesByWaiterCrossesMidnight(
          const TimeOfDay(hour: 20, minute: 45),
          const TimeOfDay(hour: 20, minute: 30),
        ),
        isTrue,
      );
    });
  });

  group('salesByWaiterTimeParams', () {
    test('sin franja no manda parámetros — la RPC usa su default', () {
      expect(salesByWaiterTimeParams(null, null), (null, null));
    });

    test('una sola hora tampoco manda nada: la franja necesita las dos', () {
      expect(
        salesByWaiterTimeParams(const TimeOfDay(hour: 20, minute: 0), null),
        (null, null),
      );
      expect(
        salesByWaiterTimeParams(null, const TimeOfDay(hour: 3, minute: 0)),
        (null, null),
      );
    });

    test('formatea HH:mm:ss con cero a la izquierda', () {
      expect(
        salesByWaiterTimeParams(
          const TimeOfDay(hour: 20, minute: 0),
          const TimeOfDay(hour: 3, minute: 5),
        ),
        ('20:00:00', '03:05:00'),
      );
    });

    test('medianoche exacta se formatea 00:00:00, no vacío', () {
      expect(
        salesByWaiterTimeParams(
          const TimeOfDay(hour: 0, minute: 0),
          const TimeOfDay(hour: 6, minute: 0),
        ),
        ('00:00:00', '06:00:00'),
      );
    });
  });

  group('salesByWaiterTimeLabel', () {
    test('sin franja dice "Todo el día"', () {
      expect(salesByWaiterTimeLabel(null, null), 'Todo el día');
    });

    test('franja nocturna avisa del cruce de medianoche', () {
      expect(
        salesByWaiterTimeLabel(
          const TimeOfDay(hour: 20, minute: 0),
          const TimeOfDay(hour: 3, minute: 0),
        ),
        '20:00 → 03:00 (+1 día)',
      );
    });

    test('franja diurna no lleva el aviso', () {
      expect(
        salesByWaiterTimeLabel(
          const TimeOfDay(hour: 12, minute: 0),
          const TimeOfDay(hour: 18, minute: 30),
        ),
        '12:00 → 18:30',
      );
    });
  });
}
