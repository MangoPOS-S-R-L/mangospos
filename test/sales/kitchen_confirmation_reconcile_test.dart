// Fase 3 (5.2) de la guía de cierre: con operaciones de la cuenta todavía en
// la cola, la recarga ya no ignora el servidor entero. Una confirmación de
// cocina que el servidor tiene para la misma línea (otra caja la envió) se
// incorpora y lo local (notas, cantidades, líneas sin subir) se conserva. Es
// el fallo de caja de la mesa A26 (10-10): una nota pendiente dejaba en
// «por confirmar» lo que cocina ya tenía.

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/business_settings_offline_cache.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _orderId = '0a100000-0000-4000-8000-000000000001';
const _miller = '6a000000-0000-4000-8000-000000000001';
const _juice = '6a000000-0000-4000-8000-000000000002';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;
  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    activeBusinessName: 'Medio Tiempo',
    userName: 'Caja',
    permissions: {'ventas.orden.agregar_item', 'ventas.orden.enviar_cocina'},
  );
}

class _Sales extends SalesViewModel {
  _Sales(this.initial);
  final CurrentOrderState initial;
  @override
  CurrentOrderState build() => initial;
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

OrderItem _item(
  String id,
  String name, {
  String status = 'draft',
  double qty = 1,
  String? notes,
}) => OrderItem(
  id: id,
  orderId: _orderId,
  productId: name,
  productName: name,
  quantity: qty,
  unitPrice: 225,
  subtotal: 225 * qty,
  discounts: 0,
  tax: 0,
  total: 225 * qty,
  isTakeout: false,
  status: status,
  notes: notes,
  createdAt: DateTime(2026, 10, 10, 21, 51),
);

Order _order({String status = 'open'}) => Order(
  id: _orderId,
  sessionId: 'session-$_orderId',
  status: status,
  subtotal: 0,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: 0,
  createdAt: DateTime(2026, 10, 10, 20, 3),
);

class _Server extends SalesRepository {
  _Server(super.client);
  List<OrderItem> items = [];
  Order order = _order();

  @override
  Future<
    ({
      Order? order,
      List<OrderItem> items,
      List<OrderCheck> checks,
      String? customerId,
      String? customerName,
      String? note,
    })
  >
  getOrderBundle(String orderId, {String? businessId}) async => (
    order: order,
    items: List.of(items),
    checks: const <OrderCheck>[],
    customerId: null,
    customerName: null,
    note: null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
  final secureStore = <String, String>{};
  final offline = OfflinePosService();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? const {};
            if (call.method == 'write') {
              secureStore[args['key'] as String] = args['value'] as String;
            }
            if (call.method == 'read') return secureStore[args['key']];
            if (call.method == 'containsKey') {
              return secureStore.containsKey(args['key']);
            }
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    client = SupabaseClient('http://localhost:54321', 'test-key');
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient(
        (request) async => http.Response(
          request.method == 'GET' ? '[]' : 'null',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
    );
  });

  setUp(() {
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDownAll(() async {
    ConnectivityService().simulateDisconnect();
    await db.close();
    await client.dispose();
    await Supabase.instance.dispose();
  });

  Future<(ProviderContainer, SalesViewModel)> caja(
    String biz,
    _Server server,
    List<OrderItem> onScreen,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(
            CurrentOrderState(
              order: _order(),
              origin: 'table',
              items: onScreen,
            ),
          ),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(server),
      ],
    );
    addTearDown(c.dispose);
    return (c, c.read(currentOrderProvider.notifier));
  }

  /// Operación de la cuenta todavía sin subir (en espera de reintento).
  Future<void> pendingInQueue(String biz, Map<String, dynamic> action) =>
      offline.enqueueAction(
        businessId: biz,
        action: {
          ...action,
          'order_id': _orderId,
          'origin': 'table',
          'status': 'failed',
          'attempts': 1,
          'next_retry_at': DateTime.now()
              .add(const Duration(hours: 1))
              .toIso8601String(),
        },
      );

  OrderItem line(ProviderContainer c, String id) =>
      c.read(currentOrderProvider).items.firstWhere((item) => item.id == id);

  test('S14: el servidor ya confirmó la línea y la caja tiene una nota '
      'pendiente: incorpora la confirmación y conserva la nota', () async {
    const biz = 's14';
    final server = _Server(client)
      ..items = [
        _item(_miller, '4x3 Miller', status: 'pending', qty: 4),
        _item(_juice, 'Jugo fresa'),
      ];
    final (c, vm) = await caja(biz, server, [
      _item(_miller, '4x3 Miller', qty: 4, notes: 'misma cubeta'),
      _item(_juice, 'Jugo fresa'),
    ]);
    await pendingInQueue(biz, {
      'type': 'update_item_notes',
      'item_id': _miller,
      'notes': 'misma cubeta',
    });

    await vm.reloadOrderNow();
    expect(line(c, _miller).status, 'pending', reason: 'cocina ya la tiene');
    expect(line(c, _miller).notes, 'misma cubeta', reason: 'nota local');
    expect(line(c, _juice).status, 'draft', reason: 'nadie la envió');
  });

  test('S15: envío local pendiente de subir y lectura vieja del servidor '
      '(draft): no vuelve a «por confirmar»', () async {
    const biz = 's15';
    final server = _Server(client)
      ..items = [_item(_miller, '4x3 Miller', qty: 4)];
    final (c, vm) = await caja(biz, server, [
      _item(_miller, '4x3 Miller', status: 'pending', qty: 4),
    ]);
    await pendingInQueue(biz, {
      'type': 'confirm_local_order',
      'item_ids_by_area': {
        'cervezas': [_miller],
      },
      'printed_areas': ['cervezas'],
      'missing_areas': <String>[],
    });

    await vm.reloadOrderNow();
    expect(line(c, _miller).status, 'pending');
  });

  test('S20: un incremento local posterior no queda confirmado por la ronda '
      'anterior', () async {
    const biz = 's20';
    final server = _Server(client)
      ..items = [_item(_miller, '4x3 Miller', status: 'pending', qty: 2)];
    final (c, vm) = await caja(biz, server, [
      _item(_miller, '4x3 Miller', qty: 3),
    ]);
    await pendingInQueue(biz, {
      'type': 'update_item_quantity',
      'item_id': _miller,
      'quantity': 3,
    });

    await vm.reloadOrderNow();
    expect(line(c, _miller).status, 'draft', reason: 'el incremento sigue');
    expect(line(c, _miller).quantity, 3);
  });

  test('S20: una cuenta cobrada en el servidor no se resucita por una marca '
      'local de cocina', () async {
    const biz = 's20-closed';
    final server = _Server(client)
      ..order = _order(status: 'paid')
      ..items = [_item(_miller, '4x3 Miller', status: 'paid', qty: 4)];
    final (c, vm) = await caja(biz, server, [
      _item(_miller, '4x3 Miller', status: 'pending', qty: 4),
    ]);
    await pendingInQueue(biz, {
      'type': 'confirm_local_order',
      'item_ids_by_area': {
        'cervezas': [_miller],
      },
      'printed_areas': ['cervezas'],
      'missing_areas': <String>[],
    });

    await vm.reloadOrderNow();
    final order = c.read(currentOrderProvider).order;
    expect(order == null || order.status == 'paid', isTrue);
  });
}
