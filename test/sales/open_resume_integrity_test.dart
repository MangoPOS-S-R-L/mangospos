// Integridad al abrir/retomar Venta Rápida/Manual (fase 4, unidad F2):
// - una carga o continuación de OTRA cuenta (cliente asignado, oferta) que
//   responde tarde nunca escribe en la pantalla nueva ni en su respaldo;
// - solo se retoma la venta que el SERVIDOR confirma como de esta pantalla
//   (table_sessions.origin), nunca por Order.origin (siempre 'table');
// - «Asignar a mesa» suelta el respaldo 'manual';
// - la confirmación del retomado reemplazada por otra carga decide con el
//   servidor;
// - el reinicio tras cobrar respeta la venta nueva que ya abrió el lector;
// - la marca local de cobrada se escribe antes de imprimir;
// - retail: un carrito anulado no salta al carrito de otro cliente.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/core/fiscal/sales_note_policy.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/payment_intent_journal.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/fiscal_models.dart';
import 'package:mangopos/data/models/payment_attempt_lease.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/repositories/sales_repository_improved.dart';
import 'package:mangopos/presentation/sales/state/by_zone_state.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/retail_carts_provider.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_by_zone_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/fiscal/fiscal_service.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _permissions = {'ventas.orden.agregar_item'};

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;

  @override
  SessionState build() =>
      SessionState(activeBusinessId: businessId, permissions: _permissions);

  /// El cajero cambia de sucursal.
  void switchTo(String other) => state = SessionState(
    activeBusinessId: other,
    permissions: _permissions,
  );
}

class _Sales extends SalesViewModel {
  @override
  CurrentOrderState build() => const CurrentOrderState();

  @override
  Future<bool> ensureCashSessionOpen() async => true;
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

typedef _Bundle = ({
  Order? order,
  List<OrderItem> items,
  List<OrderCheck> checks,
  String? customerId,
  String? customerName,
  String? note,
});

typedef _SessionRow = ({String? origin, DateTime? closedAt});

class _Repository extends SalesRepository {
  _Repository(super.client);

  /// Ids pedidos a fn_get_order_bundle, en orden.
  final loaded = <String>[];
  final added = <String>[];
  final sessionChecks = <String>[];
  final assignedToTable = <String>[];
  int sharedOpens = 0;
  final bundles = <String, _Bundle>{};

  /// Respuestas diferidas por orden, una por llamada (luego [bundles]).
  final bundleQueues = <String, List<Completer<_Bundle>>>{};
  final sessions = <String, _SessionRow?>{};
  Object? sessionError;
  Completer<void>? deferredAssignCustomer;
  Completer<void>? deferredAssignCheck;
  Completer<void>? deferredOffer;
  final tableOpens = <String, OpenTableResult>{};

  @override
  Future<Map<String, dynamic>> openManualOrQuick({
    required String origin,
    String? customerName,
    int peopleCount = 1,
    String? businessId,
  }) async {
    sharedOpens++;
    return {'order_id': 'order-new-$sharedOpens'};
  }

  @override
  Future<Map<String, dynamic>> openRetailCart({
    required String slot,
    required String businessId,
    int peopleCount = 1,
  }) async => {'order_id': 'remote-$slot'};

  @override
  Future<OpenTableResult> openTableAndLoad({
    required String tableId,
    String? userId,
    int peopleCount = 1,
    String? openedByEmployeeId,
  }) async => tableOpens[tableId]!;

  @override
  Future<Map<String, dynamic>> assignManualOrderToTable({
    required String orderId,
    required String tableId,
    String? userId,
  }) async {
    assignedToTable.add(orderId);
    return {'order_id': orderId};
  }

  @override
  Future<void> assignCustomerToSession({
    required String sessionId,
    required String customerId,
    required String customerName,
    String? businessId,
  }) async {
    await deferredAssignCustomer?.future;
  }

  @override
  Future<void> assignCustomerToCheck({
    required String checkId,
    required String customerId,
    required String customerName,
    String? customerRnc,
  }) async {
    await deferredAssignCheck?.future;
  }

  @override
  Future<String?> addOfferDealItem({
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    required double discount,
    required String name,
    String? promotionId,
    int checkPosition = 1,
    String? clientOpId,
    String? createdByEmployeeId,
  }) async {
    added.add('offer:$orderId');
    await deferredOffer?.future;
    return null;
  }

  @override
  Future<({String itemId, bool replayed, bool itemExists})>
  addItemFromMenuIdempotent({
    required String clientOpId,
    required String orderId,
    required String menuItemId,
    double quantity = 1,
    int checkPosition = 1,
    bool isTakeout = false,
    String? notes,
    String? createdByEmployeeId,
  }) async {
    added.add(orderId);
    return (
      itemId: 'remote-item-${added.length}',
      replayed: false,
      itemExists: true,
    );
  }

  @override
  Future<({String? origin, DateTime? closedAt})?> getOrderSessionOrigin(
    String orderId, {
    required String businessId,
  }) async {
    sessionChecks.add(orderId);
    if (sessionError != null) throw sessionError!;
    return sessions.containsKey(orderId)
        ? sessions[orderId]
        : (origin: 'quick', closedAt: null);
  }

