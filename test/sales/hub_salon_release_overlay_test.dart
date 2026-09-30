import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';

void main() {
  TableStatus row({String? sessionId}) => TableStatus(
    tableId: 'table-1',
    zoneId: 'zone-1',
    code: 'B16',
    sessionId: sessionId,
    ordersCount: 0,
    minutesOpen: null,
  );

  test('servidor libre y fresco descarta orden remota vieja del Hub', () {
    expect(
      shouldOverlayHubTable(row(), {
        'order_id': '707a0b98-0000-0000-0000-000000000000',
      }, freshServerStatus: true),
      isFalse,
    );
  });

  test('orden local pendiente sigue visible aunque servidor diga libre', () {
    expect(
      shouldOverlayHubTable(row(), {
        'order_id': 'local-order-1234',
      }, freshServerStatus: true),
      isTrue,
    );
  });

  test('contenido del Hub con ID real nunca desaparece por fila libre', () {
    expect(
      shouldOverlayHubTable(row(), {
        'order_id': '707a0b98-0000-0000-0000-000000000000',
        'items_count': 1,
      }, freshServerStatus: true),
      isTrue,
    );
  });

  test('snapshot cacheado no desmiente al Hub', () {
    expect(
      shouldOverlayHubTable(row(), {
        'order_id': '707a0b98-0000-0000-0000-000000000000',
      }, freshServerStatus: false),
      isTrue,
    );
  });

  test('no pisa una sesion real abierta', () {
    expect(
      shouldOverlayHubTable(row(sessionId: 'session-1'), {
        'order_id': 'local-order-1234',
      }, freshServerStatus: true),
      isFalse,
    );
  });
}
