import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/order_edit.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/by_zone_state.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/fiscal/fiscal_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// T04 (20261010_0006): ediciones versionadas desde la pantalla de la cuenta.
/// Ningún cambio viejo pisa en silencio uno posterior; ante un conflicto la
/// intención del operador queda para que decida.

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;
  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    permissions: {'ventas.orden.agregar_item', 'ventas.orden.editar_item'},
  );
}

class _Sales extends SalesViewModel {
  _Sales(this.initial);
  final CurrentOrderState initial;
  @override
  CurrentOrderState build() => initial;
  @override
  Future<bool> ensureCashSessionOpen() async => true;
  @override
  Future<void> refreshOrder({bool clearIfPaid = false}) async {}
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Zones extends ByZoneViewModel {
  @override
  ByZoneState build() => const ByZoneState();
}

class _Fiscal implements FiscalService {
  @override
  Future<List<FiscalNcfSequence>> getSequences(String businessId) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// El servidor: cada edición se responde a mano (aplicada o en conflicto).
class _Server extends SalesRepository {
  _Server(super.client);

  final edits = <({double quantity, OrderEdit edit})>[];
  final replies = <Completer<OrderEditResult>>[];
  final _sent = StreamController<void>.broadcast();

  Future<void> waitForEdits(int count) async {
    while (edits.length < count) {
      await _sent.stream.first;
    }
  }

  @override
  Future<OrderEditResult> updateItemQuantity({
    required String itemId,
    required double quantity,
    required OrderEdit edit,
  }) {
    final reply = Completer<OrderEditResult>();
    edits.add((quantity: quantity, edit: edit));
    replies.add(reply);
    _sent.add(null);
    return reply.future;
  }

  void apply(int index) {
    final base = edits[index].edit.base.version ?? 0;
    replies[index].complete(
      OrderEditResult(status: 'applied', version: base + 1),
    );
  }