  @override
  Future<_Bundle> getOrderBundle(String orderId, {String? businessId}) async {
    loaded.add(orderId);
    final queue = bundleQueues[orderId];
    if (queue != null && queue.isNotEmpty) {
      return queue.removeAt(0).future;
    }
    final bundle = bundles[orderId];
    if (bundle != null) return bundle;
    // Ventas y carritos recién abiertos: vacíos y abiertos.
    if (orderId.startsWith('order-new-') || orderId.startsWith('remote-')) {
      return _bundle(orderId, withItems: false);
    }
    throw TimeoutException('bundle sin respuesta');
  }
}

Order _order(String id, {String status = 'open'}) => Order.fromMap({
  'id': id,
  'session_id': 'session-$id',
  'status_ext': status,
  'subtotal': 100,
  'total': 100,
  'created_at': '2026-10-09T12:00:00Z',
});

OrderItem _item(String orderId) => OrderItem.fromMap({
  'id': 'item-$orderId',
  'order_id': orderId,
  'product_name': 'Producto $orderId',
  'product_id': 'product-$orderId',
  'qty': 1,
  'unit_price': 100,
  'subtotal': 100,
  'total': 100,
  'status': 'draft',
  'created_at': '2026-10-09T12:00:00Z',
});

CurrentOrderState _sale(String id, {String origin = 'quick'}) =>
    CurrentOrderState(origin: origin, order: _order(id), items: [_item(id)]);

_Bundle _bundle(String id, {String status = 'open', bool withItems = true}) => (
  order: _order(id, status: status),
  items: withItems ? [_item(id)] : const <OrderItem>[],
  checks: const <OrderCheck>[],
  customerId: null,
  customerName: null,
  note: null,
);

Payment _payment(String status) => Payment(
  id: 'payment-$status',
  businessId: 'biz',
  paymentMethodId: 'cash',
  amount: 100,
  changeAmount: 0,
  status: status,
  createdAt: DateTime(2026, 10, 9),
);

http.Response _emptyResponse(http.BaseRequest request) => http.Response(
  request.method == 'GET' ? '[]' : 'null',
  200,
  headers: {'content-type': 'application/json'},
  request: request as http.Request,
);

/// Cobro dividido en línea: el servidor confirma cada abono.
class _PaySales extends SalesRepositoryImproved {
  _PaySales(super.client);

  /// Retiene la respuesta del servidor al cobro.
  Completer<void>? gate;
  final paymentStarted = Completer<void>();

  @override
  Future<PaymentAttemptLease?> acquirePaymentAttempt({
    required String orderId,
    String? checkId,
    required String attemptId,
    String? deviceId,
    String? holderLabel,
  }) async => const PaymentAttemptLease(acquired: true);

  @override
  Future<Payment> processPayment({
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    int splitSequence = 0,
    bool closeCheck = true,
    DateTime? paidAt,
    String? attemptId,
  }) async {
    if (!paymentStarted.isCompleted) paymentStarted.complete();
    await gate?.future;
    return Payment(
    id: 'payment-$splitSequence',
    businessId: 'biz',
    orderId: orderId,
    checkId: checkId,
    paymentMethodId: paymentMethodId,
    amount: amount,
    changeAmount: changeAmount,
    status: 'completed',
    createdAt: paidAt ?? DateTime(2026, 10, 10),
  );
  }
}

class _NoContext extends Fake implements BuildContext {}

/// Diario del cobro que guarda el plan inicial y falla al anotar los abonos
/// (disco lleno).
class _JournalFailsAfterPlan extends PaymentIntentJournal {
  var _saves = 0;

