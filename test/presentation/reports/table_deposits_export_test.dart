// Exportación del reporte de abonos (botones PDF y Excel/CSV de Reportes).
//
// Los nombres y referencias los escribe la gente: un emoji o una letra fuera
// de Latin-1 hace que el paquete `pdf` lance y el botón "no haga nada".

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/table_deposit_report.dart';
import 'package:mangopos/data/repositories/reports_repository.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _report = TableDepositReport.build(
  accountRows: [
    {
      'id': 'a1',
      'table_id': 't1',
      'balance': 6500,
      'holder_name': 'Juan Pérez 🎉 Šimić',
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
      'reference': 'TRX-12345 €',
      'created_at': '2026-09-19T14:05:00Z',
      'payment_methods': {'name': 'Transferencia'},
    },
    {
      'id': '2',
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

void main() {
  late ProviderContainer container;
  late ReportsViewModel viewModel;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        reportsViewModelProvider.overrideWith(
          (ref) => ReportsViewModel(
            ReportsRepository(
              SupabaseClient(
                'http://localhost',
                'anon',
                authOptions: const AuthClientOptions(autoRefreshToken: false),
              ),
            ),
            ref,
          ),
        ),
      ],
    );
    viewModel = container.read(reportsViewModelProvider.notifier);
  });

  tearDown(() => container.dispose());

  ReportsState state() => container
      .read(reportsViewModelProvider)
      .copyWith(depositsReport: _report);

  test('el PDF de abonos se arma aunque el nombre traiga emoji', () async {
    final bytes = await ReportsExportService.buildCurrentReportPdf(
      category: ReportCategory.deposits,
      state: state(),
      viewModel: viewModel,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('el PDF sin datos también se arma', () async {
    final bytes = await ReportsExportService.buildCurrentReportPdf(
      category: ReportCategory.deposits,
      state: container
          .read(reportsViewModelProvider)
          .copyWith(depositsReport: TableDepositReport.empty),
      viewModel: viewModel,
    );
    expect(bytes, isNotEmpty);
  });

  test('el CSV trae nombre, referencia y balance', () {
    final csv = ReportsCsvExportService.buildCsv(
      ReportCategory.deposits,
      state(),
      viewModel,
    );
    expect(csv, contains('Reporte de abonos'));
    expect(csv, contains('Juan Pérez 🎉 Šimić'));
    expect(csv, contains('TRX-12345 €'));
    expect(csv, contains('6500.00'));
    expect(csv, contains('Movimientos del rango'));
  });
}
