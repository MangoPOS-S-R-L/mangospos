import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

Widget _host(void Function(BuildContext context) onTap) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => onTap(context),
          child: const Text('disparar'),
        ),
      ),
    ),
  );
}

void main() {
  const rawError =
      "ClientException with SocketException: Failed host lookup: "
      "'supabase.mangopos.do' (OS Error: Host desconocido, errno = 11001), "
      "uri=https://supabase.mangopos.do/auth/v1/token?grant_type=password";

  testWidgets('el toast de error no muestra texto tecnico', (tester) async {
    await tester.pumpWidget(_host((c) => AppToast.error(c, rawError)));
    await tester.tap(find.text('disparar'));
    await tester.pump();

    expect(find.text(FriendlyError.connection), findsOneWidget);
    expect(find.textContaining('http'), findsNothing);
    expect(find.textContaining('SocketException'), findsNothing);
    expect(find.textContaining('errno'), findsNothing);
  });

  testWidgets('conserva la frase de la pantalla y traduce la causa', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host((c) => AppToast.error(c, 'No se pudo imprimir: $rawError')),
    );
    await tester.tap(find.text('disparar'));
    await tester.pump();

    expect(
      find.text('No se pudo imprimir. ${FriendlyError.connection}'),
      findsOneWidget,
    );
  });

  testWidgets('cinco errores seguidos dejan un solo aviso en pantalla', (
    tester,
  ) async {
    var intento = 0;
    await tester.pumpWidget(
      _host((c) {
        intento++;
        AppToast.error(c, 'Intento $intento fallido.');
      }),
    );

    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('disparar'));
      await tester.pump();
    }

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Intento 5 fallido.'), findsOneWidget);
    expect(find.text('Intento 4 fallido.'), findsNothing);
  });

  testWidgets('el aviso se va solo antes de los 5 segundos', (tester) async {
    await tester.pumpWidget(_host((c) => AppToast.error(c, 'Algo falló.')));
    await tester.tap(find.text('disparar'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);

    // Sin intervencion del usuario: pasado el tope, la pantalla queda limpia.
    await tester.pump(AppToast.maxDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  group('showAppSnackBar', () {
    testWidgets('recorta una duracion mas larga que el tope', (tester) async {
      await tester.pumpWidget(
        _host(
          (c) => ScaffoldMessenger.of(c).showAppSnackBar(
            const SnackBar(
              content: Text('Aviso largo'),
              duration: Duration(seconds: 30),
            ),
          ),
        ),
      );
      await tester.tap(find.text('disparar'));
      await tester.pumpAndSettle();
      expect(find.text('Aviso largo'), findsOneWidget);

      // Los 30 segundos pedidos quedan recortados al tope de la app.
      await tester.pump(
        AppSnackBarMessenger.maxDuration + const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('limpia el detalle tecnico del contenido', (tester) async {
      await tester.pumpWidget(
        _host(
          (c) => ScaffoldMessenger.of(c).showAppSnackBar(
            SnackBar(
              content: Text('No se pudo transferir: $rawError'),
              backgroundColor: Colors.red,
            ),
          ),
        ),
      );
      await tester.tap(find.text('disparar'));
      await tester.pump();

      expect(
        find.text('No se pudo transferir. ${FriendlyError.connection}'),
        findsOneWidget,
      );
    });

    testWidgets('respeta la accion y el estilo del aviso original', (
      tester,
    ) async {
      var pulsado = false;
      await tester.pumpWidget(
        _host(
          (c) => ScaffoldMessenger.of(c).showAppSnackBar(
            SnackBar(
              content: Text('Cuenta por pagar creada: $rawError'),
              action: SnackBarAction(
                label: 'Ver',
                onPressed: () => pulsado = true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('disparar'));
      await tester.pumpAndSettle();

      expect(find.text('Ver'), findsOneWidget);
      await tester.tap(find.text('Ver'));
      await tester.pump();
      expect(pulsado, isTrue);
    });

    testWidgets('el segundo aviso reemplaza al primero', (tester) async {
      var n = 0;
      await tester.pumpWidget(
        _host((c) {
          n++;
          ScaffoldMessenger.of(
            c,
          ).showAppSnackBar(SnackBar(content: Text('Aviso $n')));
        }),
      );

      await tester.tap(find.text('disparar'));
      await tester.pump();
      await tester.tap(find.text('disparar'));
      await tester.pump();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Aviso 2'), findsOneWidget);
      expect(find.text('Aviso 1'), findsNothing);
    });
  });
}