  @override
  Future<bool> save(PaymentIntent intent) async => ++_saves == 1;
}

/// Retiene la lectura de fiscal_documents, la que precede a la espera del
/// e-CF en el cobro dividido.
Completer<void>? _fiscalLookupGate;
var _fiscalLookups = 0;

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final offline = OfflinePosService();
  final keys = <String, String>{};
  late OfflineQueueDb db;
  late SupabaseClient repoClient;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            if (call.method == 'write') {
              keys[args['key'] as String] = args['value'] as String;
            }
            if (call.method == 'read') return keys[args['key']];
            return null;
          },
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
    repoClient = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((request) async => _emptyResponse(request)),
    );
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/fiscal_documents')) {
          _fiscalLookups++;
          await _fiscalLookupGate?.future;
        }
        return _emptyResponse(request);
      }),
    );
  });

  setUp(() {
    offline.setHubUploader(null);
    ConnectivityService().simulateReconnect();
  });

  tearDownAll(() async {
    await db.close();
    await repoClient.dispose();
    await Supabase.instance.dispose();
  });

  ProviderContainer container(
    String biz,
    _Repository repository, {
    bool retail = false,
  }) {
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(_Sales.new),
        currentBusinessModelProvider.overrideWithValue(
          retail ? BusinessModel.retail : BusinessModel.restaurant,
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        byZoneVmProvider.overrideWith(_Zones.new),
        fiscalServiceProvider.overrideWithValue(_Fiscal()),
        salesRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<CurrentOrderState?> slot(String biz, String slotId) =>
      offline.loadSnapshot(businessId: biz, slotId: slotId);

  /// Mesa A abierta en línea (fn_open_table_and_load) y en pantalla.
  Future<ProviderContainer> withTableA(
    String biz,
    _Repository repository,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    repository.tableOpens['table-A'] = (
      orderId: 'order-A',
      bundle: _bundle('order-A'),
    );
    repository.bundles['order-A'] = _bundle('order-A');
    final c = container(biz, repository);
    await c.read(currentOrderProvider.notifier).openTable('table-A');
    expect(c.read(currentOrderProvider).order?.id, 'order-A');
    expect(c.read(currentOrderProvider).origin, 'table');
    return c;
  }

  group('una continuación tardía de otra cuenta no escribe', () {
    test(
      'cliente asignado en la mesa A que responde tarde no entra en la Venta '
      'Rápida retomada ni en su respaldo',
      () async {
        const biz = 'late-assign-customer-resume';
        final repository = _Repository(repoClient);
        await offline.saveSnapshot(
          businessId: biz,
          slotId: 'quick',
          origin: 'quick',
          state: _sale('order-Q'),
        );
        final confirmQ = Completer<_Bundle>();
        repository.bundleQueues['order-Q'] = [confirmQ];
        repository.deferredAssignCustomer = Completer<void>();
        final c = await withTableA(biz, repository);
        final vm = c.read(currentOrderProvider.notifier);

        final assigning = vm.assignCustomerToCurrentOrder(
          customerId: 'customer-1',
          customerName: 'Ana',
        );
        final resuming = vm.ensureQuickOrder();
        await _waitUntil(() => repository.loaded.contains('order-Q'));
        final loadsBefore = repository.loaded.length;

        // El servidor responde la asignación con la Venta Rápida ya en
        // pantalla: antes recargaba la mesa A con el origen 'quick'.
        repository.deferredAssignCustomer!.complete();
        expect(await assigning, isNull);
        confirmQ.complete(_bundle('order-Q'));
        await resuming;

        final visible = c.read(currentOrderProvider);
        expect(visible.order?.id, 'order-Q');
        expect(visible.origin, 'quick');
        expect(visible.loading, isFalse);
        expect(repository.loaded.skip(loadsBefore), isNot(contains('order-A')));
        expect((await slot(biz, 'quick'))?.order?.id, 'order-Q');
        expect((await slot(biz, 'table-A'))?.order?.id, 'order-A');
        expect(repository.sharedOpens, 0);
      },
    );

    test('cliente de sub-cuenta asignado en la mesa A que responde tarde no '
        'entra en la Venta Rápida nueva', () async {
      const biz = 'late-assign-check-fresh';
      final repository = _Repository(repoClient);
      repository.deferredAssignCheck = Completer<void>();
      final c = await withTableA(biz, repository);
      final vm = c.read(currentOrderProvider.notifier);

      final assigning = vm.assignCustomerToCheck(
        checkId: 'check-1',
        customerId: 'customer-1',
        customerName: 'Ana',
      );
      await vm.ensureQuickOrder();
      expect(c.read(currentOrderProvider).order?.id, 'order-new-1');
      final loadsBefore = repository.loaded.length;

      repository.deferredAssignCheck!.complete();
      await assigning;
      // Una recarga en vuelo tendría tiempo de escribir.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final visible = c.read(currentOrderProvider);
      expect(visible.order?.id, 'order-new-1');
      expect(visible.origin, 'quick');
      expect(repository.loaded.skip(loadsBefore), isNot(contains('order-A')));
      expect((await slot(biz, 'quick'))?.order?.id, 'order-new-1');
    });

    for (final outcome in ['responde bien', 'falla']) {
      test('oferta de la mesa A que $outcome tarde no entra en la Venta Manual '
          '(ni recarga ni restauración)', () async {
        final biz = 'late-offer-${outcome.replaceAll(' ', '-')}';
        final repository = _Repository(repoClient);
        repository.deferredOffer = Completer<void>();
        final c = await withTableA(biz, repository);
        final vm = c.read(currentOrderProvider.notifier);

        final offering = vm.addOfferDeal(
          menuItemId: 'product-offer',
          lineQty: 1,
          discount: 0,
          name: 'Oferta',
          originalPrice: 10,
        );
        await _waitUntil(() => repository.added.contains('offer:order-A'));
        await vm.ensureManualOrder();
        expect(c.read(currentOrderProvider).order?.id, 'order-new-1');
        final loadsBefore = repository.loaded.length;

        if (outcome == 'falla') {
          repository.deferredOffer!.completeError(
            PostgrestException(message: 'oferta rechazada', code: 'P0001'),
          );
        } else {
          repository.deferredOffer!.complete();
        }
        await offering;
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final visible = c.read(currentOrderProvider);
        expect(visible.order?.id, 'order-new-1');
        expect(visible.origin, 'manual');
        expect(visible.items, isEmpty);
        expect(visible.error, isNull);
        expect(repository.loaded.skip(loadsBefore), isNot(contains('order-A')));
        expect((await slot(biz, 'manual'))?.order?.id, 'order-new-1');
      });
    }
  });

  group('retomar solo lo que el servidor confirma como de esta pantalla', () {
    test(
      '«Asignar a mesa» suelta el respaldo manual: volver a Venta Manual abre '
      'una venta nueva',
      () async {
        const biz = 'assign-manual-to-table-releases-slot';
        final repository = _Repository(repoClient);
        await offline.saveSnapshot(
          businessId: biz,
          slotId: 'manual',
          origin: 'manual',
          state: _sale('order-M', origin: 'manual'),
        );
        repository.sessions['order-M'] = (origin: 'manual', closedAt: null);
        repository.bundles['order-M'] = _bundle('order-M');
        final c = container(biz, repository);
        final vm = c.read(currentOrderProvider.notifier);
        await vm.ensureManualOrder();
        expect(c.read(currentOrderProvider).order?.id, 'order-M');

        repository.tableOpens['table-5'] = (
          orderId: 'order-M',
          bundle: _bundle('order-M'),
        );
        await vm.assignManualOrderToTable(
          orderId: 'order-M',
          tableId: 'table-5',
        );
        expect(repository.assignedToTable, ['order-M']);
        expect(c.read(currentOrderProvider).origin, 'table');
        expect((await slot(biz, 'manual'))?.order, isNull);
        expect((await slot(biz, 'table-5'))?.order?.id, 'order-M');

        // Aunque el servidor no alcance a responder la sesión, el respaldo ya
        // no apunta a la cuenta de la mesa.
        repository.sessionError = PostgrestException(
          message: 'lectura fallida',
          code: 'PGRST000',
        );
        await vm.ensureManualOrder();

        final visible = c.read(currentOrderProvider);
        expect(visible.order?.id, 'order-new-1');
        expect(visible.origin, 'manual');
        expect(repository.sharedOpens, 1);
      },
    );

    for (final row in <String, _SessionRow?>{
      'pasada a una mesa (dine_in)': (origin: 'dine_in', closedAt: null),
      'de la otra pantalla (quick)': (origin: 'quick', closedAt: null),
      'con la sesión cerrada': (
        origin: 'manual',
        closedAt: DateTime(2026, 10, 9),
      ),
      'inexistente o de otro negocio': null,
    }.entries) {
      test(
        'respaldo manual cuya venta el servidor ve ${row.key} no se retoma',
        () async {
          final biz = 'resume-session-rejected-${row.key.hashCode}';
          final repository = _Repository(repoClient);
          await offline.saveSnapshot(
            businessId: biz,
            slotId: 'manual',
            origin: 'manual',
            state: _sale('order-M', origin: 'manual'),
          );
          repository.sessions['order-M'] = row.value;
          // Abierta en el servidor: por estado sola, se retomaría.
          repository.bundles['order-M'] = _bundle('order-M');
          final c = container(biz, repository);

          await c.read(currentOrderProvider.notifier).ensureManualOrder();

          final visible = c.read(currentOrderProvider);
          expect(visible.order?.id, 'order-new-1');
          expect(visible.origin, 'manual');
          expect(visible.loading, isFalse);
          expect(repository.sessionChecks, ['order-M']);
          expect(repository.loaded, isNot(contains('order-M')));
          expect((await slot(biz, 'manual'))?.order?.id, 'order-new-1');
        },
      );
    }

    test('la venta propia se confirma por su sesión aunque Order.origin sea '
        "'table' (orders no tiene columna origin)", () async {
      const biz = 'resume-session-not-order-origin';
      final repository = _Repository(repoClient);
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick',
        origin: 'quick',
        state: _sale('order-Q'),
      );
      repository.bundles['order-Q'] = _bundle('order-Q');
      expect(repository.bundles['order-Q']!.order!.origin, 'table');
      final c = container(biz, repository);

      await c.read(currentOrderProvider.notifier).ensureQuickOrder();

      final visible = c.read(currentOrderProvider);
      expect(visible.order?.id, 'order-Q');
      expect(visible.origin, 'quick');
      expect(visible.loading, isFalse);
      expect(repository.sessionChecks, ['order-Q']);
      expect(repository.sharedOpens, 0);
    });

    test('lectura de la sesión con error del servidor (ni confirma ni niega): '
        'decide la carga y no deja la venta huérfana', () async {
      const biz = 'resume-session-unknown';
      final repository = _Repository(repoClient);
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick',
        origin: 'quick',
        state: _sale('order-Q'),
      );
      repository.sessionError = PostgrestException(
        message: 'lectura fallida',
        code: 'PGRST000',
      );
      repository.bundles['order-Q'] = _bundle('order-Q');
      final c = container(biz, repository);

      await c.read(currentOrderProvider.notifier).ensureQuickOrder();

      expect(c.read(currentOrderProvider).order?.id, 'order-Q');
      expect(c.read(currentOrderProvider).loading, isFalse);
      expect(repository.loaded, ['order-Q']);
      expect(repository.sharedOpens, 0);
    });

    test(
      'sesión sin respuesta por red: se retoma como sin red, sin una segunda '
      'lectura al servidor caído',
      () async {
        const biz = 'resume-session-unreachable';
        final repository = _Repository(repoClient);
        await offline.saveSnapshot(
          businessId: biz,
          slotId: 'quick',
          origin: 'quick',
          state: _sale('order-Q'),
        );
        repository.sessionError = TimeoutException('red caída');
        final c = container(biz, repository);

        await c.read(currentOrderProvider.notifier).ensureQuickOrder();

        final visible = c.read(currentOrderProvider);
        expect(visible.order?.id, 'order-Q');
        expect(visible.items.map((i) => i.id), ['item-order-Q']);
        expect(visible.loading, isFalse);
        expect(repository.loaded, isEmpty);
        expect(repository.sharedOpens, 0);
      },
    );

    test('confirmación del retomado reemplazada por otra recarga de la misma '
        'venta: decide con el servidor (cobrada → venta nueva)', () async {
      const biz = 'resume-superseded-confirmation';
      final repository = _Repository(repoClient);
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick',
        origin: 'quick',
        state: _sale('order-Q'),
      );
      final first = Completer<_Bundle>();
      final second = Completer<_Bundle>();
      repository.bundleQueues['order-Q'] = [first, second];
      // Lo que responde el servidor de ahí en adelante: ya se cobró.
      repository.bundles['order-Q'] = _bundle('order-Q', status: 'paid');
      final c = container(biz, repository);
      final vm = c.read(currentOrderProvider.notifier);
      int loadsOfQ() => repository.loaded.where((id) => id == 'order-Q').length;

      final resuming = vm.ensureQuickOrder();
      await _waitUntil(() => loadsOfQ() == 1);
      // Otra recarga de la misma venta (p. ej. la de la impresión o la de
      // reconectar) reemplaza la confirmación en vuelo.
      final reloading = vm.reloadOrderNow();
      await _waitUntil(() => loadsOfQ() == 2);
      first.complete(_bundle('order-Q'));
      await resuming;
      second.complete(_bundle('order-Q', status: 'paid'));
      await reloading;

      final visible = c.read(currentOrderProvider);
      expect(visible.order?.id, 'order-new-1');
      expect(visible.origin, 'quick');
      expect(visible.loading, isFalse);
      expect(repository.sharedOpens, 1);
    });

    test('Pre-Cuenta durante la confirmación del retomado: cuando el '
        'reintento reemplaza su recarga, espera y lee el servidor, no el '
        'respaldo pintado', () async {
      const biz = 'precheck-during-resume-retry';
      final repository = _Repository(repoClient);
      // Respaldo de este equipo: 1 producto. El servidor tiene 2.
      await offline.saveSnapshot(
        businessId: biz,
        slotId: 'quick',
        origin: 'quick',
        state: _sale('order-Q'),
      );
      final _Bundle fresh = (
        order: _order('order-Q'),
        items: [
          _item('order-Q'),
          _item('order-Q').copyWith(id: 'item-order-Q-2'),
        ],
        checks: const <OrderCheck>[],
        customerId: null,
        customerName: null,
        note: null,
      );
      final confirm = Completer<_Bundle>();
      final precheck = Completer<_Bundle>();
      final retry = Completer<_Bundle>();
      repository.bundleQueues['order-Q'] = [confirm, precheck, retry];
      final c = container(biz, repository);
      final vm = c.read(currentOrderProvider.notifier);
      int loadsOfQ() => repository.loaded.where((id) => id == 'order-Q').length;

      final resuming = vm.ensureQuickOrder();
      await _waitUntil(() => loadsOfQ() == 1);
      CurrentOrderState? seenByPrecheck;
      final reloading = vm.reloadOrderNow().then(
        (_) => seenByPrecheck = c.read(currentOrderProvider),
      );
      await _waitUntil(() => loadsOfQ() == 2);
      // La confirmación quedó reemplazada: reintenta y reemplaza la recarga.
      confirm.complete(fresh);
      await _waitUntil(() => loadsOfQ() == 3);
      precheck.complete(fresh);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      retry.complete(fresh);
      await reloading;
      await resuming;

      expect(seenByPrecheck?.order?.id, 'order-Q');
      expect(seenByPrecheck?.loading, isFalse);
      expect(seenByPrecheck?.items.map((i) => i.id), [
        'item-order-Q',
        'item-order-Q-2',
      ]);
      expect(repository.sharedOpens, 0);
    });
  });

  test('recarga de la mesa reemplazada por otra de la misma cuenta (sin '
      '«cargando»): espera la vigente y lee el servidor', () async {
    const biz = 'reload-replaced-by-realtime';
    final repository = _Repository(repoClient);
    final c = await withTableA(biz, repository);
    final vm = c.read(currentOrderProvider.notifier);
    expect(c.read(currentOrderProvider).loading, isFalse);
    expect(c.read(currentOrderProvider).items, hasLength(1));

    final _Bundle fresh = (
      order: _order('order-A'),
      items: [
        _item('order-A'),
        _item('order-A').copyWith(id: 'item-order-A-2'),
      ],
      checks: const <OrderCheck>[],
      customerId: null,
      customerName: null,
      note: null,
    );
    final first = Completer<_Bundle>();
    final second = Completer<_Bundle>();
    repository.bundleQueues['order-A'] = [first, second];
    int loadsOfA() => repository.loaded.where((id) => id == 'order-A').length;
    final loadsBefore = loadsOfA();

    CurrentOrderState? seenByPrecheck;
    final reloading = vm.reloadOrderNow().then(
      (_) => seenByPrecheck = c.read(currentOrderProvider),
    );
    await _waitUntil(() => loadsOfA() == loadsBefore + 1);
    // Otra recarga de la misma mesa (p. ej. la de Realtime) la reemplaza.
    final other = vm.reloadOrderNow();
    await _waitUntil(() => loadsOfA() == loadsBefore + 2);
    first.complete(fresh);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    second.complete(fresh);
    await reloading;
    await other;

    expect(seenByPrecheck?.items.map((i) => i.id), [
      'item-order-A',
      'item-order-A-2',
    ]);
  });

  group('cierre de una venta cobrada', () {
    test('cobro dividido en línea: la marca local de cobrada se escribe antes '
        'de la espera del e-CF', () async {
      const biz = 'split-paid-mark-before-ecf';
      await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
      final c = container(biz, _Repository(repoClient));
      await c.read(currentOrderProvider.notifier).ensureQuickOrder();
      final orderId = c.read(currentOrderProvider).order!.id;
      expect((await slot(biz, 'quick'))?.order?.id, orderId);

      final payProvider =
          StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
            (ref) => PaymentSplitViewModel(
              _PaySales(repoClient),
              orderId,
              100,
              ref: ref,
              initialize: false,
              salesNotePolicy: const SalesNotePolicy(enabled: false),
              fiscalType: 'B02',
              sessionResolver: ({bool skipLocal = false}) async => 'caja',
              connectionStatus: () => true,
            ),
          );
      final pay = c.read(payProvider.notifier);
      // Lo que conecta la pantalla de ventas (ver _openPaymentModal).
      final salesVm = c.read(currentOrderProvider.notifier);
      pay.onServerConfirmed = (payments) => salesVm.markVirtualSalePaidLocally(
        businessId: biz,
        isRetail: false,
        orderId: orderId,
        origin: 'quick',
        checkId: null,
        payments: payments,
      );
      pay.setInput('100');
      pay.addTransaction();

      final gate = _fiscalLookupGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
        _fiscalLookupGate = null;
      });
      final lookupsBefore = _fiscalLookups;
      final paying = pay.confirmPayment(_NoContext());
      await _waitUntil(() => _fiscalLookups > lookupsBefore);

      // Esperando al e-CF: si la app muere aquí, un reinicio sin red no
      // retoma la venta cobrada.
      expect(
        await offline.isOrderClosedLocally(businessId: biz, orderId: orderId),
        isTrue,
      );
      expect(await slot(biz, 'quick'), isNull);

      gate.complete();
      expect(await paying, hasLength(1));
    });

    test('cambio de sucursal mientras responde el cobro: la marca va al '
        'negocio de la venta cobrada, no al activo', () async {
      const biz = 'paid-mark-branch-a';
      const otherBiz = 'paid-mark-branch-b';
      await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
      final c = container(biz, _Repository(repoClient));
      await c.read(currentOrderProvider.notifier).ensureQuickOrder();
      final orderId = c.read(currentOrderProvider).order!.id;
      expect((await slot(biz, 'quick'))?.order?.id, orderId);

      final sales = _PaySales(repoClient)..gate = Completer<void>();
      final payProvider =
          StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
            (ref) => PaymentSplitViewModel(
              sales,
              orderId,
              100,
              ref: ref,
              initialize: false,
              salesNotePolicy: const SalesNotePolicy(enabled: false),
              fiscalType: 'B02',
              sessionResolver: ({bool skipLocal = false}) async => 'caja',
              connectionStatus: () => true,
            ),
          );
      final pay = c.read(payProvider.notifier);
      // Lo que conecta la pantalla: el contexto fijado al tocar «Pagar».
      final salesVm = c.read(currentOrderProvider.notifier);
      pay.onServerConfirmed = (payments) => salesVm.markVirtualSalePaidLocally(
        businessId: biz,
        isRetail: false,
        orderId: orderId,
        origin: 'quick',
        checkId: null,
        payments: payments,
      );
      pay.setInput('100');
      pay.addTransaction();

      final paying = pay.confirmPayment(_NoContext());
      await sales.paymentStarted.future;
      // Mientras el servidor responde, el cajero pasa a otra sucursal.
      (c.read(sessionProvider.notifier) as _Session).switchTo(otherBiz);
      sales.gate!.complete();
      expect(await paying, hasLength(1));

      expect(
        await offline.isOrderClosedLocally(businessId: biz, orderId: orderId),
        isTrue,
      );
      expect(await slot(biz, 'quick'), isNull);
      expect(
        await offline.isOrderClosedLocally(
          businessId: otherBiz,
          orderId: orderId,
        ),
        isFalse,
      );
    });

    test('cobro de mesa: con otra sucursal ya activa, la marca va al negocio '
        'del cobro y no toca la pantalla nueva', () async {
      const biz = 'paid-table-branch-a';
      const otherBiz = 'paid-table-branch-b';
      final repository = _Repository(repoClient);
      final c = await withTableA(biz, repository);
      (c.read(sessionProvider.notifier) as _Session).switchTo(otherBiz);

      await c
          .read(currentOrderProvider.notifier)
          .markPaidOrderLocally('order-A', businessId: biz);

      expect(
        await offline.isOrderClosedLocally(businessId: biz, orderId: 'order-A'),
        isTrue,
      );
      expect(
        await offline.isOrderClosedLocally(
          businessId: otherBiz,
          orderId: 'order-A',
        ),
        isFalse,
      );
    });

    test('cobro dividido: si el diario falla tras el último abono, la marca '
        'local de cobrada ya quedó escrita', () async {
      const biz = 'split-paid-mark-journal-fails';
      await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
      final c = container(biz, _Repository(repoClient));
      await c.read(currentOrderProvider.notifier).ensureQuickOrder();
      final orderId = c.read(currentOrderProvider).order!.id;

      final payProvider =
          StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
            (ref) => PaymentSplitViewModel(
              _PaySales(repoClient),
              orderId,
              100,
              ref: ref,
              initialize: false,
              salesNotePolicy: const SalesNotePolicy(enabled: false),
              fiscalType: 'B02',
              sessionResolver: ({bool skipLocal = false}) async => 'caja',
              connectionStatus: () => true,
              intentJournal: _JournalFailsAfterPlan(),
            ),
          );
      final pay = c.read(payProvider.notifier);
      // Lo que conecta la pantalla de ventas (ver _openPaymentModal).
      final salesVm = c.read(currentOrderProvider.notifier);
      pay.onServerConfirmed = (payments) => salesVm.markVirtualSalePaidLocally(
        businessId: biz,
        isRetail: false,
        orderId: orderId,
        origin: 'quick',
        checkId: null,
        payments: payments,
      );
      pay.setInput('100');
      pay.addTransaction();

      // El servidor cerró la venta, pero el cobro no pudo anotarse.
      expect(await pay.confirmPayment(_NoContext()), isNull);
      expect(
        await offline.isOrderClosedLocally(businessId: biz, orderId: orderId),
        isTrue,
      );
      expect(await slot(biz, 'quick'), isNull);
    });

    test('el reinicio tras cobrar respeta la venta nueva que abrió el lector y '
        'su producto escaneado', () async {
      const biz = 'post-payment-restart-keeps-scanned-sale';
      await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
      final repository = _Repository(repoClient);
      final c = container(biz, repository);
      final vm = c.read(currentOrderProvider.notifier);
      await vm.ensureQuickOrder();
      expect(c.read(currentOrderProvider).order?.id, 'order-new-1');

      // Cobro: onFinish marca la venta en cierre; Realtime trae la venta
      // cobrada y vacía la pantalla.
      repository.bundles['order-new-1'] = _bundle(
        'order-new-1',
        status: 'paid',
      );
      await vm.markVirtualSalePaidLocally(
        businessId: biz,
        isRetail: false,
        orderId: 'order-new-1',
        origin: 'quick',
        checkId: null,
        payments: [_payment('completed')],
      );
      vm.markOrderClosing('order-new-1');
      await vm.refreshOrder(clearIfPaid: true);
      await _waitUntil(() => c.read(currentOrderProvider).order == null);

      // El lector escanea el primer producto del siguiente cliente.
      await vm.ensureQuickOrder();
      expect(c.read(currentOrderProvider).order?.id, 'order-new-2');
      await vm.addItem(
        menuItemId: 'product-scan',
        productName: 'Escaneado',
        productPrice: 10,
        productTaxRate: 0,
      );
      expect(repository.added, ['order-new-2']);

      // onFinish termina su closeOrder y reinicia.
      await vm.openQuick(forceRestart: true);

      final visible = c.read(currentOrderProvider);
      expect(visible.order?.id, 'order-new-2');
      expect(visible.origin, 'quick');
      expect(repository.sharedOpens, 2);
      expect((await slot(biz, 'quick'))?.order?.id, 'order-new-2');
    });

    test('el reinicio tras cobrar sí abre una venta nueva cuando la pantalla '
        'sigue en la venta cobrada', () async {
      const biz = 'post-payment-restart-replaces-paid-sale';
      await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
      final repository = _Repository(repoClient);
      final c = container(biz, repository);
      final vm = c.read(currentOrderProvider.notifier);
      await vm.ensureQuickOrder();
      expect(c.read(currentOrderProvider).order?.id, 'order-new-1');

      vm.markOrderClosing('order-new-1');
      await vm.openQuick(forceRestart: true);

      expect(c.read(currentOrderProvider).order?.id, 'order-new-2');
      expect(repository.sharedOpens, 2);
    });

    test(
      'cobro en línea confirmado: la marca local de cobrada se escribe antes '
      'de imprimir y un reinicio sin red no retoma la venta',
      () async {
        const biz = 'paid-online-marker-before-print';
        await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
        await offline.saveSnapshot(
          businessId: biz,
          slotId: 'quick',
          origin: 'quick',
          state: _sale('order-Q'),
        );
        final c = container(biz, _Repository(repoClient));

        await c
            .read(currentOrderProvider.notifier)
            .markVirtualSalePaidLocally(
              businessId: biz,
              isRetail: false,
              orderId: 'order-Q',
              origin: 'quick',
              checkId: null,
              payments: [_payment('completed')],
            );

        // Escrita al volver del await, sin esperar a onFinish.
        expect(
          await offline.isOrderClosedLocally(
            businessId: biz,
            orderId: 'order-Q',
          ),
          isTrue,
        );
        expect(await slot(biz, 'quick'), isNull);

        final repository = _Repository(repoClient);
        final restarted = container(biz, repository);
        ConnectivityService().simulateDisconnect();
        await restarted.read(currentOrderProvider.notifier).ensureQuickOrder();
        final visible = restarted.read(currentOrderProvider);
        expect(visible.order?.id, startsWith('local-order-'));
        expect(visible.items, isEmpty);
      },
    );

    for (final skipped
        in <
              String,
              ({String origin, String? checkId, String status, bool retail})
            >{
              'sub-cuenta': (
                origin: 'quick',
                checkId: 'check-1',
                status: 'completed',
                retail: false,
              ),
              'cobro en cola (sin red)': (
                origin: 'manual',
                checkId: null,
                status: 'pending',
                retail: false,
              ),
              'mesa': (
                origin: 'table',
                checkId: null,
                status: 'completed',
                retail: false,
              ),
              'retail': (
                origin: 'quick',
                checkId: null,
                status: 'completed',
                retail: true,
              ),
            }
            .entries) {
      test('sin marca anticipada para ${skipped.key}', () async {
        final biz = 'paid-online-marker-skip-${skipped.key.hashCode}';
        final c = container(
          biz,
          _Repository(repoClient),
          retail: skipped.value.retail,
        );
        await c
            .read(currentOrderProvider.notifier)
            .markVirtualSalePaidLocally(
              businessId: biz,
              isRetail: skipped.value.retail,
              orderId: 'order-S',
              origin: skipped.value.origin,
              checkId: skipped.value.checkId,
              payments: [_payment(skipped.value.status)],
            );
        expect(
          await offline.isOrderClosedLocally(
            businessId: biz,
            orderId: 'order-S',
          ),
          isFalse,
        );
      });
    }
  });

  test('retail: carrito anulado abre uno nuevo en su lugar y nunca salta al '
      'carrito de otro cliente', () async {
    const biz = 'retail-void-cart-no-jump';
    final repository = _Repository(repoClient);
    await offline.saveSnapshot(
      businessId: biz,
      slotId: 'quick-empty',
      origin: 'quick',
      state: _sale('order-V'),
    );
    repository.bundles['order-V'] = _bundle(
      'order-V',
      status: 'void',
      withItems: false,
    );
    final c = container(biz, repository, retail: true);
    c.read(retailCartsProvider.notifier).replaceAll([
      RetailCart(
        slotId: 'quick-x',
        number: 1,
        orderId: 'order-X',
        customerName: 'Cliente X',
      ),
      RetailCart(slotId: 'quick-empty', number: 2, orderId: 'order-V'),
    ], 'quick-empty');
    final vm = c.read(currentOrderProvider.notifier);
    await vm.switchRetailCart('quick-empty');
    expect(c.read(currentOrderProvider).order?.status, 'void');

    await vm.addItem(
      menuItemId: 'product-new',
      productName: 'Nuevo',
      productPrice: 10,
      productTaxRate: 0,
    );

    final carts = c.read(retailCartsProvider);
    final visible = c.read(currentOrderProvider);
    expect(carts.activeSlotId, isNot('quick-x'));
    expect(carts.activeSlotId, startsWith('quick-'));
    expect(visible.order?.id, 'remote-${carts.activeSlotId}');
    expect(visible.order?.id, isNot('order-X'));
    expect(
      carts.carts.map((cart) => cart.slotId),
      allOf(contains('quick-x'), isNot(contains('quick-empty'))),
    );
    expect(repository.added, isEmpty);
    // El producto no se agregó: el aviso sigue en pantalla (el lector no
    // canta «Agregado»).
    expect(visible.error, isNotNull);
  });
}
