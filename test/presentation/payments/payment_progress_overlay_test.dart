import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/fiscal/payment_stage.dart';
import 'package:mangopos/core/widgets/payment_progress_overlay.dart';

/// El overlay de cobro por etapas. Existe porque la emisión e-CF metió una
/// espera de hasta 8 segundos en medio del cobro, y un spinner mudo hacía que
/// el cajero creyera que la app se colgó.
///
/// Lo que estos tests protegen es que las etapas mostradas correspondan a
/// esperas reales: prometer "Consultando con la DGII" en un cobro con NCF de
/// papel sería mentir sobre lo que está pasando.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Stack(children: [child])),
  );

  Future<void> pump(
    WidgetTester tester, {
    required PaymentStage stage,
    required bool isElectronic,
    bool dgiiContingency = false,
  }) async {
    await tester.pumpWidget(
      wrap(
        PaymentProgressOverlay(
          stage: stage,
          isElectronic: isElectronic,
          dgiiContingency: dgiiContingency,
        ),
      ),
    );
    await tester.pump();
  }

  group('qué etapas se muestran', () {
    testWidgets('con NCF de papel no aparece la DGII', (tester) async {
      await pump(
        tester,
        stage: PaymentStage.registrando,
        isElectronic: false,
      );

      expect(find.text('Registrando el cobro'), findsOneWidget);
      expect(find.text('Imprimiendo comprobante'), findsOneWidget);
      // Esa espera no existe en papel: listarla haría creer que el cobro
      // tarda más de lo que tarda.
      expect(find.text('Consultando con la DGII'), findsNothing);
    });

    testWidgets('con e-CF aparecen las tres', (tester) async {
      await pump(
        tester,
        stage: PaymentStage.registrando,
        isElectronic: true,
      );

      expect(find.text('Registrando el cobro'), findsOneWidget);
      expect(find.text('Consultando con la DGII'), findsOneWidget);
      expect(find.text('Imprimiendo comprobante'), findsOneWidget);
    });
  });

  group('progreso visual', () {
    testWidgets('la primera etapa gira y ninguna esta cumplida', (
      tester,
    ) async {
      await pump(
        tester,
        stage: PaymentStage.registrando,
        isElectronic: true,
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('en DGII la primera queda cumplida', (tester) async {
      await pump(tester, stage: PaymentStage.dgii, isElectronic: true);

      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('al imprimir hay dos cumplidas', (tester) async {
      await pump(
        tester,
        stage: PaymentStage.imprimiendo,
        isElectronic: true,
      );

      expect(find.byIcon(Icons.check), findsNWidgets(2));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('en papel al imprimir solo hay una cumplida', (tester) async {
      await pump(
        tester,
        stage: PaymentStage.imprimiendo,
        isElectronic: false,
      );

      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('en idle no se marca nada como cumplido', (tester) async {
      // Frame entre el tap y el primer copyWith del viewmodel. Sin la guarda
      // de activeIdx >= 0, el indexWhere devuelve -1 y TODAS las etapas se
      // pintarian como cumplidas.
      await pump(tester, stage: PaymentStage.idle, isElectronic: true);

      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('aviso de la DGII', () {
    testWidgets('no aparece de inmediato', (tester) async {
      await pump(tester, stage: PaymentStage.dgii, isElectronic: true);

      // Alanube responde tipico en 1-3s. Mostrar el aviso de una sugeriria
      // que la espera es larga cuando normalmente no lo es.
      final texto = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(texto.opacity, 0);
    });

    testWidgets('aparece si la espera se alarga', (tester) async {
      await pump(tester, stage: PaymentStage.dgii, isElectronic: true);
      await tester.pump(const Duration(seconds: 3));

      final texto = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(texto.opacity, 1);
      expect(find.textContaining('No cierres esta ventana'), findsOneWidget);
    });

    testWidgets('nunca aparece fuera de la etapa DGII', (tester) async {
      await pump(
        tester,
        stage: PaymentStage.registrando,
        isElectronic: true,
      );
      await tester.pump(const Duration(seconds: 3));

      expect(find.byType(AnimatedOpacity), findsNothing);
    });
  });
  group('contingencia de DGII', () {
    // Cuando `emit-document` no responde a tiempo el cobro NO falla: la venta
    // quedo grabada y el ticket se imprime. Lo que estos tests protegen es que
    // el cajero se entere de que la factura todavia no llego a la DGII, en vez
    // de ver un check verde que le haria creer que ya esta emitida.
    testWidgets('la fila de DGII deja de prometer que se consulto', (
      tester,
    ) async {
      await pump(
        tester,
        stage: PaymentStage.imprimiendo,
        isElectronic: true,
        dgiiContingency: true,
      );

      expect(find.text('DGII no respondió a tiempo'), findsOneWidget);
      expect(find.text('Consultando con la DGII'), findsNothing);
    });

    testWidgets('explica que el cobro quedo hecho y no hay que reenviar', (
      tester,
    ) async {
      await pump(
        tester,
        stage: PaymentStage.imprimiendo,
        isElectronic: true,
        dgiiContingency: true,
      );

      expect(
        find.textContaining('el ticket se imprime igual'),
        findsOneWidget,
      );
      expect(
        find.textContaining('automáticamente'),
        findsOneWidget,
      );
    });

    testWidgets('sin contingencia no aparece ningun aviso', (tester) async {
      await pump(
        tester,
        stage: PaymentStage.imprimiendo,
        isElectronic: true,
      );

      expect(find.text('DGII no respondió a tiempo'), findsNothing);
      expect(find.textContaining('el ticket se imprime igual'), findsNothing);
    });
  });
}
