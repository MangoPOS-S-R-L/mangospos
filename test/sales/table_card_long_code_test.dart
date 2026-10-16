import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/domain/models/ventas_table.dart';
import 'package:mangopos/presentation/sales/widgets/table_card.dart';

/// Nombres de mesa largos («ÁREA EXTERIOR - MESA 1», El Nido 16-oct): el nombre
/// se pintaba fuera de la card y el número quedaba cortado o encima de la card
/// vecina. El nombre entero tiene que quedar DENTRO de la card, con el número
/// visible, también con el total de una mesa ocupada al lado.
void main() {
  const code = 'ÁREA EXTERIOR - MESA 1';

  Future<void> pumpCard(WidgetTester tester, VentasTable table) async {
    await tester.pumpWidget(
      ProviderScope(
        // La moneda real sale de la sesión (Supabase); el total solo necesita
        // la de respaldo para pintarse.
        overrides: [
          currentBusinessCurrencyProvider.overrideWithValue(
            const AsyncValue.data(BusinessCurrency.fallbackDop),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: kTableCardMinWidth,
                child: TableCard(table: table),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void expectInsideCard(WidgetTester tester, Finder finder) {
    final card = tester.getRect(find.byType(TableCard));
    final rect = tester.getRect(finder);
    expect(rect.left, greaterThanOrEqualTo(card.left));
    expect(rect.right, lessThanOrEqualTo(card.right));
  }

  testWidgets('disponible · el nombre largo entra completo en la card', (
    tester,
  ) async {
    await pumpCard(
      tester,
      const VentasTable(
        id: 't',
        code: code,
        status: TableStatus.disponible,
        zone: 'z',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(code), findsOneWidget);
    expectInsideCard(tester, find.text(code));
  });

  testWidgets('ocupada · nombre largo y total sin pisarse', (tester) async {
    await pumpCard(
      tester,
      const VentasTable(
        id: 't',
        code: code,
        status: TableStatus.ocupado,
        zone: 'z',
        total: 3468.8,
        waiterId: 's1',
        waiterName: 'Luis',
        time: '04:32 PM',
      ),
    );

    expect(tester.takeException(), isNull);
    final name = find.text(code);
    final total = find.textContaining('3,469');
    expect(name, findsOneWidget);
    expect(total, findsOneWidget);
    expectInsideCard(tester, name);
    expectInsideCard(tester, total);
    expect(
      tester.getRect(name).right,
      lessThanOrEqualTo(tester.getRect(total).left),
    );
  });

  testWidgets('nombre corto · sigue a su tamaño de siempre', (tester) async {
    await pumpCard(
      tester,
      const VentasTable(
        id: 't',
        code: 'M1',
        status: TableStatus.disponible,
        zone: 'z',
      ),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.text('M1')).height, 28);
  });
}
