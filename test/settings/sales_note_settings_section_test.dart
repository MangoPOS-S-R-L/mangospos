import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/fiscal/view/sales_note_settings_section.dart';

Widget _host({
  required BusinessFeatures features,
  required TextEditingController prefixController,
  required TextEditingController limitController,
  ValueChanged<bool>? onEnabled,
  VoidCallback? onLimit,
  VoidCallback? onPrefix,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: SalesNoteSettingsSection(
          features: features,
          prefixController: prefixController,
          limitController: limitController,
          onEnabledChanged: onEnabled ?? (_) {},
          onLimitSubmitted: onLimit ?? () {},
          onPrefixSubmitted: onPrefix ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  late TextEditingController prefixController;
  late TextEditingController limitController;

  setUp(() {
    prefixController = TextEditingController(text: 'NV-');
    limitController = TextEditingController(text: '3');
  });
  tearDown(() {
    prefixController.dispose();
    limitController.dispose();
  });

  group('Layout', () {
    for (final size in const [
      Size(1024, 600),
      Size(1440, 900),
      Size(420, 800),
    ]) {
      testWidgets('renderiza sin desbordes a ${size.width.toInt()} dp', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _host(
            features: const BusinessFeatures(salesNoteEnabled: true),
            prefixController: prefixController,
            limitController: limitController,
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Vender por nota de venta'), findsOneWidget);
      });
    }

    testWidgets('apagada solo muestra el switch principal', (tester) async {
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(),
          prefixController: prefixController,
          limitController: limitController,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Vender por nota de venta'), findsOneWidget);
      expect(find.text('Notas de venta antes de una factura'), findsNothing);
      expect(find.text('Prefijo de la numeración'), findsNothing);
      expect(find.byType(Switch), findsOneWidget);
    });
  });

  group('Contenido', () {
    testWidgets('muestra el prefijo guardado y el progreso del ciclo', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(
            salesNoteEnabled: true,
            salesNotePrefix: 'NOTA-',
            salesNoteLimit: 5,
            salesNoteCount: 2,
          ),
          prefixController: prefixController,
          limitController: limitController,
        ),
      );

      expect(find.textContaining('NOTA-000123'), findsOneWidget);
      expect(
        find.textContaining('Después de 5 notas de venta'),
        findsOneWidget,
      );
      expect(
        find.text('Notas utilizadas desde la última factura: 2'),
        findsOneWidget,
      );
      expect(find.text('Preseleccionar al cobrar'), findsNothing);
      expect(find.textContaining('El próximo cobro'), findsNothing);
    });

    testWidgets('avisa cuando la próxima venta requiere factura', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(
            salesNoteEnabled: true,
            salesNoteCount: 3,
          ),
          prefixController: prefixController,
          limitController: limitController,
        ),
      );

      expect(
        find.textContaining('El próximo cobro en efectivo a consumidor final'),
        findsOneWidget,
      );
    });

    testWidgets('explica qué pagos requieren comprobante', (tester) async {
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(salesNoteEnabled: true),
          prefixController: prefixController,
          limitController: limitController,
        ),
      );

      expect(find.textContaining('NO consume NCF'), findsOneWidget);
      expect(
        find.textContaining('Tarjeta, transferencia y crédito fiscal siempre'),
        findsOneWidget,
      );
    });
  });

  group('Interacción', () {
    testWidgets('el switch avisa del cambio', (tester) async {
      bool? enabled;

      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(salesNoteEnabled: true),
          prefixController: prefixController,
          limitController: limitController,
          onEnabled: (v) => enabled = v,
        ),
      );

      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.byType(Switch));
      expect(enabled, isFalse);
    });

    testWidgets('permite guardar la cantidad y solo acepta dígitos', (
      tester,
    ) async {
      var saves = 0;
      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(salesNoteEnabled: true),
          prefixController: prefixController,
          limitController: limitController,
          onLimit: () => saves++,
        ),
      );

      final limitField = find.widgetWithText(TextField, 'Cantidad de notas');
      await tester.enterText(limitField, '5a');
      expect(limitController.text, '5');
      await tester.tap(find.byTooltip('Guardar cantidad de notas'));
      expect(saves, equals(1));
    });

    testWidgets('el botón del prefijo dispara el guardado', (tester) async {
      var saves = 0;

      await tester.pumpWidget(
        _host(
          features: const BusinessFeatures(salesNoteEnabled: true),
          prefixController: prefixController,
          limitController: limitController,
          onPrefix: () => saves++,
        ),
      );

      await tester.tap(find.byTooltip('Guardar prefijo'));
      expect(saves, equals(1));
    });
  });
}
