// Tarjeta "Facturación electrónica" en Ajustes → Comprobantes fiscales.
//
// Lo que protege: que el dueño vea "Solicitar" solo si nunca la pidió, que una
// solicitud en curso muestre en qué paso va (y el reenvío cuando el
// certificado falló), y que un negocio ya activo no invite a pedirla de nuevo.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/data/repositories/ecf_request_repository.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/fiscal/view/ecf_request_card.dart';

Future<void> _pump(WidgetTester tester, Map<String, dynamic> json) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ecfRequestStatusProvider('b1').overrideWith(
          (ref) async => EcfRequestStatus.fromJson(json),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: EcfRequestCard(businessId: 'b1'))),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('es', null));

  testWidgets('nunca la pidió: invita a solicitar', (tester) async {
    await _pump(tester, {'stage': 'none', 'data': {'rnc': '133328828'}});
    expect(find.text('Solicitar'), findsOneWidget);
    expect(find.text('Conviértete en emisor electrónico'), findsOneWidget);
  });

  testWidgets('empresa sin registrar: muestra el reenvío', (tester) async {
    await _pump(tester, {
      'stage': 'company',
      'requested_at': '2026-09-17T15:00:00Z',
      'contact_name': 'Ana Pérez',
      'contact_phone': '809-555-1234',
    });
    expect(find.text('Solicitar'), findsNothing);
    expect(find.text('Enviar de nuevo con mi certificado'), findsOneWidget);
    expect(find.textContaining('Ana Pérez'), findsOneWidget);
  });

  testWidgets('en certificación: pasos marcados y guía', (tester) async {
    await _pump(tester, {
      'stage': 'certification',
      'requested_at': '2026-09-17T15:00:00Z',
      'already_authorized': false,
    });
    final checks = tester.widgetList<Icon>(find.byIcon(Icons.check_circle));
    // Solicitud enviada + empresa registrada.
    expect(checks.length, 2);
    expect(find.textContaining('te guía con la postulación'), findsOneWidget);
    expect(find.text('Enviar de nuevo con mi certificado'), findsNothing);
  });

  testWidgets('ya activa: no invita a pedirla otra vez', (tester) async {
    await _pump(tester, {'stage': 'active'});
    expect(find.text('Facturación electrónica activa'), findsOneWidget);
    expect(find.text('Solicitar'), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });

  test('etapa desconocida cae en none', () {
    expect(EcfRequestStage.parse('otra'), EcfRequestStage.none);
    expect(EcfRequestStage.parse('sequences'), EcfRequestStage.sequences);
  });
}
