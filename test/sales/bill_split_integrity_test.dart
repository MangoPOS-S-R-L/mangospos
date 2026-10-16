import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/models/order_edit.dart';
import 'package:mangopos/data/models/bill_split_edit.dart';
import 'package:mangopos/presentation/split_bill/viewmodel/split_bill_viewmodel.dart';
import 'package:mangopos/presentation/split_bill/widgets/split_bill_modal.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'offer_split_receipts_test.dart' as f;

class _Session extends f.Session {
  @override
  SessionState build() => super.build().copyWith(
    permissions: {...super.build().permissions, 'ventas.cuenta.split_equiv'},
  );
}

class _Repository extends f.FixtureSales {
  _Repository(super.client, {required super.current, super.afterExplode});
  final commits = <BillSplitEdit>[];
  Object? reject;
  Completer<void>? gate;
  Object? preparationFailure;
  @override
  Future<int> explodeItemsToUnits({required String orderId}) async {
    if (preparationFailure case final failure?) throw failure;
    return super.explodeItemsToUnits(orderId: orderId);
  }

  @override
  Future<OrderEditResult> applyBillSplit(BillSplitEdit intent) async {
    commits.add(intent);
    await gate?.future;
    final e = reject;
    reject = null;
    if (e != null) throw e;
    return const OrderEditResult(status: 'applied', version: 8);
  }

  @override
  Future<OrderEditResult?> moveItemsToCheckBatch({
    required List<OrderItem> items,
    required int checkPosition,
    required String orderId,
    String? opId,
    bool force = false,
  }) => throw StateError('No se permiten escrituras por destino');
  @override
  Future<void> deleteCheck(String id) =>
      throw StateError('No se permiten borrados sueltos');
  @override
  Future<void> setCheckNcfType({required String checkId, String? ncfType}) =>
      throw StateError('No se permiten cambios fiscales sueltos');
}