  void conflict(int index, {String reason = 'stale_version', int qty = 4}) {
    replies[index].completeError(
      OrderEditConflict(
        OrderEditResult(
          status: 'conflict',
          reason: reason,
          version: 9,
          current: {'qty': qty},
        ),
      ),
    );
  }

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
  getOrderBundle(String orderId, {String? businessId}) async {
    throw TimeoutException('bundle unavailable');
  }
}

CurrentOrderState _sale() => CurrentOrderState(
  origin: 'quick',
  order: Order.fromMap({
    'id': 'order-A',
    'session_id': 'session-A',
    'status_ext': 'open',
    'subtotal': 100,
    'total': 100,
    'created_at': '2026-10-10T12:00:00Z',
    'version': 3,
  }),
  items: [
    OrderItem.fromMap({
      'id': 'item-A',
      'order_id': 'order-A',
      'product_name': 'Producto A',
      'product_id': 'product-A',
      'qty': 1,
      'unit_price': 100,
      'subtotal': 100,
      'total': 100,
      'status': 'draft',
      'created_at': '2026-10-10T12:00:00Z',
      'version': 5,
    }),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final secureStore = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient client;
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            if (call.method == 'write') {
              secureStore[args['key'] as String] = args['value'] as String;
            }
            if (call.method == 'read') return secureStore[args['key']];
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    client = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((_) async => throw TimeoutException('no WAN')),
    );
  });
  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  Future<(ProviderContainer, _Server)> prepare(String biz) async {
    final server = _Server(client);
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'quick',
      origin: 'quick',
      state: _sale(),
    );
    ConnectivityService().simulateReconnect();
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(() => _Sales(_sale())),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(server),
      ],
    );
    addTearDown(container.dispose);
    return (container, server);
  }

  double quantityOf(ProviderContainer c) =>
      c.read(currentOrderProvider).items.single.quantity;

  test('dos toques rápidos: el segundo va sobre la versión que dejó el '
      'primero (no choca consigo)', () async {
    final (c, server) = await prepare('t04-own-taps');
    final vm = c.read(currentOrderProvider.notifier);

    final first = vm.updateItemQuantity('item-A', 2);
    await server.waitForEdits(1);
    final second = vm.updateItemQuantity('item-A', 3);
    // En fila: el segundo no sale mientras el primero no responde.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.edits, hasLength(1));

    server.apply(0);
    await first;
    await server.waitForEdits(2);
    server.apply(1);
    await second;

    expect(server.edits.map((e) => e.edit.base.version), [5, 6]);
    expect(server.edits.map((e) => e.edit.base.force), [false, false]);
    expect(server.edits[0].edit.opId, isNot(server.edits[1].edit.opId));
    expect(quantityOf(c), 3);
    expect(c.read(currentOrderProvider).items.single.version, 7);
    expect(c.read(currentOrderProvider).editConflict, isNull);
  });

  test('otro equipo cambió la línea: no se pisa, vuelve lo de antes y queda '
      'el aviso con la intención', () async {
    final (c, server) = await prepare('t04-conflict');
    final vm = c.read(currentOrderProvider.notifier);

    final editing = vm.updateItemQuantity('item-A', 2);
    await server.waitForEdits(1);
    expect(quantityOf(c), 2, reason: 'optimista mientras responde');
    server.conflict(0, qty: 4);
    await editing;

    final notice = c.read(currentOrderProvider).editConflict;
    expect(notice, isNotNull);
    expect(notice!.message, contains('Otro equipo cambió esto'));
    expect(notice.message, contains('Tu cambio:'));
    expect(notice.detail, 'Ahora: cantidad 4.');
    expect(quantityOf(c), 1, reason: 'el cambio no aplicado no se muestra');
    expect(vm.canApplyConflictingEdit, isTrue);
    // Un conflicto no es falta de red: nada a la cola.
    expect(
      (await offline.unsettledActions(
        't04-conflict',
      )).where((a) => a['type'] == 'update_item_quantity'),
      isEmpty,
    );

    // El operador decide aplicar su cambio: va forzado, una sola vez.
    final resolving = vm.resolveEditConflict(
      applyMine: true,
      noticeId: notice.id,
    );
    await server.waitForEdits(2);
    expect(server.edits[1].quantity, 2);
    expect(server.edits[1].edit.base.force, isTrue);
    server.apply(1);
    await resolving;
    expect(server.edits, hasLength(2));
    expect(c.read(currentOrderProvider).editConflict, isNull);
  });

  test('quedarse con lo de ahora no reenvía nada', () async {
    final (c, server) = await prepare('t04-keep');
    final vm = c.read(currentOrderProvider.notifier);
    final editing = vm.updateItemQuantity('item-A', 2);
    await server.waitForEdits(1);
    server.conflict(0);
    await editing;
    final notice = c.read(currentOrderProvider).editConflict!;

    await vm.resolveEditConflict(applyMine: false, noticeId: notice.id);

    expect(server.edits, hasLength(1));
    expect(c.read(currentOrderProvider).editConflict, isNull);
    expect(vm.canApplyConflictingEdit, isFalse);
  });

  test('una decisión sobre un aviso anterior no aplica la intención de otro',
      () async {
    final (c, server) = await prepare('t04-stale-decision');
    final vm = c.read(currentOrderProvider.notifier);
    final editing = vm.updateItemQuantity('item-A', 2);
    await server.waitForEdits(1);
    server.conflict(0);
    await editing;

    await vm.resolveEditConflict(applyMine: true, noticeId: 'aviso-anterior');

    expect(server.edits, hasLength(1));
    expect(c.read(currentOrderProvider).editConflict, isNotNull);
  });

  test('producto quitado por otro equipo: no se ofrece aplicar encima',
      () async {
    final (c, server) = await prepare('t04-missing');
    final vm = c.read(currentOrderProvider.notifier);
    final editing = vm.updateItemQuantity('item-A', 2);
    await server.waitForEdits(1);
    server.conflict(0, reason: 'item_missing');
    await editing;

    expect(c.read(currentOrderProvider).editConflict, isNotNull);
    expect(vm.canApplyConflictingEdit, isFalse);
  });
}
