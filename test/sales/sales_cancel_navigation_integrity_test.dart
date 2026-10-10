import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/retail_carts_provider.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/fiscal/fiscal_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;

  @override
  SessionState build() =>
      SessionState(activeBusinessId: businessId, userName: 'Cajero A');
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

class _Fiscal implements FiscalService {
  @override
  Future<List<FiscalNcfSequence>> getSequences(String businessId) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository extends SalesRepository {
  _Repository(super.client);
  final closeStarted = Completer<void>();
  final closeRelease = Completer<void>();
  final noteStarted = Completer<void>();
  final noteRelease = Completer<void>();
  bool deferClose = true;
  bool deferNote = false;
  final closedIds = <String>[];
  final notes = <({String sessionId, String? note, String? businessId})>[];

  // closeRetailCart lee el servidor antes de anular en línea (una pantalla
  // vieja puede mostrar abierta una venta ya cobrada): aquí confirma que la
  // venta sigue abierta, así el cierre sigue yendo en línea.
  @override
  Future<Order?> getOrder(String orderId, {String? businessId}) async =>
      Order.fromMap({
        'id': orderId,
        'session_id': 'session-$orderId',
        'status_ext': 'open',
        'subtotal': 100,
        'total': 100,
        'created_at': '2026-10-09T12:00:00Z',
      });

  @override
  Future<void> closeOrder({
    required String orderId,
    required String status,
  }) async {
    expect(status, 'void');
    closedIds.add(orderId);
    closeStarted.complete();
    if (deferClose) await closeRelease.future;
  }

  /// Servidor sin 20261009_0007: el cierre de la pestaña usa closeOrder.
  @override
  Future<String> voidOrderIfUnpaid(String orderId) async =>
      throw const PostgrestException(
        message: 'Could not find the function public.fn_void_order_if_unpaid',
        code: 'PGRST202',
      );

  @override
  Future<void> updateSessionNote({
    required String sessionId,
    String? note,
    String? businessId,
  }) async {
    notes.add((sessionId: sessionId, note: note, businessId: businessId));
    noteStarted.complete();
    if (deferNote) await noteRelease.future;
  }
}

CurrentOrderState _sale(String id, String note) => CurrentOrderState(
  origin: 'quick',
  sessionNote: note,
  order: Order.fromMap({
    'id': id,
    'session_id': 'session-$id',
    'status_ext': 'open',
    'subtotal': 100,
    'total': 100,
    'created_at': '2026-10-09T12:00:00Z',
  }),
  items: [
    OrderItem.fromMap({
      'id': 'item-$id',
      'order_id': id,
      'product_name': 'Producto $id',
      'qty': 1,
      'unit_price': 100,
      'subtotal': 100,
      'total': 100,
      'status': 'draft',
      'created_at': '2026-10-09T12:00:00Z',
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
    offline.setHubUploader(null);
    client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient((_) async => throw TimeoutException('no WAN')),
    );
  });

  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  Future<ProviderContainer> prepare(String businessId, _Repository repo) async {
    final first = _sale('order-A', 'Nota A');
    final second = _sale('order-B', 'Nota B');
    await PosLookupOfflineCache().saveBusinessTaxes(businessId, []);
    await offline.saveSnapshot(
      businessId: businessId,
      slotId: 'quick-A',
      origin: 'quick',
      state: first,
    );
    await offline.saveSnapshot(
      businessId: businessId,
      slotId: 'quick-B',
      origin: 'quick',
      state: second,
    );
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(businessId)),
        currentOrderProvider.overrideWith(() => _Sales(first)),
        currentBusinessModelProvider.overrideWithValue(BusinessModel.retail),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    container.read(retailCartsProvider.notifier).replaceAll([
      const RetailCart(slotId: 'quick-A', orderId: 'order-A', number: 1),
      const RetailCart(slotId: 'quick-B', orderId: 'order-B', number: 2),
    ], 'quick-A');
    ConnectivityService().simulateDisconnect();
    await container
        .read(currentOrderProvider.notifier)
        .switchRetailCart('quick-A');
    ConnectivityService().simulateReconnect();
    return container;
  }

  test(
    'late close of cart A preserves selected cart B and its snapshot',
    () async {
      const businessId = 'cancel-A-switch-B';
      final repository = _Repository(client);
      final container = await prepare(businessId, repository);
      final vm = container.read(currentOrderProvider.notifier);
      final cancelling = vm.closeRetailCart('quick-A');
      await repository.closeStarted.future;
      ConnectivityService().simulateDisconnect();
      await vm.switchRetailCart('quick-B');
      final second = container.read(currentOrderProvider);
      repository.closeRelease.complete();
      await cancelling;

      final visible = container.read(currentOrderProvider);
      expect(repository.closedIds, ['order-A']);
      expect(visible.order?.id, 'order-B');
      expect(visible.items, second.items);
      expect(visible.sessionNote, 'Nota B');
      expect(container.read(retailCartsProvider).activeSlotId, 'quick-B');
      expect(
        (await offline.loadSnapshot(
          businessId: businessId,
          slotId: 'quick-B',
        ))?.items,
        second.items,
      );
      expect(
        await offline.isOrderClosedLocally(
          businessId: businessId,
          orderId: 'order-A',
        ),
        isTrue,
      );
      expect(
        await offline.isOrderClosedLocally(
          businessId: businessId,
          orderId: 'order-B',
        ),
        isFalse,
      );
    },
  );

  test(
    'late cancellation audit note belongs only to the captured session',
    () async {
      const businessId = 'cancel-note-A-switch-B';
      final repository = _Repository(client)
        ..deferClose = false
        ..deferNote = true;
      final container = await prepare(businessId, repository);
      final vm = container.read(currentOrderProvider.notifier);
      final cancelling = vm.cancelCurrentOrder(
        reason: 'Cliente retiró el pedido',
      );
      await repository.noteStarted.future;
      ConnectivityService().simulateDisconnect();
      await vm.switchRetailCart('quick-B');
      repository.noteRelease.complete();
      await cancelling;

      expect(repository.closedIds, ['order-A']);
      expect(repository.notes.single.sessionId, 'session-order-A');
      expect(repository.notes.single.businessId, businessId);
      expect(repository.notes.single.note, startsWith('Nota A\n[ANULACION]'));
      expect(
        repository.notes.single.note,
        contains('Cajero A: Cliente retiró el pedido'),
      );
      final visible = container.read(currentOrderProvider);
      expect(visible.order?.id, 'order-B');
      expect(visible.sessionNote, 'Nota B');
      expect(visible.items.single.productName, 'Producto order-B');
    },
  );
}
