import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/offline/payment_intent_journal.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/data/models/payment_attempt_lease.dart';
import 'package:mangopos/data/models/bank_account.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/sales_repository_improved.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Servidor falso: registra cada abono (índice + fecha). `dieAt` simula que
/// la app se cierra justo en ese abono (el cobro queda a medias).
class _Sales extends SalesRepositoryImproved {
  _Sales(super.client);
  final calls = <int>[];
  final dates = <DateTime?>[];
  int? dieAt;

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
    calls.add(splitSequence);
    dates.add(paidAt);
    if (dieAt == splitSequence) {
      dieAt = null;
      throw StateError('la app se cerró');
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
    );
  }
}

class _FailingJournal extends PaymentIntentJournal {
  const _FailingJournal();

  @override
  Future<bool> save(PaymentIntent intent) async => false;
}

BankAccount _bank() => BankAccount.fromMap({
  'id': 'bank-1',
  'business_id': 'biz',
  'bank_name': 'Banco Popular',
  'account_number': '123456789',
  'account_type': 'checking',
  'currency': 'DOP',
  'is_active': true,
  'sort_order': 0,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const journal = PaymentIntentJournal();

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

  /// Cada instancia = la app abierta de nuevo (otro contenedor, otro modal).
  ({PaymentSplitViewModel vm, PaymentSplitState Function() state}) openModal(
    _Sales sales,
    String orderId,
    double total, {
    bool Function()? connected,
    Future<void> Function({
      required String businessId,
      required Map<String, dynamic> action,
    })?
    enqueue,
    PaymentIntentJournal intentJournal = const PaymentIntentJournal(),
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
            connectionStatus: connected ?? () => true,
            enqueuePayment: enqueue,
            intentJournal: intentJournal,
          ),
        );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return (
      vm: container.read(provider.notifier),
      state: () => container.read(provider),
    );
  }

  group('diario', () {
    testWidgets('si no se puede guardar el intento, no envía pagos', (
      tester,
    ) async {
      final context = await contextOf(tester);
      final sales = _Sales(Supabase.instance.client);
      final modal = openModal(
        sales,
        'order-storage-full',
        100,
        intentJournal: const _FailingJournal(),
      );
      await tester.pump();
      modal.vm.setInput('100');
      modal.vm.addTransaction();

      expect(await modal.vm.confirmPayment(context), isNull);
      expect(sales.calls, isEmpty);
      expect(modal.state().error, contains('No se pudo guardar'));
    });

    test('guarda y lee el plan completo', () async {
      final paidAt = DateTime.utc(2026, 9, 29, 22, 33);
      await journal.save(
        PaymentIntent(
          attemptId: 'attempt-1',
          orderId: 'order-a',
          checkId: 'check-1',
          businessId: 'biz',
          totalAmount: 100,
          lines: [
            const PaymentIntentLine(method: 'cash', amount: 40),
            PaymentIntentLine(
              method: 'transfer',
              amount: 60,
              reference: 'REF-9',
              bankAccount: _bank(),
            ),
          ],
          paidAt: paidAt,
          createdAt: DateTime.now().toUtc(),
          offline: true,
          offlineNcf: 'B0200000042',
          offlineNcfResolved: true,
          recordedPayments: {
            0: Payment(
              id: 'p-0',
              businessId: 'biz',
              orderId: 'order-a',
              paymentMethodId: 'cash',
              amount: 40,
              changeAmount: 0,
              status: 'completed',
              createdAt: paidAt,
            ),
          },
        ),
      );

      final loaded = await journal.load('order-a', 'check-1');

      expect(loaded, isNotNull);
      expect(loaded!.attemptId, 'attempt-1');
      expect(loaded.paidAt, paidAt);
      expect(loaded.lines.map((l) => l.method), ['cash', 'transfer']);
      expect(loaded.lines.last.bankAccount?.id, 'bank-1');
      expect(loaded.lines.last.reference, 'REF-9');
      expect(loaded.offline, isTrue);
      expect(loaded.offlineNcf, 'B0200000042');
      expect(loaded.recordedPayments.keys, [0]);
      expect(loaded.recordedPayments[0]!.id, 'p-0');
      expect(
        await journal.load('order-a', null),
        isNull,
        reason: 'la cuenta completa y la subcuenta son intentos distintos',
      );
    });

    test('un intento viejo sigue disponible hasta conciliación', () async {
      await journal.save(
        PaymentIntent(
          attemptId: 'old',
          orderId: 'order-old',
          checkId: null,
          totalAmount: 10,
          lines: const [PaymentIntentLine(method: 'cash', amount: 10)],
          paidAt: DateTime.utc(2026, 9, 1),
          createdAt: DateTime.now().toUtc().subtract(const Duration(days: 4)),
        ),
      );

      expect((await journal.load('order-old', null))?.attemptId, 'old');
      final storage = await StorageService.getInstance();
      expect(
        await storage.exists(PaymentIntentJournal.keyFor('order-old', null)),
        isTrue,
      );
    });

    test('un plan ilegible no se restaura a medias', () async {
      final storage = await StorageService.getInstance();
      await storage.writeJson(PaymentIntentJournal.keyFor('order-bad', null), {
        'attempt_id': 'x',
        'order_id': 'order-bad',
        'total_amount': 100,
        'paid_at': DateTime.now().toUtc().toIso8601String(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'lines': [
          {'method': 'cash', 'amount': 40},
          {'method': 'card'}, // sin monto
        ],
      });

      expect(await journal.load('order-bad', null), isNull);
    });

    test('limpieza por negocio respeta los demás', () async {
      PaymentIntent intent(String order, String? biz) => PaymentIntent(
        attemptId: 'a-$order',
        orderId: order,
        checkId: null,
        businessId: biz,
        totalAmount: 1,
        lines: const [PaymentIntentLine(method: 'cash', amount: 1)],
        paidAt: DateTime.now().toUtc(),
        createdAt: DateTime.now().toUtc(),
      );
      await journal.save(intent('o-1', 'biz-a'));
      await journal.save(intent('o-2', 'biz-b'));

      expect(await journal.deleteForBusiness('biz-a'), 1);
      expect(await journal.load('o-1', null), isNull);
      expect(await journal.load('o-2', null), isNotNull);
    });
  });

  group('cobro dividido interrumpido', () {
    testWidgets(
      'reinicio a mitad: retoma el MISMO plan y solo cobra lo que faltaba',
      (tester) async {
        final context = await contextOf(tester);
        final sales = _Sales(Supabase.instance.client)..dieAt = 1;

        final first = openModal(sales, 'order-crash', 100);
        await tester.pump();
        first.vm.setInput('40');
        first.vm.addTransaction();
        first.vm.setMethod(PaymentMethodType.card);
        first.vm.setInput('60');
        first.vm.addTransaction();
        expect(await first.vm.confirmPayment(context), isNull);
        expect(sales.calls, [0, 1]);
        final paidAt = sales.dates.first;

        // La app se reinicia: modal nuevo para la misma cuenta.
        final second = openModal(sales, 'order-crash', 100);
        await tester.pump();
        final restored = second.state();
        expect(restored.transactions.map((t) => t.amount), [40, 60]);
        expect(restored.transactions.map((t) => t.method), [
          PaymentMethodType.cash,
          PaymentMethodType.card,
        ]);
        expect(restored.resumedAttemptNotice, contains('quedó a medias'));

        // El plan está bloqueado: no se puede cambiar lo que ya se cobró.
        second.vm.removeTransaction(restored.transactions.first.id);
        second.vm.setInput('999');
        second.vm.addTransaction();
        expect(second.state().transactions.map((t) => t.amount), [40, 60]);

        final payments = await second.vm.confirmPayment(context);

        expect(payments!.map((p) => p.id), ['payment-0', 'payment-1']);
        expect(sales.calls, [0, 1, 1], reason: 'el abono 0 no se repite');
        expect(sales.dates.last, paidAt, reason: 'misma fecha del cobro');
        expect(await journal.load('order-crash', null), isNull);
        expect(second.state().resumedAttemptNotice, isNull);
      },
    );

    testWidgets('si la cuenta cambió, avisa y no retoma', (tester) async {
      final context = await contextOf(tester);
      final sales = _Sales(Supabase.instance.client)..dieAt = 1;
      final first = openModal(sales, 'order-changed', 100);
      await tester.pump();
      first.vm.setInput('40');
      first.vm.addTransaction();
      first.vm.setInput('60');
      first.vm.addTransaction();
      await first.vm.confirmPayment(context);

      final second = openModal(sales, 'order-changed', 150);
      await tester.pump();

      expect(second.state().transactions, isEmpty);
      expect(second.state().resumedAttemptNotice, contains('150.00'));
      expect(second.state().resumedAttemptNotice, contains('1 de 2'));
      second.vm.setInput('150');
      second.vm.addTransaction();
      expect(second.state().transactions, hasLength(1));
    });

    testWidgets(
      'si el cajero ya armó otro plan, se le muestra el interrumpido en vez de cobrar',
      (tester) async {
        final context = await contextOf(tester);
        final sales = _Sales(Supabase.instance.client)..dieAt = 1;
        final first = openModal(sales, 'order-pending', 100);
        await tester.pump();
        first.vm.setInput('40');
        first.vm.addTransaction();
        first.vm.setInput('60');
        first.vm.addTransaction();
        await first.vm.confirmPayment(context);
        sales.calls.clear();

        final second = openModal(sales, 'order-pending', 100);
        // Toca antes de que termine la lectura del diario.
        second.vm.setMethod(PaymentMethodType.card);
        second.vm.setInput('100');
        second.vm.addTransaction();
        await tester.pump();

        expect(await second.vm.confirmPayment(context), isNull);
        expect(sales.calls, isEmpty, reason: 'no cobra el plan nuevo');
        expect(second.state().transactions.map((t) => t.amount), [40, 60]);

        await second.vm.confirmPayment(context);
        expect(sales.calls, [1]);
      },
    );

    testWidgets(
      'offline: retoma el mismo intento y no vuelve a encolar lo encolado',
      (tester) async {
        final context = await contextOf(tester);
        final sales = _Sales(Supabase.instance.client);
        final queued = <Map<String, dynamic>>[];
        var failSecond = true;
        Future<void> enqueue({
          required String businessId,
          required Map<String, dynamic> action,
        }) async {
          if (action['split_sequence'] == 1 && failSecond) {
            failSecond = false;
            throw StateError('la app se cerró');
          }
          queued.add(action);
        }

        final first = openModal(
          sales,
          'order-offline',
          100,
          connected: () => false,
          enqueue: enqueue,
        );
        await tester.pump();
        first.vm.setInput('40');
        first.vm.addTransaction();
        first.vm.setInput('60');
        first.vm.addTransaction();
        expect(await first.vm.confirmPayment(context), isNull);
        expect(queued.map((a) => a['split_sequence']), [0]);

        final second = openModal(
          sales,
          'order-offline',
          100,
          // Volvió la red, pero un intento offline no se mezcla con online.
          connected: () => true,
          enqueue: enqueue,
        );
        await tester.pump();
        final payments = await second.vm.confirmPayment(context);

        expect(payments, hasLength(2));
        expect(sales.calls, isEmpty);
        expect(queued.map((a) => a['split_sequence']), [0, 1]);
        expect(
          queued[0]['id'].toString().replaceAll(RegExp(r'-\d$'), ''),
          queued[1]['id'].toString().replaceAll(RegExp(r'-\d$'), ''),
          reason: 'mismo attempt_id: la cola deduplica por id',
        );
        expect(queued[0]['paid_at'], queued[1]['paid_at']);
        expect(await journal.load('order-offline', null), isNull);
      },
    );
  });
}
