// Rendimiento y mermas: la pantalla arma sus piezas sin desbordes (laptop y
// teléfono), un motivo filtra todo y cada insumo abre su ficha.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/yield_state.dart';
import 'package:mangopos/presentation/inventory/view/inventory_yield_view.dart';
import 'package:mangopos/presentation/inventory/viewmodel/yield_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// `SessionController.build()` toca Supabase; la moneda depende de la sesión.
class _Session extends SessionController {
  @override
  SessionState build() => const SessionState();
}

class _FakeYieldVm extends ChangeNotifier implements YieldViewModel {
  _FakeYieldVm(this._state);

  YieldState _state;
  final reasons = <String?>[];

  @override
  YieldState get state => _state;

  @override
  Future<void> init() async {}

  @override
  Future<void> refresh() async {}

  @override
  void setReason(String? reason) {
    reasons.add(reason);
    _state = reason == null || reason == _state.reasonFilter
        ? _state.copyWith(clearReason: true)
        : _state.copyWith(reasonFilter: reason);
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

YieldReport _report() => YieldReport.fromMap({
  'days': 30,
  'items': [
    {
      'item_id': 'pollo',
      'item_name': 'Pechuga de pollo',
      'item_sku': 'P-1',
      'item_unit': 'lb',
      'current_stock': 12,
      'purchased_qty': 40,
      'purchased_value': 6000,
      'consumed_qty': 30,
      'consumed_value': 4500,
      'waste_qty': 4,
      'waste_value': 600,
      'count_adjust_qty': -1,
      'count_adjust_value': -150,
      'waste_by_reason': {
        'expiration': {'qty': 3, 'value': 450, 'count': 2},
        'breakage': {'qty': 1, 'value': 150, 'count': 1},
      },
    },
    {
      'item_id': 'queso',
      'item_name': 'Queso',
      'item_unit': 'lb',
      'purchased_qty': 10,
      'purchased_value': 2000,
      'consumed_qty': 9,
      'consumed_value': 1800,
      'waste_qty': 1,
      'waste_value': 200,
      'waste_by_reason': {
        'breakage': {'qty': 1, 'value': 200, 'count': 1},
      },
    },
  ],
  'by_reason': [
    {'reason': 'expiration', 'qty': 3, 'value': 450, 'count': 2},
    {'reason': 'breakage', 'qty': 2, 'value': 350, 'count': 2},
  ],
  'daily': [
    for (var d = 1; d <= 30; d++)
      {
        'day': '2026-09-${d.toString().padLeft(2, '0')}',
        'consumed_value': 200,
        'waste_value': d.isEven ? 30 : 0,
      },
  ],
});

Future<_FakeYieldVm> _pump(
  WidgetTester tester, {
  required Size size,
  YieldState? state,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final vm = _FakeYieldVm(state ?? YieldState(report: _report()));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        yieldViewModelProvider.overrideWith((ref) => vm),
        sessionProvider.overrideWith(_Session.new),
      ],
      child: const MaterialApp(home: InventoryYieldView()),
    ),
  );
  await tester.pumpAndSettle();
  return vm;
}

void main() {
  testWidgets('laptop: indicadores, gráficos y tabla sin desbordes', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1440, 2600));

    // Rendimiento en dinero: 6300 de producción vs 800 de merma = 89%.
    expect(find.text('89%'), findsOneWidget);
    expect(find.text('Merma por motivo'), findsOneWidget);
    expect(find.text('Merma por día'), findsOneWidget);
    expect(find.text('Insumos con más merma'), findsOneWidget);
    expect(find.text('Detalle por insumo'), findsOneWidget);
    expect(find.text('Diferencias de conteo'), findsOneWidget);
    expect(find.byKey(const ValueKey('yield-row-pollo')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('teléfono: todo apilado, sin desbordes', (tester) async {
    await _pump(tester, size: const Size(360, 4200));
    expect(find.text('Detalle por insumo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tocar un motivo filtra la tabla', (tester) async {
    final vm = await _pump(tester, size: const Size(1440, 2600));

    await tester.tap(find.byKey(const ValueKey('yield-reason-expiration')));
    await tester.pumpAndSettle();

    expect(vm.reasons, ['expiration']);
    // Solo el pollo tuvo merma por vencido.
    expect(find.byKey(const ValueKey('yield-row-pollo')), findsOneWidget);
    expect(find.byKey(const ValueKey('yield-row-queso')), findsNothing);
    expect(find.textContaining('Solo la merma por «Vencido»'), findsOneWidget);

    await tester.tap(find.byKey(const Key('yield-chip-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('yield-row-queso')), findsOneWidget);
  });

  testWidgets('cada insumo abre su ficha con la merma por motivo', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1440, 2600));

    await tester.tap(find.byKey(const ValueKey('yield-row-pollo')));
    await tester.pumpAndSettle();

    final dialog = find.byType(YieldItemDialog);
    expect(dialog, findsOneWidget);
    // 30 de producción vs 4 de merma → 88%.
    expect(
      find.descendant(of: dialog, matching: find.text('88%')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('Vencido')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.text('Merma sobre lo comprado'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('sin la migración lo dice en vez de quedarse en blanco', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(1200, 1000),
      state: const YieldState(missingFunction: true),
    );
    expect(find.textContaining('20260930_0050'), findsOneWidget);
  });

  testWidgets('período sin movimientos', (tester) async {
    await _pump(
      tester,
      size: const Size(1200, 1000),
      state: const YieldState(),
    );
    expect(find.text('Sin movimientos en este período'), findsOneWidget);
  });
}
