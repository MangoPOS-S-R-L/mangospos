// test/printing/kitchen_ticket_idempotency_test.dart
//
// Una REIMPRESIÓN de comanda es un duplicado deliberado del mismo papel. Si
// reusa la clave de idempotencia de la comanda original, la cola BT y el
// cloud queue (unique por business + idempotency_key donde status <>
// 'cancelled') la descartan contra el job viejo: no sale papel y el KDS
// igual dice "Comanda reimpresa". Estas pruebas fijan que cada tipo de
// ticket lleve su propia clave y que la comanda original NO cambie la suya
// (su dedupe sí es el que queremos: reintento de la MISMA comanda).
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/printing_service.dart';

void main() {
  const orderId = '8f2e6a5c-0000-4000-8000-000000000001';
  const areaCode = 'kitchen_hot';
  const printerId = 'printer-1';

  String? key({String? suffix, String? order = orderId}) =>
      kitchenTicketIdempotencyKey(
        orderId: order,
        areaCode: areaCode,
        printerId: printerId,
        suffix: suffix,
      );

  group('kitchenTicketIdempotencyKey', () {
    test('la comanda original conserva la clave legacy', () {
      expect(key(), 'kitchen-$orderId-$areaCode-$printerId');
      // Sufijo vacío = sin sufijo: no debe cambiar el dedupe de la comanda.
      expect(key(suffix: ''), key());
    });

    test('una reimpresión NO comparte clave con la comanda', () {
      expect(key(suffix: 'reprint-123'), isNot(key()));
    });

    test('dos reimpresiones distintas no se deduplican entre sí', () {
      expect(key(suffix: 'reprint-123'), isNot(key(suffix: 'reprint-124')));
    });

    test('el ticket de LISTO no colisiona con la comanda ni con la reimpresión',
        () {
      final ready = key(suffix: 'ready-123');
      expect(ready, isNot(key()));
      expect(ready, isNot(key(suffix: 'reprint-123')));
    });

    test('sin orderId no hay clave estable que deduplicar', () {
      expect(key(order: null), isNull);
      expect(key(order: '', suffix: 'reprint-1'), isNull);
    });

    test('cada área e impresora mantienen su propia clave', () {
      expect(
        kitchenTicketIdempotencyKey(
          orderId: orderId,
          areaCode: 'bar',
          printerId: printerId,
          suffix: 'reprint-1',
        ),
        isNot(key(suffix: 'reprint-1')),
      );
      expect(
        kitchenTicketIdempotencyKey(
          orderId: orderId,
          areaCode: areaCode,
          printerId: 'printer-2',
          suffix: 'reprint-1',
        ),
        isNot(key(suffix: 'reprint-1')),
      );
    });
  });
}
