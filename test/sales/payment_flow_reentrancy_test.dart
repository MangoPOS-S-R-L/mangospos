import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/state/payment_flow_provider.dart';

void main() {
  testWidgets(
    'cinco taps comparten un cobro durante preparación, modal y postpago',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final probe = _PaymentFlowProbe();
      await tester.pumpWidget(_PaymentFlowHarness(container, probe));

      // Simula un callback de otra vista que todavía no se ha reconstruido.
      final otherEntry = tester
          .widget<TextButton>(find.byKey(const Key('pay-quick')))
          .onPressed!;

      // No hay pump entre taps: deshabilitar el botón en el siguiente frame
      // por sí solo no evita que se preparen varios modales.
      for (final source in ['table', 'quick', 'table', 'quick', 'table']) {
        await tester.tap(find.byKey(Key('pay-$source')));
      }
      expect(probe.startedSources, ['table']);
      expect(container.read(paymentFlowProvider), isTrue);
      expect(probe.dialogsOpened, 0);

      await tester.pump();
      _expectPaymentEntriesEnabled(tester, false);
      probe.attempt.preparation.complete();
      await tester.pumpAndSettle();
      expect(probe.dialogsOpened, 1);
      expect(_paymentDialogs, findsOneWidget);

      // El cajero puede dejar abierto el cobro mucho tiempo. El bloqueo no
      // vence por un temporizador mientras el modal sigue esperando.
      await tester.pump(const Duration(hours: 1));
      otherEntry();
      await tester.pump();
      expect(probe.startedSources, ['table']);
      expect(_paymentDialogs, findsOneWidget);

      await tester.tap(find.text('Confirmar pago'));
      await tester.pump();
      expect(probe.paymentStarts, 1);
      otherEntry();
      await tester.pump();
      expect(probe.dialogsOpened, 1);
      expect(container.read(paymentFlowProvider), isTrue);

      probe.attempt.payment.complete();
      await tester.pumpAndSettle();
      expect(_paymentDialogs, findsNothing);
      expect(probe.postPayments, 1);
      expect(container.read(paymentFlowProvider), isTrue);
      _expectPaymentEntriesEnabled(tester, false);
      otherEntry();
      await tester.pump();
      expect(probe.startedSources, ['table']);

      probe.attempt.postPayment.complete();
      await tester.pumpAndSettle();
      expect(probe.completedPayments, 1);
      expect(container.read(paymentFlowProvider), isFalse);
      _expectPaymentEntriesEnabled(tester, true);
    },
  );

  testWidgets('cancelar o cerrar permite reabrir sin modales detrás', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final probe = _PaymentFlowProbe();
    await tester.pumpWidget(_PaymentFlowHarness(container, probe));

    await tester.tap(find.byKey(const Key('pay-table')));
    probe.attempt.preparation.complete();
    await tester.pumpAndSettle();
    expect(_paymentDialogs, findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(_paymentDialogs, findsNothing);
    expect(container.read(paymentFlowProvider), isFalse);
    _expectPaymentEntriesEnabled(tester, true);

    probe.attempt = _PaymentAttempt();
    for (final source in ['quick', 'table', 'quick', 'table', 'quick']) {
      await tester.tap(find.byKey(Key('pay-$source')));
    }
    expect(probe.startedSources, ['table', 'quick']);
    probe.attempt.preparation.complete();
    await tester.pumpAndSettle();
    expect(probe.dialogsOpened, 2);
    expect(_paymentDialogs, findsOneWidget);

    // Cerrar mediante la barrera también resuelve el flujo y su bloqueo.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_paymentDialogs, findsNothing);
    expect(container.read(paymentFlowProvider), isFalse);
    expect(probe.paymentStarts, 0);
    expect(probe.postPayments, 0);
    _expectPaymentEntriesEnabled(tester, true);

    probe.attempt = _PaymentAttempt();
    await tester.tap(find.byKey(const Key('pay-table')));
    probe.attempt.preparation.complete();
    await tester.pumpAndSettle();
    expect(probe.dialogsOpened, 3);
    expect(_paymentDialogs, findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(_paymentDialogs, findsNothing);
    expect(container.read(paymentFlowProvider), isFalse);
  });

  test('retorno temprano antes del modal permite un nuevo intento', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(paymentFlowProvider.notifier);
    var attempts = 0;

    await controller.run(() async {
      attempts++;
      return; // Cuenta sin saldo, vista desmontada o preparación cancelada.
    });
    expect(container.read(paymentFlowProvider), isFalse);
    await controller.run(() async {
      attempts++;
    });
    expect(attempts, 2);
    expect(container.read(paymentFlowProvider), isFalse);
  });

  test(
    'errores síncronos y asíncronos liberan el flujo para reintentar',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(paymentFlowProvider.notifier);

      await expectLater(
        controller.run(() => throw StateError('falló la preparación')),
        throwsStateError,
      );
      expect(container.read(paymentFlowProvider), isFalse);

      final preparation = Completer<void>();
      final running = controller.run(() => preparation.future);
      expect(container.read(paymentFlowProvider), isTrue);
      final failed = expectLater(running, throwsStateError);
      preparation.completeError(StateError('falló el cobro'));
      await failed;
      expect(container.read(paymentFlowProvider), isFalse);

      var retried = false;
      await controller.run(() async {
        retried = true;
      });
      expect(retried, isTrue);
      expect(container.read(paymentFlowProvider), isFalse);
    },
  );
}

