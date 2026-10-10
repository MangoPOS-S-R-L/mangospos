import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mangopos/data/models/table_status.dart' as data;
import 'package:mangopos/domain/models/ventas_table.dart';
import 'package:mangopos/presentation/sales/view/theme/table_status_style.dart';
import 'package:mangopos/presentation/sales/widgets/review_accounts_badge.dart';
import 'package:mangopos/presentation/sales/widgets/table_card.dart';

/// Cuentas en revisión (20261010_0020) en el salón: el dueño eligió verlas en
/// la MISMA mesa con «2 cuentas · revisar».
void main() {
  Map<String, dynamic> row({Object? reviewCount, Object? reviewTotal}) => {
    'table_id': 't-71',
    'zone_id': 'z-1',
    'code': 'MESA71',
    'session_id': 's-1',
    'orders_count': 2,
    'total': 640,
    'review_orders_count': reviewCount,
    'review_total': reviewTotal,
  };

  group('modelo', () {
    test('lee las columnas nuevas de la vista', () {
      final ts = data.TableStatus.fromMap(
        row(reviewCount: 1, reviewTotal: 300),
      );
      expect(ts.reviewOrdersCount, 1);
      expect(ts.reviewTotal, 300);
    });

    test('numeric como texto también se lee', () {
      final ts = data.TableStatus.fromMap(
        row(reviewCount: '2', reviewTotal: '1341.12'),
      );
      expect(ts.reviewOrdersCount, 2);
      expect(ts.reviewTotal, 1341.12);
    });

    test('sin la migración (columnas ausentes) = 0', () {
      final ts = data.TableStatus.fromMap(row());
      expect(ts.reviewOrdersCount, 0);
      expect(ts.reviewTotal, 0);
    });

    test('una cuenta en revisión nunca deja la mesa «vacía»', () {
      final ts = data.TableStatus(
        tableId: 't',
        zoneId: 'z',
        code: 'MESA1',
        sessionId: 's',
        ordersCount: 0,
        minutesOpen: 5,
        reviewOrdersCount: 1,
      );
      expect(isTableEffectivelyEmpty(ts), isFalse);
      expect(ventasTableFromStatus(ts).status, TableStatus.ocupado);
      expect(ventasTableFromStatus(ts).reviewAccounts, 1);
    });
  });

  group('etiqueta', () {
    VentasTable table({required int review, double? total}) => VentasTable(
      id: 't',
      code: 'MESA4',
      status: TableStatus.ocupado,
      zone: 'z',
      total: total,
      reviewAccounts: review,
    );

    test(
      'cuenta actual con consumo + 1 en revisión: «2 cuentas · revisar»',
      () {
        expect(
          reviewAccountsLabel(table(review: 1, total: 640)),
          '2 cuentas · revisar',
        );
      },
    );

    test('dos en revisión + la actual: «3 cuentas · revisar»', () {
      expect(
        reviewAccountsLabel(table(review: 2, total: 100)),
        '3 cuentas · revisar',
      );
    });

    test('solo queda la de revisión: «Cuenta por revisar»', () {
      expect(reviewAccountsLabel(table(review: 1)), 'Cuenta por revisar');
    });

    test('sin cuentas en revisión: nada', () {
      expect(reviewAccountsLabel(table(review: 0, total: 640)), isEmpty);
    });
  });

  testWidgets('la tarjeta de la mesa muestra la marca', (tester) async {
    // Sin total: el total de la card lee la moneda del negocio (Supabase).
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: TableCard(
                  table: VentasTable(
                    id: 't-71',
                    code: 'MESA71',
                    status: TableStatus.ocupado,
                    zone: 'z',
                    reviewAccounts: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Cuenta por revisar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
