// Ajustes → Historial: que pinte las frases, abra lo borrado, filtre por área
// y no se desborde en teléfono ni en escritorio.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/data/models/change_history_entry.dart';
import 'package:mangopos/data/repositories/change_history_repository.dart';
import 'package:mangopos/presentation/settings/history/view/change_history_view.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRepository extends ChangeHistoryRepository {
  _FakeRepository(this.rows)
    : super(
        SupabaseClient(
          'http://localhost',
          'anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  final List<Map<String, dynamic>> rows;
  final calls = <List<String>>[];

  @override
  Future<List<ChangeHistoryEntry>> loadPage({
    required String businessId,
    int offset = 0,
    List<String> tables = const [],
    String? action,
    String search = '',
  }) async {
    calls.add(tables);
    return rows
        .where((r) => tables.isEmpty || tables.contains(r['table_name']))
        .map(ChangeHistoryEntry.fromJson)
        .toList(growable: false);
  }
}

class _FakeSessionController extends SessionController {
  @override
  SessionState build() => const SessionState(activeBusinessId: 'biz-1');
}

final _now = DateTime.now().toUtc();
String _ago(Duration d) => _now.subtract(d).toIso8601String();

final _rows = <Map<String, dynamic>>[
  {
    'id': 4,
    'table_name': 'cash_transactions',
    'row_id': 'c1',
    'action': 'create',
    'label': 'Caja 1',
    'context': 'Fondo para cambio',
    'actor_name': 'Juan Pérez',
    'changed_at': _ago(const Duration(minutes: 2)),
    'changes': {
      'event': 'cash_deposit',
      'amount': 500,
      'reason': 'Fondo para cambio',
      'approved_by': 'Luis Admin',
    },
  },
  {
    'id': 3,
    'table_name': 'menu_items',
    'row_id': 'p1',
    'action': 'update',
    'label': 'Johnnie Walker 18',
    'context': '',
    'actor_name': 'Luis Admin',
    'changed_at': _ago(const Duration(minutes: 5)),
    'changes': {
      'price': [24000, 26000],
    },
  },
  {
    'id': 2,
    'table_name': 'order_items',
    'row_id': 'i1',
    'action': 'delete',
    'label': 'Don Julio Reposado',
    'context': 'MUEBLE16',
    'actor_name': 'Juan Pérez',
    'changed_at': _ago(const Duration(minutes: 30)),
    'changes': {
      'quantity': 1,
      'unit_price': 12000,
      'reason': 'Cliente cambió de idea',
    },
  },
];

Future<_FakeRepository> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _FakeRepository(_rows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        changeHistoryRepositoryProvider.overrideWithValue(repo),
        sessionProvider.overrideWith(_FakeSessionController.new),
        currentBusinessCurrencyProvider.overrideWithValue(
          const AsyncValue.data(BusinessCurrency.fallbackDop),
        ),
      ],
      child: const MaterialApp(home: ChangeHistoryView()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  for (final (name, size) in [
    ('teléfono', const Size(390, 1600)),
    ('escritorio', const Size(1400, 1600)),
  ]) {
    testWidgets('$name: frases, detalles y filtro por área', (tester) async {
      final repo = await _pump(tester, size);

      expect(find.text('HOY'), findsOneWidget);
      expect(find.textContaining('Juan Pérez agregó'), findsOneWidget);
      expect(find.textContaining('a Caja 1'), findsOneWidget);
      expect(
        find.text('Luis Admin editó el producto Johnnie Walker 18'),
        findsOneWidget,
      );
      // La edición se ve abierta: antes → después.
      expect(find.textContaining('26,000', findRichText: true), findsOneWidget);
      // Lo borrado se abre al tocar.
      expect(
        find.text('Juan Pérez quitó Don Julio Reposado de MUEBLE16'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cliente cambió de idea', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('Ver lo que se borró'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Cliente cambió de idea', findRichText: true),
        findsOneWidget,
      );

      // Filtro «Caja»: pide solo las tablas de caja.
      await tester.tap(find.widgetWithText(ChoiceChip, 'Caja'));
      await tester.pumpAndSettle();
      expect(repo.calls.last, contains('cash_transactions'));
      expect(repo.calls.last, isNot(contains('menu_items')));
      expect(find.textContaining('Luis Admin editó'), findsNothing);
      expect(find.textContaining('Juan Pérez agregó'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
