// Pantalla del reporte de abonos: que pinte nombre, referencia y balance en
// escritorio y en teléfono sin desbordes de layout.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/table_deposit_report.dart';
import 'package:mangopos/data/repositories/reports_repository.dart';
import 'package:mangopos/presentation/reports/view/table_deposits_report_view.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeReportsViewModel extends ReportsViewModel {
  _FakeReportsViewModel(Ref ref, TableDepositReport report)
    : super(
        ReportsRepository(
          // Sin auto-refresh: su timer periódico queda pendiente al terminar
          // el test. Nunca se llama: loadCategory no hace nada.
          SupabaseClient(
            'http://localhost',
            'anon',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
        ),
        ref,
      ) {
    state = state.copyWith(depositsReport: report);
  }

  @override
  Future<void> loadCategory(ReportCategory category) async {}
}

class _FakeSessionController extends SessionController {
  @override
  SessionState build() => const SessionState(activeBusinessId: 'biz-1');
}

final _report = TableDepositReport.build(
  accountRows: [
    {
      'id': 'a1',
      'table_id': 't1',
      'balance': 6500,
      'holder_name': 'Juan Pérez',
      'dining_tables': {
        'code': 'M5',
        'label': 'Mesa 5',
        'zones': {'name': 'Terraza'},
      },
    },
  ],
  movementRows: [
    {
      'id': '1',
      'account_id': 'a1',
      'type': 'deposit',
      'amount': 10000,
      'balance_after': 10000,
      'reference': 'TRX-12345',
      'created_at': '2026-09-19T14:05:00Z',
      'payment_methods': {'name': 'Transferencia'},
    },
    {
      'id': '2',
      'account_id': 'a1',
      'type': 'reversal',
      'amount': 500,
      'balance_after': 10000,
      'created_at': '2026-09-19T19:00:00Z',
    },
    {
      'id': '3',
      'account_id': 'a1',
      'type': 'consumption',
      'amount': -3500,
      'balance_after': 6500,
      'created_at': '2026-09-19T20:00:00Z',
    },
  ],
  from: DateTime(2026, 9, 19),
  to: DateTime(2026, 9, 20),
);

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reportsViewModelProvider.overrideWith(
          (ref) => _FakeReportsViewModel(ref, _report),
        ),
        sessionProvider.overrideWith(_FakeSessionController.new),
      ],
      child: const MaterialApp(home: TableDepositsReportView()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('escritorio: tabla con nombre, referencia y balance', (
    tester,
  ) async {
    // Alto de sobra: el ListView es perezoso y la tabla de movimientos
    // queda debajo del pliegue.
    await _pump(tester, const Size(1400, 2400));
    expect(tester.takeException(), isNull);
    expect(find.text('Juan Pérez'), findsWidgets);
    expect(find.text('TRX-12345'), findsWidgets);
    expect(find.text('Imprimir reporte'), findsOneWidget);
    expect(find.text('Saldos por mesa'), findsOneWidget);
    expect(find.text('Devuelto por anulación'), findsOneWidget);
  });

  testWidgets('tablet POS 1024 px: la tabla de escritorio cabe', (
    tester,
  ) async {
    await _pump(tester, const Size(1024, 2400));
    expect(tester.takeException(), isNull);
    expect(find.text('Devuelto por anulación'), findsOneWidget);
  });

  testWidgets('teléfono: tarjetas apiladas sin desbordes', (tester) async {
    // 470 px sigue siendo teléfono (< 480). Más angosto, el chip de rango del
    // ReportScaffold compartido desborda con la fuente de pruebas (cada
    // glifo mide 1 em) — no es de esta pantalla.
    await _pump(tester, const Size(470, 3200));
    expect(tester.takeException(), isNull);
    expect(find.text('Juan Pérez'), findsWidgets);
    expect(find.text('TRX-12345'), findsWidgets);
    expect(find.text('Devuelto por anulación · Mesa 5'), findsOneWidget);
  });
}
