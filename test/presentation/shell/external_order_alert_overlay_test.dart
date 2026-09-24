// El aviso de pedido entrante: qué se ve y qué NO se ve.
//
// Importa porque es la única señal que tiene el personal de que entró un pedido
// que nadie digitó. Si la tarjeta no muestra el número o no se puede cerrar,
// el pedido se prepara tarde o el aviso estorba para siempre.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/external_order_alerts.dart';
import 'package:mangopos/presentation/shell/external_order_alert_overlay.dart';

ExternalOrderAlert _alerta({
  required String id,
  String? number,
  String serviceType = 'delivery',
  String? customer,
  double? total,
  bool paid = true,
}) => ExternalOrderAlert(
  id: id,
  channel: 'pincer',
  number: number,
  serviceType: serviceType,
  customerName: customer,
  total: total,
  paid: paid,
  createdAt: DateTime.utc(2026, 9, 24, 18, 30),
);

class _AlertasFijas extends ExternalOrderAlertsNotifier {
  _AlertasFijas(this._inicial);
  final List<ExternalOrderAlert> _inicial;

  // Sin `super.build()`: no queremos timers ni audio en un test de widget.
  @override
  List<ExternalOrderAlert> build() => _inicial;
}

Future<void> _montar(WidgetTester tester, List<ExternalOrderAlert> alertas) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        externalOrderAlertsProvider.overrideWith(() => _AlertasFijas(alertas)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Stack(children: [ExternalOrderAlertOverlay()]),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('sin pedidos no pinta nada', (tester) async {
    await _montar(tester, const []);
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('Pedido nuevo'), findsNothing);
  });

  testWidgets('muestra el número grande, el canal y el cliente', (
    tester,
  ) async {
    await _montar(tester, [
      _alerta(id: 'a', number: '142', customer: 'Juan Pérez', total: 1250),
    ]);

    expect(find.text('Pedido nuevo · Pincer'), findsOneWidget);
    expect(find.text('#142'), findsOneWidget);
    expect(find.text('Juan Pérez'), findsOneWidget);
    expect(find.text('RD\$ 1250.00'), findsOneWidget);
    expect(find.text('Delivery'), findsOneWidget);
    expect(find.text('Pagado'), findsOneWidget);

    // El número es lo que el personal lee de lejos: tiene que ser el texto
    // más grande de la tarjeta.
    final numero = tester.widget<Text>(find.text('#142'));
    expect(numero.style!.fontSize, greaterThanOrEqualTo(24));
  });

  testWidgets('un pedido sin pagar avisa que hay que cobrarlo', (tester) async {
    await _montar(tester, [
      _alerta(id: 'a', number: '143', paid: false, serviceType: 'pickup'),
    ]);
    expect(find.text('Cobrar al entregar'), findsOneWidget);
    expect(find.text('Para llevar'), findsOneWidget);
    expect(find.text('Pagado'), findsNothing);
  });

  testWidgets('cerrar quita SOLO ese aviso', (tester) async {
    await _montar(tester, [
      _alerta(id: 'a', number: '1'),
      _alerta(id: 'b', number: '2'),
    ]);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);

    await tester.tap(find.byTooltip('Descartar aviso').first);
    await tester.pumpAndSettle();

    expect(find.text('#1'), findsNothing);
    expect(find.text('#2'), findsOneWidget);
  });

  testWidgets('con muchos pedidos apila 3 y cuenta el resto', (tester) async {
    await _montar(tester, [
      for (var i = 1; i <= 6; i++) _alerta(id: '$i', number: '$i'),
    ]);

    // Tres visibles, no seis: en hora pico taparían la pantalla de trabajo.
    expect(find.byTooltip('Descartar aviso'), findsNWidgets(3));
    expect(find.text('+3 más · descartar todos'), findsOneWidget);

    await tester.tap(find.text('+3 más · descartar todos'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Descartar aviso'), findsNothing);
  });
}
