// Conduce de salida de inventario: tiene que decir QUÉ salió, CUÁNTO, DE
// DÓNDE, POR QUÉ y quién lo autorizó — y traer las DOS firmas, porque una
// salida tiene dos responsables. A 58mm (32 columnas) nada se sale del papel.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/adjust_reasons.dart';
import 'package:mangopos/services/printing/waste_exit_ticket.dart';

String _ticket({
  String item = 'FILETE DE PECHUGA DE POLLO FRESCO',
  double quantity = 2.5,
  String unit = 'lb',
  String reasonLabel = 'Vencido',
  String warehouse = 'Almacen Principal',
  String? notes,
  String? operator_ = 'Robinson',
  double stockBefore = 12,
  double stockAfter = 9.5,
  double costPerUnit = 140,
  int paperWidth = 80,
}) => WasteExitTicket.generate(
  businessName: 'La Penda Express',
  itemName: item,
  quantity: quantity,
  unit: unit,
  reasonLabel: reasonLabel,
  warehouseName: warehouse,
  notes: notes,
  operatorName: operator_,
  stockBefore: stockBefore,
  stockAfter: stockAfter,
  costPerUnit: costPerUnit,
  paperWidth: paperWidth,
  occurredAt: DateTime.utc(2026, 9, 23, 18, 30),
).rawText ?? '';

void main() {
  group('WasteExitTicket', () {
    test('dice qué salió, de dónde y por qué', () {
      final t = _ticket();
      expect(t, contains('SALIDA DE INVENTARIO'));
      expect(t, contains('La Penda Express'));  // tal cual, como el comprobante de eliminación
      expect(t, contains('ALMACEN PRINCIPAL'));
      expect(t, contains('FILETE DE PECHUGA DE POLLO FRESCO'));
      expect(t, contains('2.5 lb'));
      expect(t, contains('VENCIDO'));
    });

    test('trae el antes y el después, que es lo que permite auditarlo', () {
      final t = _ticket(stockBefore: 12, stockAfter: 9.5);
      expect(t, contains('Stock antes:'));
      expect(t, contains('12 lb'));
      expect(t, contains('Stock después:'));
      expect(t, contains('9.5 lb'));
    });

    test('trae las DOS firmas: quien entrega y quien autoriza', () {
      final t = _ticket();
      expect(t, contains('Entregado por'));
      expect(t, contains('Autorizado por'));
      expect(t, contains('Registrado por: ROBINSON'));
    });

    test('costea la salida cuando el insumo tiene costo', () {
      // 2.5 lb x 140 = 350.00
      expect(_ticket(quantity: 2.5, costPerUnit: 140), contains('350.00'));
    });

    test('sin costo no inventa una línea de dinero', () {
      expect(_ticket(costPerUnit: 0), isNot(contains('Costo:')));
    });

    test('la nota sale cuando hay, y no cuando no', () {
      expect(_ticket(notes: 'Se rompió la funda'), contains('Se rompió la funda'));
      expect(_ticket(), isNot(contains('Nota:')));
    });

    test('cantidad entera sin decimales, fraccionaria sin ceros de relleno', () {
      expect(_ticket(quantity: 3, unit: 'ud'), contains('3 ud'));
      // una receta en onzas convertida a libras deja 0.0625
      expect(_ticket(quantity: 0.0625, unit: 'lb'), contains('0.0625 lb'));
    });

    test('a 58mm ninguna línea se sale del papel', () {
      for (final line in _ticket(paperWidth: 58).split('\n')) {
        expect(line.length, lessThanOrEqualTo(32), reason: 'se sale: "$line"');
      }
    });

    test('a 80mm tampoco', () {
      for (final line in _ticket(paperWidth: 80).split('\n')) {
        expect(line.length, lessThanOrEqualTo(48), reason: 'se sale: "$line"');
      }
    });
  });

  group('catálogo de motivos', () {
    test('«limpieza» existe y es una salida', () {
      final r = adjustReasonByCode('cleaning');
      expect(r, isNotNull);
      expect(r!.label, 'Limpieza');
      expect(r.isExit, isTrue);
    });

    test('rotura y vencimiento también son salidas', () {
      expect(adjustReasonByCode('breakage')!.isExit, isTrue);
      expect(adjustReasonByCode('expiration')!.isExit, isTrue);
    });

    test('un cuadre NO es salida: no hay nada que firmar', () {
      expect(adjustReasonByCode('physical_count')!.isExit, isFalse);
      expect(adjustReasonByCode('correction')!.isExit, isFalse);
    });
  });
}