Finder get _paymentDialogs =>
    find.byKey(const Key('payment-dialog'), skipOffstage: false);

void _expectPaymentEntriesEnabled(WidgetTester tester, bool enabled) {
  for (final source in ['table', 'quick']) {
    final button = tester.widget<TextButton>(find.byKey(Key('pay-$source')));
    expect(button.onPressed, enabled ? isNotNull : isNull);
  }
}

class _PaymentAttempt {
  final preparation = Completer<void>();
  final payment = Completer<void>();
  final postPayment = Completer<void>();
}

class _PaymentFlowProbe {
  _PaymentAttempt attempt = _PaymentAttempt();
  final startedSources = <String>[];
  int dialogsOpened = 0;
  int paymentStarts = 0;
  int postPayments = 0;
  int completedPayments = 0;
}

class _PaymentFlowHarness extends StatelessWidget {
  const _PaymentFlowHarness(this.container, this.probe);

  final ProviderContainer container;
  final _PaymentFlowProbe probe;

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            _PaymentEntry(source: 'table', probe: probe),
            _PaymentEntry(source: 'quick', probe: probe),
          ],
        ),
      ),
    ),
  );
}

class _PaymentEntry extends ConsumerWidget {
  const _PaymentEntry({required this.source, required this.probe});

  final String source;
  final _PaymentFlowProbe probe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(paymentFlowProvider);
    return TextButton(
      key: Key('pay-$source'),
      onPressed: busy
          ? null
          : () => unawaited(
              ref.read(paymentFlowProvider.notifier).run(() async {
                final attempt = probe.attempt;
                probe.startedSources.add(source);
                await attempt.preparation.future;
                if (!context.mounted) return;
                probe.dialogsOpened++;
                final paid = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    key: const Key('payment-dialog'),
                    title: const Text('Pago'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: const Text('Cancelar'),
                      ),
                      TextButton(
                        onPressed: () async {
                          probe.paymentStarts++;
                          await attempt.payment.future;
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop(true);
                          }
                        },
                        child: const Text('Confirmar pago'),
                      ),
                    ],
                  ),
                );
                if (paid != true) return;
                probe.postPayments++;
                await attempt.postPayment.future;
                probe.completedPayments++;
              }),
            ),
      child: Text('Pagar $source'),
    );
  }
}