Map<String, dynamic> source({
  bool assigned = false,
  bool offer = false,
  bool customer = false,
}) {
  final base = f.snap('delete_before_split', 'two_offers');
  final main = Map<String, dynamic>.from((base['checks'] as List).first);
  final oid = (base['order'] as Map)['id'];
  return {
    ...base,
    'checks': [
      main,
      {
        ...main,
        'id': 'temp_c2',
        'position': 2,
        'label': 'C2',
        if (customer) 'customer_id': 'customer-A',
        if (customer) 'customer_name': 'Ana',
        if (customer) 'customer_rnc': '101010101',
        if (customer) 'requested_ncf_type': 'B01',
      },
      {...main, 'id': 'temp_c3', 'position': 3, 'label': 'C3'},
    ],
    'items': [
      for (final (id, qty, discount, check)
          in offer
              ? [('a', 3.0, 0.0, 'temp_c2'), ('b', 1.0, 250.0, 'temp_c2')]
              : [
                  ('a', 1.0, 0.0, assigned ? 'temp_c2' : null),
                  ('b', 1.0, 0.0, assigned ? 'temp_c3' : null),
                ])
        {
          'id': id,
          'order_id': oid,
          'product_id': 'same-product',
          'product_name': offer ? '4x3 Cerveza' : 'Refresco',
          'qty': qty,
          'unit_price': offer ? 250.0 : 100.0,
          'subtotal': qty * (offer ? 250 : 100),
          'tax': 0.0,
          'tax_rate': 0.0,
          'tax_mode': 'inclusive',
          'discounts': discount,
          'status': 'pending',
          'check_id': check ?? main['id'],
          'version': 1,
          if (offer) 'notes': '[DEAL:promo]\n[DEAL_RULE:4:250.00]',
          'created_at': '2026-10-15T12:00:00Z',
        },
    ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  setUp(
    () => client = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    ),
  );
  tearDown(() => client.dispose());
  Future<(ProviderContainer, SplitBillViewModel)> prepare(
    _Repository repo,
  ) async {
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        salesRepositoryProvider.overrideWithValue(repo),
      ],
    );
    c.listen(splitBillViewModelProvider, (_, _) {});
    addTearDown(c.dispose);
    final vm = c.read(splitBillViewModelProvider.notifier);
    await vm.initialize(f.sale(repo.current));
    return (c, vm);
  }

  test(
    'tres jugos enviados juntos se reparten uno por uno entre cuentas',
    () async {
      final grouped = source();
      final row = Map<String, dynamic>.from((grouped['items'] as List).first)
        ..addAll({
          'product_name': 'JUGOS NATURALES',
          'qty': 3,
          'unit_price': 250,
          'subtotal': 750,
          'total': 750,
          'status': 'pending',
        });
      grouped['items'] = [row];
      final prepared = {
        ...grouped,
        'items': [
          for (final id in ['a', 'jugo-2', 'jugo-3'])
            {...row, 'id': id, 'qty': 1, 'subtotal': 250, 'total': 250},
        ],
      };
      final repo = _Repository(
        client,
        current: grouped,
        afterExplode: prepared,
      );
      final (c, vm) = await prepare(repo);
      final initial = c.read(splitBillViewModelProvider);
      expect(initial.unassignedItems, hasLength(3));
      expect(
        initial.allItems.every((i) => i.quantity == 1 && i.status == 'pending'),
        true,
      );
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c2');
      vm.toggleItemSelection('jugo-2');
      await vm.assignSelectedItemsToCheck('temp_c3');
      var state = c.read(splitBillViewModelProvider);
      expect(state.itemsForCheck('temp_c2').single.quantity, 1);
      expect(state.itemsForCheck('temp_c3').single.quantity, 1);
      expect(state.unassignedItems.single.id, 'jugo-3');
      expect(state.checks.map((c) => c.total), [250, 250]);
      await vm.unassignItem('a');
      state = c.read(splitBillViewModelProvider);
      expect(state.itemsForCheck('temp_c3').single.id, 'jugo-2');
      expect(state.unassignedItems, hasLength(2));
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c2');
      await vm.applySplit();
      expect(repo.commits.single.assignments.map((a) => a['item_id']).toSet(), {
        'a',
        'jugo-2',
      });
      expect(
        repo.commits.single.assignments
            .map((a) => a['target_position'])
            .toSet(),
        {2, 3},
      );
    },
  );

  test(
    'una preparación fallida bloquea movimientos y permite reintentar',
    () async {
      final data = source();
      final repo = _Repository(client, current: data)
        ..preparationFailure = TimeoutException('sin respuesta');
      final (c, vm) = await prepare(repo);
      expect(c.read(splitBillViewModelProvider).initializationFailed, true);
      expect(c.read(splitBillViewModelProvider).canApplySplit, false);
      await vm.createNewCheck();
      await vm.applySplit();
      await vm.applyEqualSplit();
      expect(repo.commits, isEmpty);
      expect(c.read(splitBillViewModelProvider).checks, isEmpty);
      repo.preparationFailure = null;
      await vm.initialize(f.sale(data));
      expect(c.read(splitBillViewModelProvider).initializationFailed, false);
      expect(c.read(splitBillViewModelProvider).canApplySplit, true);
    },
  );

  test(
    'si el servidor devuelve un grupo ordinario no se mueve entero',
    () async {
      final data = source();
      final row = Map<String, dynamic>.from((data['items'] as List).first)
        ..addAll({'qty': 3, 'subtotal': 300});
      data['items'] = [row];
      final repo = _Repository(client, current: data);
      final (c, vm) = await prepare(repo);
      final state = c.read(splitBillViewModelProvider);
      expect(state.initializationFailed, true);
      expect(state.error, contains('20261015_0004'));
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c2');
      await vm.applySplit();
      expect(repo.commits, isEmpty);
    },
  );

  test(
    'un grupo de oferta se mantiene completo al preparar y trasladar',
    () async {
      final data = source(offer: true);
      data['items'] = [
        {
          ...Map<String, dynamic>.from((data['items'] as List).first),
          'qty': 4,
          'subtotal': 1000,
          'discounts': 250,
          'total': 750,
        },
      ];
      final repo = _Repository(client, current: data);
      final (c, vm) = await prepare(repo);
      expect(c.read(splitBillViewModelProvider).initializationFailed, false);
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c3');
      final target = c.read(splitBillViewModelProvider).checks.last;
      expect(target.items.single.quantity, 4);
      expect(target.total, 750);
    },
  );

  testWidgets('el modal muestra tres filas y un toque traslada solo un jugo', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1100);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final data = source();
    final row = Map<String, dynamic>.from((data['items'] as List).first)
      ..addAll({
        'product_name': 'JUGOS NATURALES',
        'qty': 3,
        'unit_price': 250,
        'subtotal': 750,
        'total': 750,
      });
    data['items'] = [row];
    final prepared = {
      ...data,
      'items': [
        for (final id in ['a', 'jugo-2', 'jugo-3'])
          {...row, 'id': id, 'qty': 1, 'subtotal': 250, 'total': 250},
      ],
    };
    final repo = _Repository(client, current: data, afterExplode: prepared);
    final (container, _) = await prepare(repo);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SplitBillModal(order: f.sale(data), onSplitApplied: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('JUGOS NATURALES'), findsNWidgets(3));
    await tester.tap(find.text('JUGOS NATURALES').first);
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'C2'));
    await tester.pumpAndSettle();
    final state = container.read(splitBillViewModelProvider);
    expect(state.itemsForCheck('temp_c2').single.quantity, 1);
    expect(state.checks.first.total, 250);
    expect(state.unassignedItems, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  test(
    'unir cuentas nuevas conserva ambas filas y envía los dos identificadores',
    () async {
      final repo = _Repository(client, current: source());
      final (c, vm) = await prepare(repo);
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c2');
      vm.toggleItemSelection('b');
      await vm.assignSelectedItemsToCheck('temp_c3');
      await vm.mergeChecks(sourceCheckId: 'temp_c2', targetCheckId: 'temp_c3');
      expect(
        c.read(splitBillViewModelProvider).allItems.map((i) => i.id).toSet(),
        {'a', 'b'},
      );
      expect(c.read(splitBillViewModelProvider).checks.single.total, 200);
      expect(repo.commits, isEmpty);
      await vm.applySplit();
      expect(repo.commits, hasLength(1));
      expect(repo.commits.single.assignments.map((a) => a['item_id']).toSet(), {
        'a',
        'b',
      });
      expect(
        repo.commits.single.assignments.every((a) => a['target_position'] == 3),
        true,
      );
      expect(c.read(splitBillViewModelProvider).splitApplied, true);
    },
  );
  test(
    'todos los destinos viajan juntos y un conflicto no confirma la división',
    () async {
      final repo = _Repository(client, current: source())
        ..reject = const OrderEditConflict(
          OrderEditResult(status: 'conflict', reason: 'stale_version'),
        );
      final (c, vm) = await prepare(repo);
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c2');
      vm.toggleItemSelection('b');
      await vm.assignSelectedItemsToCheck('temp_c3');
      await vm.applySplit();
      expect(
        repo.commits.single.assignments
            .map((a) => a['target_position'])
            .toSet(),
        {2, 3},
      );
      expect(c.read(splitBillViewModelProvider).splitApplied, false);
      expect(c.read(splitBillViewModelProvider).editConflict, isNotNull);
    },
  );
  test(
    'cliente RNC y comprobante sobreviven a inicializar y mover productos',
    () async {
      final repo = _Repository(
        client,
        current: source(assigned: true, customer: true),
      );
      final (c, vm) = await prepare(repo);
      var ch = c.read(splitBillViewModelProvider).checks.first;
      expect(ch.customerId, 'customer-A');
      expect(ch.customerRnc, '101010101');
      expect(ch.requestedNcfType, 'B01');
      await vm.assignCustomerToCheck(
        checkId: 'temp_c2',
        customerId: 'customer-B',
        customerName: 'Bea',
        customerRnc: '202020202',
      );
      vm.toggleItemSelection('b');
      await vm.assignSelectedItemsToCheck('temp_c2');
      ch = c.read(splitBillViewModelProvider).checks.first;
      expect(ch.customerId, 'customer-B');
      expect(ch.customerRnc, '202020202');
      expect(ch.requestedNcfType, 'B01');
      await vm.applySplit();
      final data = repo.commits.single.checks.first;
      expect(data['customer_id'], 'customer-B');
      expect(data['customer_rnc'], '202020202');
      expect(data['requested_ncf_type'], 'B01');
    },
  );
  test(
    'tipo fiscal de una subcuenta nueva se incluye en la transacción',
    () async {
      final repo = _Repository(client, current: source());
      final (c, vm) = await prepare(repo);
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c2');
      await vm.setNcfTypeForCheck('temp_c2', 'B01');
      await vm.applySplit();
      expect(repo.commits.single.checks.first['requested_ncf_type'], 'B01');
      expect(repo.commits.single.checks.first['write_metadata'], true);
    },
  );
  test(
    'separar 3+1 retira el beneficio; reunirlos recupera la oferta',
    () async {
      final repo = _Repository(client, current: source(offer: true));
      final (c, vm) = await prepare(repo);
      vm.toggleItemSelection('b');
      await vm.assignSelectedItemsToCheck('temp_c3');
      var s = c.read(splitBillViewModelProvider);
      expect(s.checks.first.total, 750);
      expect(s.checks.last.total, 250);
      expect(s.allItems.fold<double>(0, (a, i) => a + i.discounts), 0);
      vm.toggleItemSelection('b');
      await vm.assignSelectedItemsToCheck('temp_c2');
      s = c.read(splitBillViewModelProvider);
      expect(s.checks.first.total, 750);
      expect(s.allItems.fold<double>(0, (a, i) => a + i.discounts), 250);
    },
  );
  test(
    'respuesta perdida conserva ID y contenido; no acepta cambios ni duplica envío simultáneo',
    () async {
      final repo = _Repository(client, current: source())
        ..reject = TimeoutException('respuesta perdida');
      final (c, vm) = await prepare(repo);
      vm.toggleItemSelection('a');
      await vm.assignSelectedItemsToCheck('temp_c2');
      await vm.applySplit();
      final original = jsonEncode(repo.commits.single.toRpcParams());
      await vm.setNcfTypeForCheck('temp_c2', 'B01');
      expect(
        c.read(splitBillViewModelProvider).checks.first.requestedNcfType,
        isNull,
      );
      repo.gate = Completer<void>();
      final retry = vm.applySplit();
      await vm.applySplit();
      expect(repo.commits, hasLength(2));
      expect(jsonEncode(repo.commits.last.toRpcParams()), original);
      repo.gate!.complete();
      await retry;
      expect(c.read(splitBillViewModelProvider).splitApplied, true);
    },
  );
  test('un rechazo SQL conocido permite corregir el borrador', () async {
    final repo = _Repository(client, current: source())
      ..reject = const PostgrestException(message: 'MAX_CHECKS_REACHED');
    final (c, vm) = await prepare(repo);
    await vm.applySplit();
    await vm.setNcfTypeForCheck('temp_c2', 'B01');
    expect(
      c.read(splitBillViewModelProvider).checks.first.requestedNcfType,
      'B01',
    );
  });
  test(
    'eliminar subcuenta prepara todos los retiros sin escribir hasta Aplicar',
    () async {
      final data = source(assigned: true);
      final checks = data['checks'] as List;
      checks[1] = <String, dynamic>{
        ...Map<String, dynamic>.from(checks[1] as Map),
        'id': '90000000-0000-4000-8000-000000000002',
      };
      (data['items'] as List)[0] = <String, dynamic>{
        ...Map<String, dynamic>.from((data['items'] as List)[0] as Map),
        'check_id': '90000000-0000-4000-8000-000000000002',
      };
      final repo = _Repository(client, current: data);
      final (c, vm) = await prepare(repo);
      await vm.deleteCheck('90000000-0000-4000-8000-000000000002');
      expect(repo.commits, isEmpty);
      await vm.applySplit();
      expect(repo.commits.single.deletedCheckIds, [
        '90000000-0000-4000-8000-000000000002',
      ]);
      expect(repo.commits.single.assignments.single['target_position'], 1);
    },
  );
  test(
    'igualitaria usa la misma entrada atómica y admite reintento idempotente',
    () async {
      final repo = _Repository(client, current: source())
        ..reject = TimeoutException('respuesta perdida');
      final (c, vm) = await prepare(repo);
      await vm.applyEqualSplit();
      expect(repo.commits.single.equalPeople, 2);
      await vm.applyEqualSplit();
      expect(repo.commits.last.opId, repo.commits.first.opId);
    },
  );
  test('redondear dos mitades de centavo no aumenta el consumo de 600', () {
    final rows = [
      for (var i = 0; i < 2; i++)
        OrderItem.fromMap({
          'id': '$i',
          'qty': 1,
          'unit_price': 300,
          'subtotal': 234.375,
          'tax': 65.625,
          'tax_mode': 'inclusive',
          'tax_rate': 28,
        }),
    ];
    final summary = summarizeOrderPricing(null, rows);
    expect(summary.total, 600);
    expect(summary.subtotal + summary.tax, 600);
  });
  test('sin RPC atómica no se recurre a escrituras individuales', () async {
    final paths = <String>[];
    final c = SupabaseClient(
      'http://localhost:54321',
      'test',
      httpClient: MockClient((r) async {
        paths.add(r.url.path);
        return http.Response(
          jsonEncode({'code': 'PGRST202', 'message': 'missing RPC'}),
          404,
          headers: {'content-type': 'application/json'},
          request: r,
          reasonPhrase: 'Not Found',
        );
      }),
    );
    await expectLater(
      SalesRepository(c).applyBillSplit(
        const BillSplitEdit(
          opId: 'op',
          orderId: 'order',
          assignments: [],
          checks: [],
          deletedCheckIds: [],
        ),
      ),
      throwsA(isA<BillSplitServerOutdated>()),
    );
    expect(paths, ['/rest/v1/rpc/fn_apply_bill_split']);
    await c.dispose();
  });
}
