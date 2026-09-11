// Sección de NOTA DE VENTA en Configuración Fiscal.
//
// Existe por un fallo real: la primera versión ponía un `Expanded` dentro de
// un `Row` anidado que el `Row` de afuera dejaba sin acotar, y la pantalla
// reventaba al abrirse con "RenderFlex children have non-zero flex but
// incoming width constraints are unbounded". `flutter analyze` no ve eso —
// solo aparece al renderizar.
//
// Por eso las pruebas montan la sección de verdad, a los anchos donde corre
// el POS: la tablet del salón (1024x600), una ventana de escritorio y una
// angosta.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/fiscal/view/sales_note_settings_section.dart';

Widget _host({
  required BusinessFeatures features,
  required TextEditingController controller,
  ValueChanged<bool>? onEnabled,
  ValueChanged<bool>? onDefault,
  VoidCallback? onPrefix,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        // Padding como el de la tarjeta real: la sección nunca recibe el
        // ancho pelado de la pantalla.
        padding: const EdgeInsets.all(24),
        child: SalesNoteSettingsSection(
          features: features,
          prefixController: controller,
          onEnabledChanged: onEnabled ?? (_) {},
          onDefaultChanged: onDefault ?? (_) {},
          onPrefixSubmitted: onPrefix ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController(text: 'NV-'));
  tearDown(() => controller.dispose());

  group('Layout', () {
    // 1024x600 es la tablet del salón; 1440 una ventana de escritorio; 420 el
    // caso angosto donde el campo del prefijo compite con el texto.
    for (final size in const [Size(1024, 600), Size(1440, 900), Size(420, 800)]) {
      testWidgets('renderiza sin desbordes a ${size.width.toInt()} dp', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _host(
            features: const BusinessFeatures(
              salesNoteEnabled: true,
              salesNoteDefault: true,
            ),
            controller: controller,
          ),
        );

        // Cualquier excepción de layout (incluida la del flex sin acotar)
        // queda registrada acá.
        expect(tester.takeException(), isNull);
        expect(find.text('Vender por nota de venta'), findsOneWidget);
      });
    }

    testWidgets('apagada solo muestra el switch principal', (tester) async {
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(),
          controller: controller,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Vender por nota de venta'), findsOneWidget);
      // Los ajustes de detalle no tienen por qué estar si la feature no está
      // prendida.
      expect(find.text('Preseleccionar al cobrar'), findsNothing);
      expect(find.text('Prefijo de la numeración'), findsNothing);
      expect(find.byType(Switch), findsOneWidget);
    });
  });

  group('Contenido', () {
    testWidgets('muestra cómo va a salir impreso el prefijo guardado', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(
            salesNoteEnabled: true,
            salesNotePrefix: 'NOTA-',
          ),
          controller: controller,
        ),
      );

      expect(
        find.textContaining('NOTA-000123'),
        findsOneWidget,
        reason: 'el dueño tiene que ver el número real, no un ejemplo fijo',
      );
    });

    testWidgets('dice que no consume NCF', (tester) async {
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(salesNoteEnabled: true),
          controller: controller,
        ),
      );

      expect(find.textContaining('NO consume NCF'), findsOneWidget);
    });
  });

  group('Interacción', () {
    testWidgets('los switches avisan del cambio', (tester) async {
      bool? enabled;
      bool? asDefault;

      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(salesNoteEnabled: true),
          controller: controller,
          onEnabled: (v) => enabled = v,
          onDefault: (v) => asDefault = v,
        ),
      );

      final switches = find.byType(Switch);
      expect(switches, findsNWidgets(2));

      await tester.tap(switches.first);
      expect(enabled, isFalse, reason: 'estaba prendida: el toque la apaga');

      await tester.tap(switches.last);
      expect(asDefault, isTrue);
    });

    testWidgets('el botón del prefijo dispara el guardado', (tester) async {
      var saves = 0;

      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(salesNoteEnabled: true),
          controller: controller,
          onPrefix: () => saves++,
        ),
      );

      await tester.tap(find.byTooltip('Guardar prefijo'));
      expect(saves, equals(1));
    });
  });
}
