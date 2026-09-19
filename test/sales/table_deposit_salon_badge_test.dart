import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/data/models/dining_table.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/presentation/sales/widgets/zone_floor_map.dart';

DiningTable _table(String id, String code, {double x = 0}) => DiningTable(
  id: id,
  zoneId: 'zona-1',
  code: code,
  shape: TableShape.square,
  state: TableState.available,
  capacity: 4,
  posX: x,
  posY: 0,
  width: 1,
  height: 1,
  rotation: 0,
  isActive: true,
);

TableStatus _free(String id, String code) => TableStatus(
  tableId: id,
  zoneId: 'zona-1',
  code: code,
  sessionId: null,
  ordersCount: 0,
  minutesOpen: 0,
);

Future<void> _pumpMap(
  WidgetTester tester, {
  Map<String, double> deposits = const {},
}) async {
  final tables = [
    _table('vip-1', 'VIP1'),
    _table('mesa-2', 'M2', x: 3),
  ];
  await tester.pumpWidget(
    ProviderScope(
      // La moneda real sale de la sesión (Supabase). En el test basta con la
      // de respaldo: lo que se prueba es que el badge aparezca.
      overrides: [
        currentBusinessCurrencyProvider.overrideWithValue(
          const AsyncValue.data(BusinessCurrency.fallbackDop),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: ZoneFloorMap(
              tables: tables,
              statusByTableId: {
                for (final t in tables) t.id: _free(t.id, t.code),
              },
              depositByTableId: deposits,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // La cajera no veía el abono "desde afuera": el salón tiene dos vistas y el
  // badge solo estaba en la cuadrícula. El plano se guarda por dispositivo,
  // así que una caja en plano nunca lo veía aunque el dueño sí.
  group('plano del salón: saldo abonado de la mesa', () {
    testWidgets('la mesa con abono muestra su saldo en el plano', (
      tester,
    ) async {
      await _pumpMap(tester, deposits: {'vip-1': 50000});

      expect(find.textContaining('Abono'), findsOneWidget);
      expect(find.textContaining('50,000'), findsOneWidget);
    });

    testWidgets('se ve aunque la mesa esté LIBRE: el saldo es de la mesa', (
      tester,
    ) async {
      // Las dos mesas están libres (sin sesión). Lo que sobró de anoche tiene
      // que verse igual, porque se consume hoy.
      await _pumpMap(tester, deposits: {'vip-1': 12000});

      expect(find.textContaining('12,000'), findsOneWidget);
    });

    testWidgets('solo la mesa con abono lleva badge', (tester) async {
      await _pumpMap(tester, deposits: {'vip-1': 50000});

      // Una sola mesa con saldo → un solo badge, no uno por mesa.
      expect(
        find.byIcon(Icons.account_balance_wallet_outlined),
        findsOneWidget,
      );
    });

    testWidgets('sin abonos el plano se ve como siempre', (tester) async {
      await _pumpMap(tester);

      expect(find.textContaining('Abono'), findsNothing);
      expect(find.byIcon(Icons.account_balance_wallet_outlined), findsNothing);
    });

    testWidgets('un saldo agotado (0) no pinta badge', (tester) async {
      await _pumpMap(tester, deposits: {'vip-1': 0});

      expect(find.textContaining('Abono'), findsNothing);
    });
  });
}
