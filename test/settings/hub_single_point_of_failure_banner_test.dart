import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/settings/hub/hub_single_point_of_failure_banner.dart';

/// El aviso que le dice al dueño que su Hub sin respaldo es un punto único de
/// falla.
///
/// Lo que está en juego: en modo Hub las demás cajas le entregan sus ventas y
/// dejan de guardarlas. Si ese equipo se daña antes de subir, se pierde lo de
/// todo el local. Este aviso es lo único que se lo dice.
void main() {
  Future<void> montar(WidgetTester tester, String? backupUrl) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HubSinglePointOfFailureBanner(backupUrl: backupUrl),
        ),
      ),
    );
  }

  group('sin respaldo → avisa', () {
    testWidgets('dice que es punto único de falla', (tester) async {
      await montar(tester, null);
      expect(find.textContaining('punto único de falla'), findsOneWidget);
    });

    // El aviso tiene que explicar la CONSECUENCIA, no solo que falta un campo:
    // "falta configurar el respaldo" no mueve a nadie; "se pierde lo de todo el
    // local" sí.
    testWidgets('explica que se pierde lo de TODO el local', (tester) async {
      await montar(tester, null);
      expect(find.textContaining('TODO el local'), findsOneWidget);
    });

    testWidgets('lleva icono de advertencia', (tester) async {
      await montar(tester, null);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('una cadena vacía cuenta como sin respaldo', (tester) async {
      await montar(tester, '');
      expect(find.textContaining('punto único de falla'), findsOneWidget);
    });

    testWidgets('solo espacios también cuenta como sin respaldo',
        (tester) async {
      await montar(tester, '   ');
      expect(find.textContaining('punto único de falla'), findsOneWidget);
    });
  });

  group('con respaldo → confirma', () {
    testWidgets('no muestra la advertencia', (tester) async {
      await montar(tester, '192.168.1.51');
      expect(find.textContaining('punto único de falla'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('muestra cuál es el respaldo, para poder verificarlo',
        (tester) async {
      await montar(tester, '192.168.1.51');
      expect(find.textContaining('192.168.1.51'), findsOneWidget);
    });

    testWidgets('dice que el Hub le manda copia de cada operación',
        (tester) async {
      await montar(tester, '192.168.1.51');
      expect(find.textContaining('copia de cada operación'), findsOneWidget);
    });
  });

  // Es un aviso, no un bloqueo: quien está configurando puede poner el
  // respaldo en el paso siguiente, y bloquearlo lo dejaría a medias.
  testWidgets('no bloquea: no hay botones ni campos deshabilitados',
      (tester) async {
    await montar(tester, null);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('cambia de aviso a confirmación al configurar el respaldo',
      (tester) async {
    await montar(tester, null);
    expect(find.textContaining('punto único de falla'), findsOneWidget);

    await montar(tester, '192.168.1.51');
    expect(find.textContaining('punto único de falla'), findsNothing);
    expect(find.textContaining('192.168.1.51'), findsOneWidget);
  });
}
