// Comanda LOCAL (impresión directa por la LAN): mientras imprime, las líneas
// de esa ronda no cambian de cantidad ni se borran. Antes, subirle la
// cantidad a una durante la impresión la dejaba «por confirmar» con la
// cantidad nueva y el siguiente «Enviar» la reimprimía entera (cocina recibía
// 2 + 3 para una orden de 3). Y un modal abierto antes del envío no puede,
// al guardar después, subir en sitio una línea que ya salió a cocina.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/business_settings_offline_cache.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;
  @override
  SessionState build() => SessionState(
    activeBusinessId: businessId,
    activeBusinessName: 'Evento',
    userName: 'Cajero',
    permissions: {
      'ventas.orden.agregar_item',
      'ventas.orden.editar_item',
      'ventas.orden.enviar_cocina',
    },
  );
}

class _Sales extends SalesViewModel {
  _Sales(this.initial);
  final CurrentOrderState initial;
  @override
  CurrentOrderState build() => initial;
}

class _DelayedKitchen extends PrintingService {
  _DelayedKitchen(super.client, {this.fail = false});
  final bool fail;
  final started = Completer<void>();
  final release = Completer<void>();
  final printed = <List<OrderItem>>[];

  @override
  Future<LocalKitchenSendResult> sendLocalOrderToKitchen({
    required String businessId,
    required CurrentOrderState localState,
    String tableName = 'LOCAL',
    String? waiterName,
    String? businessName,
    KitchenAreaPrinterChooser? choosePrinter,
    bool forceChoosePrinter = false,
  }) async {
    printed.add(localState.items);
    if (!started.isCompleted) started.complete();
    await release.future;
    if (fail) throw StateError('impresora caída');
    return const LocalKitchenSendResult(dispatchIds: {}, pendingAreas: []);
  }
}

class _CloudHub extends StateNotifier<TerminalMode>
    implements HubModeController {
  _CloudHub() : super(TerminalMode.cloud);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;
  late SupabaseClient client;
  final secureStore = <String, String>{};

  setUpAll(() {
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
    client = SupabaseClient(
      'http://localhost:54321',
      'test-key',
      httpClient: MockClient(
        (request) async => throw TimeoutException('WAN unavailable'),
      ),
    );
  });

  setUp(() => ConnectivityService().simulateDisconnect());

  tearDownAll(() async {
    await db.close();
    await client.dispose();
  });

  Order order(String id) => Order(
    id: id,
    sessionId: 'session-$id',
    status: 'open',
    subtotal: 0,
    discounts: 0,
    serviceFee: 0,
    tax: 0,
    total: 0,
    createdAt: DateTime(2026, 10, 9),
  );

  Future<(ProviderContainer, _Sales)> prepare(
    String biz,
    PrintingService printing,
  ) async {
    await PosLookupOfflineCache().saveBusinessTaxes(biz, []);
    await BusinessSettingsOfflineCache().saveRow(businessId: biz, row: {});
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(() => _Session(biz)),
        currentOrderProvider.overrideWith(
          () => _Sales(CurrentOrderState(order: order('order-A'), origin: 'table')),
        ),
        hubModeProvider.overrideWith((ref) => _CloudHub()),
        salesRepositoryProvider.overrideWithValue(SalesRepository(client)),
        printingServiceProvider.overrideWithValue(printing),
      ],
    );
    addTearDown(container.dispose);
    final vm = container.read(currentOrderProvider.notifier) as _Sales;
    await vm.addItem(
      menuItemId: 'pollo',
      productName: 'Pollo',
      productPrice: 100,
      qty: 2,
    );
    return (container, vm);
  }

  OrderItem line(ProviderContainer c, String productName) => c
      .read(currentOrderProvider)
      .items
      .firstWhere((i) => i.productName == productName);

  test('subir la cantidad durante la impresión se rechaza y la ronda queda '
      'enviada (sin reimpresión)', () async {
    const biz = 'kitchen-guard-qty';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');
    expect(pollo.quantity, 2);

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    await vm.updateItemQuantity(pollo.id, 3);
    expect(line(c, 'Pollo').quantity, 2);
    expect(c.read(currentOrderProvider).error, contains('Espera'));

    printing.release.complete();
    await sending;

    final after = line(c, 'Pollo');
    expect(after.quantity, 2);
    expect(after.status, 'pending');
    expect(printing.printed.single.single.quantity, 2);
  });

  test('el modal durante la impresión avisa y no cambia la línea', () async {
    const biz = 'kitchen-guard-modal';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    await expectLater(
      vm.updateItem(pollo.id, pollo.copyWith(quantity: 3)),
      throwsA(predicate((e) => e.toString().contains('Espera'))),
    );
    printing.release.complete();
    await sending;

    expect(line(c, 'Pollo').quantity, 2);
    expect(line(c, 'Pollo').status, 'pending');
  });

  test('borrar una línea que se está imprimiendo se rechaza', () async {
    const biz = 'kitchen-guard-delete';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    expect(await vm.deleteItem(pollo.id), isFalse);
    expect(line(c, 'Pollo').id, pollo.id);
    printing.release.complete();
    await sending;

    expect(line(c, 'Pollo').status, 'pending');
  });

  test('una línea agregada durante la impresión sí se puede editar', () async {
    const biz = 'kitchen-guard-new-line';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    await vm.addItem(menuItemId: 'agua', productName: 'Agua', productPrice: 50);
    final agua = line(c, 'Agua');
    await vm.updateItemQuantity(agua.id, 3);
    expect(line(c, 'Agua').quantity, 3);
    printing.release.complete();
    await sending;

    expect(line(c, 'Pollo').status, 'pending');
    expect(line(c, 'Agua').status, 'draft');
    expect(line(c, 'Agua').quantity, 3);
  });

  test('modal abierto antes del envío y guardado después: no sube en sitio '
      'una línea que ya salió a cocina', () async {
    const biz = 'kitchen-guard-stale-modal';
    final printing = _DelayedKitchen(client);
    final (c, vm) = await prepare(biz, printing);
    // Lo que capturó el modal al abrirse: la línea «por enviar».
    final captured = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    printing.release.complete();
    await sending;
    expect(line(c, 'Pollo').status, 'pending');

    await expectLater(
      vm.updateItem(captured.id, captured.copyWith(quantity: 3)),
      throwsA(predicate((e) => e.toString().contains('ya salió a cocina'))),
    );
    expect(line(c, 'Pollo').quantity, 2);
    expect(line(c, 'Pollo').status, 'pending');
  });

  test('si la impresión falla, las líneas vuelven a poder editarse', () async {
    const biz = 'kitchen-guard-failed-print';
    final printing = _DelayedKitchen(client, fail: true);
    final (c, vm) = await prepare(biz, printing);
    final pollo = line(c, 'Pollo');

    final sending = vm.confirmOrder(tableName: 'Mesa 3');
    await printing.started.future;
    printing.release.complete();
    await expectLater(sending, throwsA(isA<StateError>()));

    await vm.updateItemQuantity(pollo.id, 3);
    expect(line(c, 'Pollo').quantity, 3);
    expect(line(c, 'Pollo').status, 'draft');
  });
}
