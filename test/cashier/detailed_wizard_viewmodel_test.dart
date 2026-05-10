import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/cashier/detailed_wizard/state/detailed_wizard_state.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';

void main() {
  const baseInput = CashCloseInput(
    expectedCash: 0,
    expectedCard: 0,
    expectedTransfer: 0,
    totalSales: 0,
    transactionCount: 0,
    startAmount: 5000,
  );

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('estado inicial: 10 denominaciones, todos en 0, fondo = 5000', () {
    final c = makeContainer();
    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.denominations, hasLength(10));
    expect(state.totalCounted, 0);
    expect(state.input.startAmount, 5000);
    expect(state.shiftCash, -5000);
    expect(state.totalReported, 0);
  });

  test('setDenominationCount calcula subtotal y total contado', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.setDenominationCount(2000, 4); // 8000
    notifier.setDenominationCount(500, 6); // 3000
    notifier.setDenominationCount(25, 12); // 300
    notifier.setDenominationCount(1, 23); // 23

    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.totalCounted, 8000 + 3000 + 300 + 23);
    expect(state.shiftCash, 8000 + 3000 + 300 + 23 - 5000);
  });

  test('setCardInput y setTransferInput parsean decimales y suman', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.setCardInput('1234.50');
    notifier.setTransferInput('800,25'); // coma se normaliza a punto

    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.numericCard, 1234.50);
    expect(state.numericTransfer, 800.25);
    expect(state.totalElectronic, closeTo(2034.75, 0.001));
  });

  test('setCardInput recorta a 2 decimales', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.setCardInput('999.999');
    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.cardInput, '999.99');
  });

  test('setSupervisorNote clipa a 500 caracteres', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.setSupervisorNote('a' * 600);
    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.supervisorNote.length, 500);
  });

  test('snapshot serializa denominaciones excluyendo ceros, una key por valor', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.setDenominationCount(2000, 2);
    notifier.setDenominationCount(100, 3);
    notifier.setDenominationCount(25, 4); // 100
    notifier.setDenominationCount(1, 50);
    notifier.setCardInput('100.00');
    notifier.setTransferInput('50.50');
    notifier.setSupervisorNote('  hola  ');

    final snap = notifier.snapshot();
    expect(snap.cashAmount, 2 * 2000 + 3 * 100 + 4 * 25 + 50);
    expect(snap.cardAmount, 100.00);
    expect(snap.transferAmount, 50.50);
    expect(snap.openingFloat, 5000.0);
    expect(snap.supervisorNote, 'hola');
    expect(snap.denominations, {
      '2000': 2,
      '100': 3,
      '25': 4,
      '1': 50,
    });
  });

  test('snapshot.supervisorNote es null cuando solo hay whitespace', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.setSupervisorNote('   ');
    expect(notifier.snapshot().supervisorNote, isNull);
  });
}
