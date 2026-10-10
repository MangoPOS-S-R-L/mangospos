import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/data/repositories/order_review_repository.dart';
import 'package:mangopos/presentation/sales/widgets/review_accounts_sheet.dart';

/// Primera carga falla; la siguiente devuelve una cuenta.
class _FlakyRepo extends OrderReviewRepository {
  _FlakyRepo(super.client);
  var calls = 0;

  @override
  Future<List<ReviewAccount>> openReviewAccounts(String sessionId) async {
    calls++;
    if (calls == 1) throw Exception('sin red');
    return [
      ReviewAccount.fromRow({
        'id': 'o-1',
        'review_reason': 'offline_conflict',
        'waiter_name': 'Claudia',
        'table_code': 'MESA71',
        'order_items': [
          {
            'product_name': 'PLATO',
            'quantity': 1,
            'total': 250,
            'status': 'pending',
          },
        ],
      }),
    ];
  }
}

void main() {
  // Fuera de la prueba: el cliente arranca un temporizador de sesión.
  late SupabaseClient client;
  setUpAll(() => client = SupabaseClient('http://localhost:54321', 'test-key'));
  tearDownAll(() => client.dispose());

  testWidgets('recargar la lista no revienta (setState sin Future)', (
    tester,
  ) async {
    final repo = _FlakyRepo(client);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          orderReviewRepositoryProvider.overrideWithValue(repo),
          currentBusinessCurrencyProvider.overrideWithValue(
            const AsyncValue.data(BusinessCurrency.fallbackDop),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ReviewAccountsSheet(
              table: TableStatus(
                tableId: 't-71',
                zoneId: 'z',
                code: 'MESA71',
                sessionId: 's-1',
                ordersCount: 2,
                minutesOpen: 5,
                total: 1920,
                reviewOrdersCount: 1,
              ),
              sessionId: 's-1',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reintentar'), findsOneWidget);

    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(repo.calls, 2);
    expect(find.text('Tomada por Claudia · MESA71'), findsOneWidget);
    expect(find.text('Mover a otra mesa'), findsOneWidget);
  });
}
