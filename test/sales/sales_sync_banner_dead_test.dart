// Banner de sincronización de Ventas: las operaciones muertas (agotaron sus
// reintentos) no se reintentan solas, así que el banner nunca se pinta «al
// día» mientras existan. Sin snackbar (decisión 4): solo badge y banner.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_queue_status_provider.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/view/sales_shell_view.dart';

class _QueueStatus extends StateNotifier<OfflineQueueStatus>
    implements OfflineQueueStatusController {
  _QueueStatus(super.state);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> pumpBanner(WidgetTester tester, {required int dead}) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            offlineQueueStatusProvider.overrideWith(
              (ref) => _QueueStatus(OfflineQueueStatus(dead: dead)),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: debugSalesSyncBanner(const CurrentOrderState()),
            ),
          ),
        ),
      );

  testWidgets('con operaciones muertas no dice «al día»', (tester) async {
    await pumpBanner(tester, dead: 2);

    expect(find.text('Sincronización al día.'), findsNothing);
    expect(
      find.text('2 operación(es) sin resolver. Revísalas en la cola.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.cloud_done_rounded), findsNothing);
  });

  testWidgets('sin operaciones muertas sigue «al día»', (tester) async {
    await pumpBanner(tester, dead: 0);

    expect(find.text('Sincronización al día.'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_done_rounded), findsOneWidget);
  });
}
