import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/payment_intent_journal.dart';
import 'package:mangopos/data/models/payment_attempt_lease.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository_improved.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Candado de cobro por cuenta entre equipos (20260929_0002).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('repositorio', () {
    late List<http.Request> requests;
    late Future<http.Response> Function(http.Request) handler;
    http.Request? current;

    SalesRepositoryImproved repo() => SalesRepositoryImproved(
      SupabaseClient(
        'http://localhost:54321',
        'test-key',
        httpClient: MockClient((request) {
          requests.add(request);
          current = request;
          return handler(request);
        }),
      ),
    );

    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
      request: current,
    );

    http.Response missing() => json({
      'code': 'PGRST202',
      'message': 'Could not find the function',
      'details': null,
      'hint': null,
    }, 404);

    Map<String, dynamic> paymentRow({int seq = 1}) => {
      'id': 'pay-1',
      'business_id': 'biz',
      'order_id': 'order-1',
      'check_id': null,
      'payment_method_id': 'cash',
      'payment_method_code': 'cash',
      'amount': 60,
      'change_amount': 0,
      'status': 'completed',
      'split_sequence': seq,
      'created_at': '2026-09-29T22:33:08Z',
    };

    Future<Payment> pay(SalesRepositoryImproved r, {String? attemptId}) =>
        r.processPayment(
          orderId: 'order-1',
          paymentMethodId: 'cash',
          amount: 60,
          cashierSessionId: 'session-1',
          splitSequence: 1,
          attemptId: attemptId,
        );

    setUp(() {
      requests = [];
      SalesRepositoryImproved.debugResetAttemptLockProbe();
    });

    test('toma el candado y lee lo cobrado por otros', () async {
      handler = (_) async => json({
        'acquired': true,
        'paid_by_others': 40,
        'next_split_sequence': 1,
      });

      final lease = await repo().acquirePaymentAttempt(
        orderId: 'order-1',
        attemptId: 'attempt-1',
        deviceId: 'caja-1',
        holderLabel: 'Ana',
      );

      expect(lease!.acquired, isTrue);
      expect(lease.paidByOthers, 40);
      expect(lease.nextSplitSequence, 1);
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['p_attempt_id'], 'attempt-1');
      expect(body['p_holder_label'], 'Ana');
    });

    test('migración sin aplicar: no se toma un candado inexistente', () async {
      handler = (_) async => missing();
      final r = repo();
      await expectLater(
        r.acquirePaymentAttempt(orderId: 'o', attemptId: 'a'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        r.acquirePaymentAttempt(orderId: 'o', attemptId: 'a'),
        throwsA(isA<StateError>()),
      );
      expect(requests, hasLength(1));
    });

    test('error de red al tomar el candado: sube como transporte', () async {
      handler = (_) async => throw TimeoutException('sin WAN');

      Object? error;
      try {
        await repo().acquirePaymentAttempt(orderId: 'o', attemptId: 'a');
      } catch (e) {
        error = e;
      }
      expect(OfflinePosService.isTransportError(error!), isTrue);
    });

    test('con attemptId cobra por el envoltorio con candado', () async {
      handler = (_) async => json(paymentRow());

      final payment = await pay(repo(), attemptId: 'attempt-1');

      expect(payment.id, 'pay-1');
      expect(
        requests.single.url.path,
        endsWith('/fn_process_payment_v3_attempt'),
      );
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['p_attempt_id'], 'attempt-1');
      expect(body['p_split_sequence'], 1);
      expect(body['p_amount'], 60);
    });

    test('envoltorio sin aplicar: no se cobra por la RPC insegura', () async {
      handler = (request) async =>
          request.url.path.endsWith('/fn_process_payment_v3_attempt')
          ? missing()
          : json(paymentRow());

      await expectLater(
        pay(repo(), attemptId: 'attempt-1'),
        throwsA(
          predicate((e) => e.toString().contains('migración del candado')),
        ),
      );
      expect(requests.map((r) => r.url.pathSegments.last), [
        'fn_process_payment_v3_attempt',
      ]);
    });

    test('candado ajeno: error claro de que no se cobró', () async {
      handler = (_) async => json({
        'code': 'MP420',
        'message': 'PAYMENT_LOCKED_BY_OTHER_DEVICE',
        'details': 'Ana',
        'hint': 'caja-1',
      }, 400);

      Object? error;
      try {
        await pay(repo(), attemptId: 'attempt-2');
      } catch (e) {
        error = e;
      }
      expect(
        error.toString(),
        contains(SalesRepositoryImproved.paymentLockedCode),
      );
      expect(error.toString(), isNot(contains('No asumas')));
    });
  });

  group('cobro dividido', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
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

    ({PaymentSplitViewModel vm, PaymentSplitState Function() state}) open(
      _LockSales sales,
      String orderId,
      double total, {
      Future<void> Function({
        required String businessId,
        required Map<String, dynamic> action,
      })?
      enqueue,
    }) {
      final provider =
          StateNotifierProvider<PaymentSplitViewModel, PaymentSplitState>(
            (ref) => PaymentSplitViewModel(
              sales,
              orderId,
              total,
              ref: ref,
              initialize: false,
              fiscalType: 'B02',
              sessionResolver: ({bool skipLocal = false}) async => 'session',
              businessResolver: () async => 'biz',
              connectionStatus: () => true,
              enqueuePayment: enqueue,
            ),
          );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      return (
        vm: container.read(provider.notifier),
        state: () => container.read(provider),
      );
    }

    testWidgets('otro equipo cobrando: no se graba nada y dice quién', (
      tester,
    ) async {
      final context = await contextOf(tester);
      final sales = _LockSales(Supabase.instance.client)
        ..leases.add(
          const PaymentAttemptLease(
            acquired: false,
            reason: 'held',
            holderLabel: 'Caja 1',
          ),
        );
      final modal = open(sales, 'order-held', 100);
      await tester.pump();
      modal.vm.setInput('100');
      modal.vm.addTransaction();

      expect(await modal.vm.confirmPayment(context), isNull);

      expect(sales.payments, isEmpty);
      expect(modal.state().error, contains('Caja 1'));
      expect(modal.state().error, contains('no se cobró nada'));
      expect(
        await const PaymentIntentJournal().load('order-held', null),
        isNull,
        reason: 'sin cobro no queda intento bloqueado',
      );
      // El plan sigue editable: nada se grabó.
      modal.vm.removeTransaction(modal.state().transactions.single.id);
      expect(modal.state().transactions, isEmpty);
    });

    testWidgets('cobro anterior a medias en otra PC: cobra solo el restante', (
      tester,
    ) async {
      final context = await contextOf(tester);
      final sales = _LockSales(Supabase.instance.client)
        ..leases.addAll(const [
          PaymentAttemptLease(
            acquired: true,
            paidByOthers: 40,
            nextSplitSequence: 1,
          ),
          PaymentAttemptLease(
            acquired: true,
            paidByOthers: 40,
            nextSplitSequence: 1,
          ),
        ]);
      final modal = open(sales, 'order-partial', 100);
      await tester.pump();
      modal.vm.setInput('100');
      modal.vm.addTransaction();

      expect(await modal.vm.confirmPayment(context), isNull);
      expect(sales.payments, isEmpty);
      expect(sales.released, 1, reason: 'suelta el candado: no grabó nada');
      expect(modal.state().totalAmount, 60);
      expect(modal.state().transactions, isEmpty);
      expect(modal.state().resumedAttemptNotice, contains('40.00'));
      expect(modal.state().resumedAttemptNotice, contains('60.00'));

      modal.vm.setInput('60');
      modal.vm.addTransaction();
      final payments = await modal.vm.confirmPayment(context);

      expect(payments, hasLength(1));
      expect(sales.payments.single.amount, 60);
      expect(
        sales.payments.single.splitSequence,
        1,
        reason: 'no choca con el abono 0 del cobro anterior',
      );
      expect(sales.payments.single.attemptId, isNotNull);
    });

    testWidgets('cuenta ya cobrada: lo dice y no cobra', (tester) async {
      final context = await contextOf(tester);
      final sales = _LockSales(Supabase.instance.client)
        ..leases.add(
          const PaymentAttemptLease(acquired: false, reason: 'closed'),
        );
      final modal = open(sales, 'order-closed', 100);
      await tester.pump();
      modal.vm.setInput('100');
      modal.vm.addTransaction();

      expect(await modal.vm.confirmPayment(context), isNull);
      expect(sales.payments, isEmpty);
      expect(modal.state().error, contains('ya fue cobrada'));
    });

    testWidgets('sin red para tomar el candado: cobra offline como siempre', (
      tester,
    ) async {
      final context = await contextOf(tester);
      final sales = _LockSales(Supabase.instance.client)
        ..acquireError = TimeoutException('sin WAN');
      final queued = <Map<String, dynamic>>[];
      final modal = open(
        sales,
        'order-offline-lock',
        100,
        enqueue: ({required businessId, required action}) async {
          queued.add(action);
        },
      );
      await tester.pump();
      modal.vm.setInput('100');
      modal.vm.addTransaction();

      final payments = await modal.vm.confirmPayment(context);

      expect(payments, hasLength(1));
      expect(sales.payments, isEmpty);
      expect(queued.single['split_sequence'], 0);
      expect(modal.state().offlineQueued, isTrue);
    });

    testWidgets(
      'cobro retomado y otra PC cobró mientras tanto: se bloquea, no recorta',
      (tester) async {
        final context = await contextOf(tester);
        final sales = _LockSales(Supabase.instance.client)
          ..dieAt = 1
          ..leases.addAll(const [
            PaymentAttemptLease(acquired: true, nextSplitSequence: 0),
            PaymentAttemptLease(
              acquired: true,
              paidByOthers: 25,
              nextSplitSequence: 3,
            ),
          ]);
        final first = open(sales, 'order-resumed-lock', 100);
        await tester.pump();
        first.vm.setInput('40');
        first.vm.addTransaction();
        first.vm.setInput('60');
        first.vm.addTransaction();
        expect(await first.vm.confirmPayment(context), isNull);
        expect(sales.payments.map((p) => p.splitSequence), [0]);

        final second = open(sales, 'order-resumed-lock', 100);
        await tester.pump();
        expect(second.state().transactions.map((t) => t.amount), [40, 60]);

        expect(await second.vm.confirmPayment(context), isNull);
        expect(sales.payments, hasLength(1), reason: 'no cobró el abono 1');
        expect(second.state().error, contains('25.00'));
        expect(second.state().transactions.map((t) => t.amount), [40, 60]);
      },
    );

    testWidgets('sin candado disponible no se cobra', (tester) async {
      final context = await contextOf(tester);
      final sales = _LockSales(Supabase.instance.client);
      final modal = open(sales, 'order-no-lock', 100);
      await tester.pump();
      modal.vm.setInput('40');
      modal.vm.addTransaction();
      modal.vm.setInput('60');
      modal.vm.addTransaction();

      final payments = await modal.vm.confirmPayment(context);

      expect(payments, isNull);
      expect(sales.payments, isEmpty);
    });
  });
}

