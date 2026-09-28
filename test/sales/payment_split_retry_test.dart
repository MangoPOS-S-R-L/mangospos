import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/fiscal/payment_stage.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository_improved.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';
import 'package:mangopos/presentation/sales/view/payment_split_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Sales extends SalesRepositoryImproved {
  _Sales(super.client);
  final calls = <int>[];
  final dates = <DateTime?>[];
  bool failSecond = false;
  Completer<void>? gate;

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
  }) async {
    calls.add(splitSequence);
    dates.add(paidAt);
    await gate?.future;
    if (failSecond && splitSequence == 1) {
      failSecond = false;
      throw TimeoutException('response lost');
    }
    return Payment(
      id: 'payment-$splitSequence',
      businessId: 'biz',
      orderId: orderId,
      checkId: checkId,
      paymentMethodId: paymentMethodId,
      amount: amount,
      changeAmount: changeAmount,
      status: 'completed',
      createdAt: paidAt!,
      reference: reference,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final font = FontLoader('RobotoTicket')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await font.load();
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient(
        (request) async => http.Response(
          '[]',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  Future<BuildContext> contextOf(WidgetTester tester) async {
    late BuildContext result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            result = context;
            return const SizedBox();
          },
        ),
      ),
    );
    return result;
  }

  testWidgets(
    'Escape cannot cancel a pending payment; callback failure returns the payment',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = Completer<void>();
      final sales = _Sales(Supabase.instance.client)..gate = gate;
      const key = ('order', 0.0, null, null, 'B02', null);
      Object? result;
      var hooks = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            paymentSplitProvider(key).overrideWith((ref) {
              final vm = PaymentSplitViewModel(
                sales,
                'order',
                0,
                ref: ref,
                initialize: false,
                fiscalType: 'B02',
                sessionResolver: ({bool skipLocal = false}) async => 'session',
                connectionStatus: () => true,
              );
              vm.setSalesNote(true);
              return vm;
            }),
          ],
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'RobotoTicket'),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<Object>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => PaymentSplitDialog(
                      orderId: 'order',
                      totalAmount: 0,
                      tableName: 'Mesa',
                      fiscalType: 'B02',
                      onConfirmed: (payments, {offlineNcf}) async {
                        hooks++;
                        throw StateError('printer unavailable');
                      },
                    ),
                  );
                },
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PaymentSplitDialog), findsOneWidget);
      expect(result, isNull);
      gate.complete();
      // The payment spinner remains active underneath the error dialog.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Pago registrado'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();
      expect(result, isA<List<Payment>>());
      expect(hooks, 1);
      expect(sales.calls, [0]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial server failure retries only the missing split', (
    tester,
  ) async {
    final context = await contextOf(tester);
    final sales = _Sales(Supabase.instance.client)..failSecond = true;
    final provider =
        StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
          (ref) => PaymentSplitViewModel(
            sales,
            'order',
            100,
            ref: ref,
            initialize: false,
            fiscalType: 'B02',
            sessionResolver: ({bool skipLocal = false}) async => 'session',
            connectionStatus: () => true,
          ),
        );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final vm = container.read(provider.notifier);
    vm.setSalesNote(true);
    vm.setInput('40');
    vm.addTransaction();
    vm.setInput('60');
    vm.addTransaction();
    final firstId = container.read(provider).transactions.first.id;
    expect(await vm.confirmPayment(context), isNull);
    vm.removeTransaction(firstId);
    vm.setInput('999');
    vm.setSalesNote(false);
    expect(container.read(provider).transactions.length, 2);
    expect(container.read(provider).salesNoteSelected, isTrue);
    final payments = await vm.confirmPayment(context);
    expect(sales.calls, [0, 1, 1]);
    expect(sales.dates.toSet().length, 1);
    expect(payments!.map((p) => p.id), ['payment-0', 'payment-1']);
    vm.setPrinting(false);
    expect(container.read(provider).stage, PaymentStage.listo);
    expect(await vm.confirmPayment(context), isNull);
    expect(sales.calls, [0, 1, 1]);
  });

  testWidgets('double confirmation and edits are blocked during the write', (
    tester,
  ) async {
    final context = await contextOf(tester);
    final gate = Completer<void>();
    final sales = _Sales(Supabase.instance.client)..gate = gate;
    final provider =
        StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
          (ref) => PaymentSplitViewModel(
            sales,
            'order',
            100,
            ref: ref,
            initialize: false,
            fiscalType: 'B02',
            sessionResolver: ({bool skipLocal = false}) async => 'session',
            connectionStatus: () => true,
          ),
        );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final vm = container.read(provider.notifier);
    vm.setSalesNote(true);
    vm.setInput('100');
    vm.addTransaction();
    final pending = vm.confirmPayment(context);
    expect(await vm.confirmPayment(context), isNull);
    vm.removeTransaction(container.read(provider).transactions.single.id);
    vm.setMethod(PaymentMethodType.card);
    expect(container.read(provider).transactions.single.amount, 100);
    expect(container.read(provider).activeMethod, PaymentMethodType.cash);
    gate.complete();
    expect(await pending, hasLength(1));
    expect(sales.calls, [0]);
  });

  testWidgets(
    'offline partial write keeps operation IDs and stays offline on retry',
    (tester) async {
      final context = await contextOf(tester);
      final sales = _Sales(Supabase.instance.client);
      final attempts = <Map<String, dynamic>>[];
      var connected = false;
      var fail = true;
      final provider =
          StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
            (ref) => PaymentSplitViewModel(
              sales,
              'order',
              100,
              ref: ref,
              initialize: false,
              fiscalType: 'B02',
              sessionResolver: ({bool skipLocal = false}) async => 'session',
              businessResolver: () async => 'biz',
              connectionStatus: () => connected,
              enqueuePayment: ({required businessId, required action}) async {
                attempts.add(Map<String, dynamic>.from(action));
                if (action['split_sequence'] == 1 && fail) {
                  fail = false;
                  throw StateError('disk unavailable');
                }
              },
            ),
          );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final vm = container.read(provider.notifier);
      vm.setSalesNote(true);
      vm.setInput('40');
      vm.addTransaction();
      vm.setInput('60');
      vm.addTransaction();
      expect(await vm.confirmPayment(context), isNull);
      expect(container.read(provider).isBusy, isFalse);
      expect(sales.calls, isEmpty);
      connected = true;
      final payments = await vm.confirmPayment(context);
      expect(payments, hasLength(2));
      expect(attempts.map((a) => a['split_sequence']), [0, 1, 1]);
      expect(attempts[1]['id'], attempts[2]['id']);
      expect(attempts.map((a) => a['paid_at']).toSet().length, 1);
      expect(attempts.first['close_order'], isFalse);
      expect(attempts.last['close_order'], isTrue);
      expect(container.read(provider).offlineQueued, isTrue);
      expect(sales.calls, isEmpty);
    },
  );
}
