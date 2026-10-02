import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/performance/performance_diagnostics.dart';
import 'package:mangopos/presentation/shell/performance_diagnostics_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'apagado no registra y una sesión nueva borra los datos anteriores',
    () async {
      final diagnostics = PerformanceDiagnostics.instance;
      diagnostics.stop();
      diagnostics.start(role: 'caja');
      expect(await diagnostics.measure('apertura', () async => true), isTrue);
      diagnostics.stop();
      expect(diagnostics.reportText, contains('apertura: n=1'));

      diagnostics.record('tardío', 99);
      expect(diagnostics.reportText, isNot(contains('tardío')));

      diagnostics.start(role: 'mesero');
      expect(diagnostics.reportText, contains('Rol: mesero'));
      expect(diagnostics.reportText, isNot(contains('apertura: n=1')));
      diagnostics.stop();
    },
  );

  test('registra fallos sin tragarse la excepción', () async {
    final diagnostics = PerformanceDiagnostics.instance;
    diagnostics.start(role: 'caja');
    await expectLater(
      diagnostics.measure<void>('pago', () async => throw StateError('falló')),
      throwsStateError,
    );
    diagnostics.stop();
    expect(diagnostics.reportText, contains('pago: n=1'));
    expect(diagnostics.reportText, contains('fallos=1'));
  });

  testWidgets('el panel etiqueta el equipo y detiene el muestreo', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PerformanceDiagnosticsDialog())),
    );
    await tester.tap(find.text('Equipo: caja'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Equipo: mesero').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Iniciar'));
    await tester.pump();
    expect(PerformanceDiagnostics.instance.reportText, contains('Rol: mesero'));
    await tester.tap(find.text('Detener'));
    await tester.pump();
    expect(PerformanceDiagnostics.instance.isRunning, isFalse);
  });
}