class _RecordedPayment {
  _RecordedPayment(this.amount, this.splitSequence, this.attemptId);
  final double amount;
  final int splitSequence;
  final String? attemptId;
}

class _LockSales extends SalesRepositoryImproved {
  _LockSales(super.client);
  final leases = <PaymentAttemptLease>[];
  Object? acquireError;
  final payments = <_RecordedPayment>[];
  int released = 0;
  int? dieAt;

  @override
  Future<PaymentAttemptLease?> acquirePaymentAttempt({
    required String orderId,
    String? checkId,
    required String attemptId,
    String? deviceId,
    String? holderLabel,
  }) async {
    final error = acquireError;
    if (error != null) throw error;
    if (leases.isEmpty) return null;
    return leases.removeAt(0);
  }

  @override
  Future<void> releasePaymentAttempt({
    required String orderId,
    required String attemptId,
  }) async {
    released++;
  }

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
    if (dieAt == splitSequence) {
      dieAt = null;
      throw StateError('la app se cerró');
    }
    payments.add(_RecordedPayment(amount, splitSequence, attemptId));
    return Payment(
      id: 'payment-$splitSequence',
      businessId: 'biz',
      orderId: orderId,
      checkId: checkId,
      paymentMethodId: paymentMethodId,
      amount: amount,
      changeAmount: changeAmount,
      status: 'completed',
      createdAt: paidAt ?? DateTime.now(),
    );
  }
}
