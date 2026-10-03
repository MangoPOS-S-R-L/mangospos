// "Dólares en gaveta" del cierre detallado: los US$ contados se convierten a
// RD$ con la tasa del día y se suman al efectivo. Solo aparece si el negocio
// activó la moneda USD en Ajustes → Monedas.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/core/currency/usd_display_settings.dart';
import 'package:mangopos/presentation/cashier/detailed_wizard/state/detailed_wizard_state.dart';
import 'package:mangopos/presentation/cashier/detailed_wizard/steps/step_cash_count.dart';
import 'package:mangopos/presentation/cashier/services/print_service.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es_DO');
  });

  const baseInput = CashCloseInput(
    expectedCash: 24000,
    expectedCard: 0,
    expectedTransfer: 0,
    totalSales: 24000,
    transactionCount: 3,
    startAmount: 2000,
  );

  UsdDisplaySettings usdOn(String rate) => UsdDisplaySettings(
    enabled: true,
    symbol: 'US\$',
    rate: Decimal.parse(rate),
    rateUpdatedAt: null,
    symbolPosition: 'before',
  );

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('sin moneda USD activa el cierre queda solo en RD\$', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.configureUsd(const UsdDisplaySettings.disabled());
    notifier.setDenominationCount(1000, 10);

    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.usdEnabled, isFalse);
    expect(state.usdCount, isNull);
    expect(state.totalCounted, 10000);
    expect(notifier.snapshot().denominations.containsKey('usd'), isFalse);
    expect(notifier.snapshot().usd, isNull);
  });

  test('los dólares se convierten con la tasa y suman al efectivo', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.configureUsd(usdOn('50'));
    notifier.setDenominationCount(1000, 10); // RD$ 10,000
    notifier.setUsdDenominationCount(100, 1); // US$ 100
    notifier.setUsdDenominationCount(50, 2); // US$ 100
    notifier.setUsdDenominationCount(20, 4); // US$ 80

    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.usdRateInput, '50');
    expect(state.usdCount!.totalUsd, 280);
    expect(state.usdInDop, 14000);
    expect(state.pesosCounted, 10000);
    expect(state.totalCounted, 24000);
    expect(state.shiftCash, 22000);
    expect(state.result.totalCounted, 24000);
    expect(state.result.cashDifference, 0);

    final snap = notifier.snapshot();
    expect(snap.cashAmount, 24000);
    expect(snap.denominations['1000'], 10);
    expect(snap.denominations['usd'], {
      'symbol': 'US\$',
      'rate': 50.0,
      'configured_rate': 50.0,
      'counts': {'100': 1, '50': 2, '20': 4},
      'total_usd': 280,
      'total_dop': 14000,
    });
    expect(snap.usd!.totalDop, 14000);
  });

  test('el cajero puede cambiar la tasa del día y queda la de Ajustes', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.configureUsd(usdOn('58.5'));
    notifier.setUsdDenominationCount(100, 1);
    notifier.setUsdRateInput('59,25'); // coma → punto

    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.usdRateInput, '59.25');
    expect(state.usdInDop, 5925);
    final usdJson = notifier.snapshot().denominations['usd'] as Map;
    expect(usdJson['rate'], 59.25);
    expect(usdJson['configured_rate'], 58.5);
  });

  test('redondea al peso sin errores de coma flotante', () {
    // 58.3 × 5 = 291.5 exacto → 292. Con double daría 291.4999…
    final usd = UsdCashCount(
      symbol: 'US\$',
      rate: Decimal.parse('58.3'),
      denominations: const [DenominationCount(value: 5, label: '', count: 1)],
    );
    expect(usd.totalDop, 292);
  });

  test('dólares sin tasa: no convierte y marca la tasa como faltante', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.configureUsd(usdOn('50'));
    notifier.setUsdRateInput('');
    expect(c.read(detailedWizardProvider(baseInput)).usdMissingRate, isFalse);

    notifier.setUsdDenominationCount(20, 1);
    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.usdMissingRate, isTrue);
    expect(state.usdInDop, 0);
  });

  test('volver a contar limpia los dólares y repone la tasa de Ajustes', () {
    final c = makeContainer();
    final notifier = c.read(detailedWizardProvider(baseInput).notifier);
    notifier.configureUsd(usdOn('50'));
    notifier.setUsdDenominationCount(100, 3);
    notifier.setUsdRateInput('61');
    notifier.resetCounts();

    final state = c.read(detailedWizardProvider(baseInput));
    expect(state.usdEnabled, isTrue);
    expect(state.usdRateInput, '50');
    expect(state.usdCount!.totalUsd, 0);
    expect(notifier.snapshot().denominations.containsKey('usd'), isFalse);
  });

  test('el JSONB guardado se lee de vuelta para la reimpresión', () {
    final original = UsdCashCount(
      symbol: 'US\$',
      rate: Decimal.parse('50'),
      configuredRate: Decimal.parse('50'),
      denominations: const [
        DenominationCount(value: 100, label: '', count: 1),
        DenominationCount(value: 20, label: '', count: 4),
        DenominationCount(value: 1, label: '', count: 0),
      ],
    );
    final back = UsdCashCount.fromJson(original.toJson())!;
    expect(back.totalUsd, 180);
    expect(back.totalDop, 9000);
    expect(back.denominations.map((d) => d.value), [100, 20]);
    expect(UsdCashCount.fromJson(null), isNull);
    expect(UsdCashCount.fromJson({'rate': 50, 'counts': {}}), isNull);
  });

  group('ticket de cierre', () {
    final service = CashClosePrintService(
      SupabaseClient('https://example.supabase.co', 'anon-key'),
    );
    const result = CashCloseResult(
      totalCounted: 24000,
      numericCard: 0,
      numericTransfer: 0,
      totalReported: 24000,
      expectedTotal: 24000,
      cashDifference: 0,
      cardDifference: 0,
      transferDifference: 0,
      totalDifference: 0,
    );
    const denominations = [
      DenominationCount(value: 1000, label: '', count: 10),
    ];
    final usd = UsdCashCount(
      symbol: 'US\$',
      rate: Decimal.parse('50'),
      denominations: const [
        DenominationCount(value: 100, label: '', count: 1),
        DenominationCount(value: 50, label: '', count: 2),
        DenominationCount(value: 20, label: '', count: 4),
      ],
    );
    final printedAt = DateTime(2026, 10, 3, 23, 0);

    test('imprime los dólares y el efectivo en pesos aparte', () {
      final text = service
          .buildEscPos(
            input: baseInput,
            result: result,
            denominations: denominations,
            usdCount: usd,
            printedAt: printedAt,
          )
          .plainText;
      expect(text, contains('DOLARES (tasa RD\$ 50.00)'));
      expect(text, contains('US\$ 20 x 4'));
      expect(text, contains('US\$ 280.00'));
      expect(text, contains('RD\$ 14,000'));
      expect(text, contains('RD\$ 10,000'));
      expect(text, contains('RD\$ 24,000'));
    });

    test('sin dólares el ticket sale igual que antes', () {
      String build(UsdCashCount? u) => service
          .buildEscPos(
            input: baseInput,
            result: result,
            denominations: denominations,
            usdCount: u,
            printedAt: printedAt,
          )
          .plainText;
      final empty = UsdCashCount(
        symbol: 'US\$',
        rate: Decimal.parse('50'),
        denominations: const [],
      );
      expect(build(null), isNot(contains('DOLARES')));
      expect(build(empty), build(null));
    });
  });

  group('paso Efectivo', () {
    Future<ProviderContainer> pumpStep(
      WidgetTester tester, {
      required double width,
      UsdDisplaySettings? usd,
    }) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final c = makeContainer();
      // autoDispose: lo mantenemos vivo mientras se configura.
      final sub = c.listen(detailedWizardProvider(baseInput), (_, _) {});
      addTearDown(sub.close);
      if (usd != null) {
        c.read(detailedWizardProvider(baseInput).notifier).configureUsd(usd);
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(body: StepCashCount(input: baseInput)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('sin USD activo no aparece la sección de dólares', (
      tester,
    ) async {
      await pumpStep(tester, width: 720);
      expect(find.text('Dólares en gaveta'), findsNothing);
      expect(find.text('TOTAL EFECTIVO CONTADO'), findsNothing);
    });

    // 720 = ancho máximo del diálogo; 560 = tablet angosta. (La fuente de
    // prueba tiene glifos cuadrados y exagera los anchos.)
    for (final width in [720.0, 560.0]) {
      testWidgets('con USD activo se cuenta y suma a ${width.toInt()} px', (
        tester,
      ) async {
        final c = await pumpStep(tester, width: width, usd: usdOn('50'));
        expect(find.text('Dólares en gaveta'), findsOneWidget);
        expect(find.text('TASA DEL DÍA'), findsOneWidget);
        expect(find.text('US\$ 100'), findsOneWidget);

        final notifier = c.read(detailedWizardProvider(baseInput).notifier);
        notifier.setDenominationCount(1000, 10);
        notifier.setUsdDenominationCount(100, 1);
        notifier.setUsdDenominationCount(50, 2);
        notifier.setUsdDenominationCount(20, 4);
        await tester.pumpAndSettle();

        expect(find.text('US\$ 280.00'), findsOneWidget);
        expect(find.text('≈ RD\$ 14,000.00'), findsOneWidget);
        expect(find.text('RD\$ 24,000.00'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
