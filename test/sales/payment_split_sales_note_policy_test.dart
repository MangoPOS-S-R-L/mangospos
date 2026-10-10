import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/fiscal/sales_note_policy.dart';
import 'package:mangopos/data/models/payment_attempt_lease.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository_improved.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/view/payment_split_screen.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Sales extends SalesRepositoryImproved {
  _Sales(super.client);

  final noteChoices = <bool>[];
  final fiscalTypes = <String?>[];
  bool normalizeCheckToOrder = false;
  String? fiscalDocumentId;

  @override
  Future<void> markAsSalesNote({
    required String orderId,
    String? checkId,
    bool value = true,
  }) async => noteChoices.add(value);

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
    fiscalTypes.add(fiscalType);
    return Payment(
      id: 'payment-$splitSequence',
      businessId: 'business',
      orderId: orderId,
      checkId: normalizeCheckToOrder ? null : checkId,
      fiscalDocumentId: fiscalDocumentId,
      paymentMethodId: paymentMethodId,
      amount: amount,
      changeAmount: changeAmount,
      status: 'completed',
      createdAt: paidAt!,
    );
  }
}

class _OrderViewModel extends SalesViewModel {
  @override
  CurrentOrderState build() => const CurrentOrderState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic>? emittedFiscalDocument;
  final documentQueries = <Uri>[];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final font = FontLoader('RobotoTicket')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await font.load();
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/fiscal_documents') ||
            request.url.path.endsWith('/sales_notes')) {
          documentQueries.add(request.url);
        }
        final document = emittedFiscalDocument;
        final rows =
            request.url.path.endsWith('/fiscal_documents') && document != null
            ? [document]
            : [];
        return http.Response(
          jsonEncode(rows),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    emittedFiscalDocument = null;
    documentQueries.clear();
  });
  tearDownAll(() => Supabase.instance.dispose());

  (
    PaymentSplitViewModel,
    ProviderContainer,
    StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>,
  )
  model({
    String fiscalType = 'B02',
    int limit = 3,
    int count = 0,
    bool enabled = true,
    _Sales? sales,
    String? checkId,
  }) {
    final provider =
        StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
          (ref) => PaymentSplitViewModel(
            sales ?? _Sales(Supabase.instance.client),
            'order',
            100,
            ref: ref,
            initialize: false,
            fiscalType: fiscalType,
            checkId: checkId,
            salesNotePolicy: SalesNotePolicy(
              enabled: enabled,
              notesBeforeInvoice: limit,
              currentCount: count,
            ),
            sessionResolver: ({bool skipLocal = false}) async => 'session',
            connectionStatus: () => true,
          ),
        );
    final container = ProviderContainer(
      overrides: [currentOrderProvider.overrideWith(_OrderViewModel.new)],
    );
    addTearDown(container.dispose);
    return (container.read(provider.notifier), container, provider);
  }

  test('cash consumer final defaults to notes until the configured quota', () {
    final (vm, container, provider) = model(limit: 5, count: 4);
    expect(container.read(provider).salesNoteAvailable, isTrue);
    expect(container.read(provider).salesNoteSelected, isTrue);
    expect(vm.salesNoteCycleMessage, contains('4 de 5'));

    final (dueVm, dueContainer, dueProvider) = model(limit: 5, count: 5);
    expect(dueContainer.read(dueProvider).salesNoteAvailable, isFalse);
    expect(dueContainer.read(dueProvider).salesNoteSelected, isFalse);
    dueVm.setSalesNote(true);
    expect(dueContainer.read(dueProvider).salesNoteSelected, isFalse);
    expect(dueVm.salesNoteCycleMessage, contains('Este cobro será factura'));
  });

  test('credit fiscal and disabled businesses always choose invoice', () {
    for (final type in ['B01', 'E31', '01', '31']) {
      final (vm, container, provider) = model(fiscalType: type);
      vm.setSalesNote(true);
      expect(container.read(provider).salesNoteAvailable, isFalse);
      expect(container.read(provider).salesNoteSelected, isFalse);
      expect(vm.salesNoteCycleMessage, isNull);
    }
    final (_, container, provider) = model(enabled: false);
    expect(container.read(provider).salesNoteAvailable, isFalse);
    expect(container.read(provider).salesNoteSelected, isFalse);
  });

  test('card, transfer, and mixed plans hide notes and cash restores them', () {
    final (vm, container, provider) = model(fiscalType: '32');
    for (final method in [
      PaymentMethodType.card,
      PaymentMethodType.transfer,
      PaymentMethodType.other,
    ]) {
      vm.setMethod(method, presetRemaining: false);
      vm.setSalesNote(true);
      expect(container.read(provider).salesNoteAvailable, isFalse);
      expect(container.read(provider).salesNoteSelected, isFalse);
      vm.setMethod(PaymentMethodType.cash, presetRemaining: false);
      expect(container.read(provider).salesNoteSelected, isTrue);
    }

    vm.setInput('40');
    vm.addTransaction();
    vm.setMethod(PaymentMethodType.card);
    vm.addTransaction();
    expect(container.read(provider).salesNoteAvailable, isFalse);
    expect(container.read(provider).salesNoteSelected, isFalse);

    final cardId = container.read(provider).transactions.last.id;
    vm.setMethod(PaymentMethodType.cash);
    vm.removeTransaction(cardId);
    expect(container.read(provider).salesNoteSelected, isTrue);
    vm.addTransaction();
    // Changing the active tab after fully loading cash does not change the
    // methods of the actual payment plan.
    vm.setMethod(PaymentMethodType.card);
    expect(container.read(provider).salesNoteSelected, isTrue);
  });

  testWidgets('a server-issued invoice overrides the requested sales note', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    emittedFiscalDocument = {
      'id': 'fiscal-document',
      'is_electronic': false,
      'ncf_number': 'B0200000001',
    };
    final sales = _Sales(Supabase.instance.client)
      ..normalizeCheckToOrder = true
      ..fiscalDocumentId = 'fiscal-document';
    final (vm, container, provider) = model(
      count: 2,
      sales: sales,
      checkId: 'primary-check',
    );
    vm.setInput('100');
    vm.addTransaction();
    expect(container.read(provider).salesNoteSelected, isTrue);
    expect(await vm.confirmPayment(context), hasLength(1));
    expect(sales.noteChoices, [true]);
    expect(sales.fiscalTypes, ['B02']);
    expect(container.read(provider).salesNoteSelected, isFalse);
    expect(container.read(provider).emittedNcf, 'B0200000001');
    expect(
      documentQueries
          .singleWhere((uri) => uri.path.endsWith('/sales_notes'))
          .queryParameters['check_id'],
      'is.null',
    );
    final fiscalQuery = documentQueries.singleWhere(
      (uri) => uri.path.endsWith('/fiscal_documents'),
    );
    expect(fiscalQuery.queryParameters['id'], 'eq.fiscal-document');
    expect(fiscalQuery.queryParameters['status'], 'eq.active');
    expect(fiscalQuery.queryParameters, isNot(contains('check_id')));
  });

  for (final width in [500.0, 1400.0]) {
    testWidgets('notes disappear on card at screen width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const key = ('order', 100.0, null, null, 'B02', null);
      late PaymentSplitViewModel vm;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            paymentSplitProvider(key).overrideWith((ref) {
              vm = PaymentSplitViewModel(
                _Sales(Supabase.instance.client),
                'order',
                100,
                ref: ref,
                initialize: false,
                fiscalType: 'B02',
                salesNotePolicy: const SalesNotePolicy(enabled: true),
              );
              return vm;
            }),
          ],
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'RobotoTicket'),
            home: const Scaffold(
              body: PaymentSplitDialog(
                orderId: 'order',
                totalAmount: 100,
                tableName: 'Mesa',
                fiscalType: 'B02',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nota de venta'), findsOneWidget);
      vm.setMethod(PaymentMethodType.card);
      await tester.pumpAndSettle();
      expect(find.text('Nota de venta'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
