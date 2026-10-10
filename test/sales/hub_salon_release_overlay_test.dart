import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/hub/hub_order_projector.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/presentation/sales/logic/hub_order_closure_guard.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  test(
    'pago confirmado por servidor descarta proyeccion vieja con importe',
    () {
      const orderId = '707a0b98-0000-0000-0000-000000000000';
      expect(
        shouldOverlayHubTable(
          row(),
          {'order_id': orderId, 'items_count': 1, 'total': 640},
          freshServerStatus: true,
          confirmedClosedOrderIds: {orderId},
        ),
        isFalse,
      );
    },
  );

  test('lectura cacheada nunca desmiente trabajo pendiente del Hub', () {
    const orderId = '707a0b98-0000-0000-0000-000000000000';
    expect(
      shouldOverlayHubTable(
        row(),
        {'order_id': orderId, 'items_count': 1},
        freshServerStatus: false,
        confirmedClosedOrderIds: {orderId},
      ),
      isTrue,
    );
  });

  test('orden local reconciliada también deja de ocupar la mesa', () {
    const orderId = 'local-order-paid-1';
    expect(
      shouldOverlayHubTable(
        row(),
        {'order_id': orderId, 'items_count': 1, 'total': 640},
        freshServerStatus: true,
        confirmedClosedOrderIds: {orderId},
      ),
      isFalse,
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

  group('cierre remoto con contenido offline', () {
    const remoteId = '707a0b98-0000-0000-0000-000000000000';
    const localId = 'local-order-pending';
    final add = <String, dynamic>{
      'type': 'add_item',
      'order_id': localId,
      'item_id': 'tmp-pending',
      'table_id': 'table-1',
      'qty': 1,
      'product_price': 640,
    };

    Future<HubClosureReconciliation> reconcile({
      String status = 'void',
      List<Map<String, dynamic>> queue = const [],
      List<Map<String, dynamic>> hub = const [],
      bool verifyHub = true,
      bool hasContent = true,
    }) => reconcileHubOrderClosures(
      remoteClosures: {remoteId: status},
      remoteOrderIds: {remoteId: remoteId},
      ordersWithHubContent: hasContent ? {remoteId} : {},
      canVerifyHubUploads: verifyHub,
      readQueueActions: () async => queue,
      readHubActions: () async => hub,
      mappedOrderId: (id) async => id == localId ? remoteId : null,
    );

    test(
      'void del barrido no retira producto pendiente en cola por alias',
      () async {
        final result = await reconcile(queue: [add]);
        expect(result.confirmed, isEmpty);
        expect(result.conflicts, {remoteId});
        expect(
          shouldOverlayHubTable(
            row(),
            {'order_id': remoteId, 'items_count': 1, 'total': 640},
            freshServerStatus: true,
            confirmedClosedOrderIds: result.confirmed.keys.toSet(),
          ),
          isTrue,
        );
      },
    );

    test(
      'void del barrido no se espeja sobre contenido no subido del Hub',
      () async {
        final ops = [
          {
            'seq': 1,
            'type': 'open_table',
            'order_id': localId,
            'table_id': 'table-1',
          },
          {...add, 'seq': 2},
        ];
        final result = await reconcile(hub: [add]);
        // Es la misma condición que usa el caller para publicar cierres.
        if (result.confirmed.isNotEmpty) {
          ops.add({'seq': 3, 'type': 'void_order', 'order_id': localId});
        }
        expect(result.confirmed, isEmpty);
        expect(HubOrderProjector.projectSalon(ops).single.total, 640);
        expect(HubOrderProjector.openOrderIds(ops), {localId});
      },
    );

    test('contenido dead sigue necesitando conciliación', () async {
      final result = await reconcile(
        queue: [
          {...add, 'status': 'dead'},
        ],
      );
      expect(result.confirmed, isEmpty);
      expect(result.conflicts, {remoteId});
    });

    test('proyección sin items conserva señal de conciliación pendiente', () {
      expect(
        shouldOverlayHubTable(
          row(),
          {'order_id': remoteId, 'items_count': 0},
          freshServerStatus: true,
          unsettledOrderIds: {remoteId},
        ),
        isTrue,
      );
    });

    test('autoliberación pendiente no descarta el alta anterior', () async {
      final result = await reconcile(
        hub: [
          add,
          {'type': 'release_empty_order', 'order_id': localId},
        ],
      );
      expect(result.confirmed, isEmpty);
    });

    test('anulación explícita pendiente conserva su efecto', () async {
      for (final source in ['queue', 'hub']) {
        final actions = [
          add,
          {'type': 'void_order', 'order_id': localId},
        ];
        final result = await reconcile(
          queue: source == 'queue' ? actions : [],
          hub: source == 'hub' ? actions : [],
        );
        expect(result.confirmed, {remoteId: 'void'});
        expect(result.conflicts, isEmpty);
      }
    });

    test('contenido posterior a anulación pendiente no se descarta', () async {
      final result = await reconcile(
        queue: [
          {'type': 'void_order', 'order_id': localId},
          add,
        ],
      );
      expect(result.confirmed, isEmpty);
    });

    test('pago offline pendiente no desaparece por void del barrido', () async {
      final result = await reconcile(
        queue: [
          {'type': 'process_payment', 'order_id': localId, 'amount': 640},
        ],
      );
      expect(result.confirmed, isEmpty);
    });

    test('pago remoto tampoco oculta contenido aún no confirmado', () async {
      final result = await reconcile(status: 'paid', hub: [add]);
      expect(result.confirmed, isEmpty);
    });

    test(
      'pagado histórico sin pendientes retira la proyección vieja',
      () async {
        final result = await reconcile(status: 'paid');
        expect(result.confirmed, {remoteId: 'paid'});
        expect(
          shouldOverlayHubTable(
            row(),
            {'order_id': remoteId, 'items_count': 1, 'total': 640},
            freshServerStatus: true,
            confirmedClosedOrderIds: result.confirmed.keys.toSet(),
          ),
          isFalse,
        );
      },
    );

    test(
      'cliente sin acuses del host conserva proyección con productos',
      () async {
        for (final status in ['void', 'paid']) {
          final result = await reconcile(status: status, verifyHub: false);
          expect(result.confirmed, isEmpty);
          expect(result.conflicts, {remoteId});
        }
      },
    );

    test('cliente respeta anulación explícita pendiente', () async {
      final result = await reconcile(
        verifyHub: false,
        queue: [
          {'type': 'void_order', 'order_id': remoteId},
        ],
      );
      expect(result.confirmed, {remoteId: 'void'});
    });

    test(
      'lectura fallida de cola o Hub no equivale a ninguna operación',
      () async {
        for (final failingSource in ['queue', 'hub']) {
          final result = await reconcileHubOrderClosures(
            remoteClosures: {remoteId: 'void'},
            remoteOrderIds: {remoteId: remoteId},
            ordersWithHubContent: {remoteId},
            canVerifyHubUploads: true,
            readQueueActions: () async {
              if (failingSource == 'queue') throw StateError('SQLite read');
              return [];
            },
            readHubActions: () async {
              if (failingSource == 'hub') throw StateError('Hub read');
              return [];
            },
            mappedOrderId: (_) async => remoteId,
          );
          expect(result.confirmed, isEmpty);
          expect(result.conflicts, {remoteId});
        }
      },
    );

    test('mapping desconocido no permite ocultar contenido', () async {
      final result = await reconcile(
        queue: [
          {...add, 'order_id': 'local-order-unknown'},
        ],
      );
      expect(result.confirmed, isEmpty);
    });

    test(
      'pendientes de otra identidad conocida no bloquean el pago viejo',
      () async {
        final result = await reconcile(
          status: 'paid',
          queue: [
            {...add, 'order_id': 'unrelated-remote-order'},
          ],
        );
        expect(result.confirmed, {remoteId: 'paid'});
      },
    );
  });

  test('consulta de cierres usa pertenencia real por sesión', () async {
    const orderId = '707a0b98-0000-0000-0000-000000000000';
    final requests = <Uri>[];
    final client = SupabaseClient(
      'https://offline-test.invalid',
      'test-key',
      httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response(
          jsonEncode([
            {'id': orderId, 'status_ext': 'paid'},
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    try {
      expect(
        await fetchClosedHubOrderStatuses(
          client,
          businessId: 'business-1',
          orderIds: [orderId],
        ),
        {orderId: 'paid'},
      );
      expect(requests.single.path, '/rest/v1/orders');
      final query = requests.single.queryParameters;
      expect(
        query['select'],
        'id,status_ext,table_sessions!inner(business_id)',
      );
      expect(query['table_sessions.business_id'], 'eq.business-1');
      expect(query, isNot(contains('business_id')));
      expect(query['status_ext'], 'in.("paid","void")');
      expect(query['id'], contains(orderId));
    } finally {
      await client.dispose();
    }
  });
}
