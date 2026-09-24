// La tarjeta de Ajustes → Integraciones.
//
// Lo que se prueba es lo que el dueño ve y decide: si está conectado o no, el
// código para dárselo al canal, y que nunca aparezca una llave en pantalla.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/channel_link_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/integrations/view/channel_link_card.dart';

const _biz = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da';

Future<void> _montar(WidgetTester tester, ChannelLinkStatus status) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        channelLinkStatusProvider((
          businessId: _biz,
          channel: 'pincer',
        )).overrideWith((ref) async => status),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ChannelLinkCard(businessId: _biz)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sin conectar invita a conectar', (tester) async {
    await _montar(tester, ChannelLinkStatus.desconectado);

    expect(find.text('Pincer'), findsOneWidget);
    expect(find.text('Conectar'), findsOneWidget);
    expect(find.text('Desconectar'), findsNothing);
    expect(
      find.text('Recibe los pedidos en línea directo en el POS'),
      findsOneWidget,
    );
  });

  testWidgets('con código vivo lo muestra grande y dice que vence', (
    tester,
  ) async {
    await _montar(
      tester,
      ChannelLinkStatus(
        connected: false,
        pendingCode: 'ABCD-2345',
        pendingCodeExpiresAt: DateTime.now().add(const Duration(minutes: 12)),
      ),
    );

    expect(find.text('Dale este código a Pincer'), findsOneWidget);
    expect(find.text('ABCD-2345'), findsOneWidget);
    expect(find.textContaining('vence en 11 min'), findsOneWidget);
    expect(find.textContaining('Solo sirve una vez'), findsOneWidget);

    // Se lee de lejos y se dicta por teléfono: tiene que ser grande.
    // Por tipo y no por texto: `find.text` cae en el EditableText interno.
    final codigo = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(codigo.style!.fontSize, greaterThanOrEqualTo(24));
  });

  testWidgets('un código vencido lo dice y no deja copiarlo', (tester) async {
    await _montar(
      tester,
      ChannelLinkStatus(
        connected: false,
        pendingCode: 'WXYZ-7788',
        pendingCodeExpiresAt: DateTime.now().subtract(
          const Duration(minutes: 1),
        ),
      ),
    );

    expect(find.text('Este código venció. Genera otro.'), findsOneWidget);
    // Por el ícono y no por el tooltip: Flutter no monta el Tooltip cuando el
    // botón está deshabilitado, así que byTooltip no encuentra nada.
    final copiar = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.copy_rounded),
    );
    expect(copiar.onPressed, isNull);
  });

  testWidgets('conectado muestra actividad y permite desconectar', (
    tester,
  ) async {
    await _montar(
      tester,
      ChannelLinkStatus(
        connected: true,
        environment: 'production',
        keyPrefix: 'mgp_prod',
        connectedAt: DateTime.now().subtract(const Duration(days: 3)),
        ordersToday: 7,
        ordersTotal: 112,
        lastOrderAt: DateTime.now().subtract(const Duration(minutes: 20)),
      ),
    );

    expect(find.text('Conectado · 7 pedido(s) hoy'), findsOneWidget);
    expect(find.text('Desconectar'), findsOneWidget);
    expect(find.text('Conectar'), findsNothing);
    expect(find.text('mgp_prod'), findsOneWidget);
    expect(find.text('112'), findsOneWidget);
    expect(find.text('hace 20 min'), findsOneWidget);
    expect(find.text('PRUEBAS'), findsNothing);
  });

  testWidgets('en sandbox avisa que es modo de pruebas', (tester) async {
    await _montar(
      tester,
      ChannelLinkStatus(
        connected: true,
        environment: 'sandbox',
        keyPrefix: 'mgp_sand',
        connectedAt: DateTime.now(),
      ),
    );

    expect(find.text('PRUEBAS'), findsOneWidget);
    expect(find.textContaining('no imprimen comanda'), findsOneWidget);
  });

  testWidgets('NUNCA muestra una llave completa en pantalla', (tester) async {
    await _montar(
      tester,
      ChannelLinkStatus(
        connected: true,
        environment: 'production',
        // El prefijo es lo único que la tarjeta conoce; la clave entera no
        // pasa por la app ni existe en su estado.
        keyPrefix: 'mgp_prod',
        connectedAt: DateTime.now(),
      ),
    );

    final textos = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ');
    expect(textos.contains('mgp_prod_'), isFalse);
    expect(textos.length, lessThan(2000));
  });
}
