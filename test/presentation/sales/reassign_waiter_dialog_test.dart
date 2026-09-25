// Asignarle una mesa abierta a otro mesero.
//
// Lo que se prueba acá es lo que el diálogo le promete al usuario y lo que le
// manda al servidor. La garantía de que la plata NO se mueve vive en la RPC y
// está probada en supabase/tests/reassign_table_waiter_local_test.sh; acá se
// prueba que la pantalla diga esa regla y mande los datos correctos.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/widgets/reassign_waiter_dialog.dart';

class _Submitted {
  String? sessionId;
  String? employeeId;
  String? reason;
  int calls = 0;
}

Future<_Submitted> _pump(
  WidgetTester tester, {
  List<ReassignWaiterOption> waiters = const [
    ReassignWaiterOption(id: 'emp-1', name: 'Claudia Perez'),
    ReassignWaiterOption(id: 'emp-2', name: 'Pedro Gomez'),
  ],
  Object? loadError,
  Object? submitError,
  Map<String, dynamic> result = const {
    'changed': true,
    'to_employee_name': 'Pedro Gomez',
    'items_frozen': 2,
  },
  String? currentWaiterName = 'Claudia',
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final sent = _Submitted();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reassignWaiterLoaderProvider.overrideWithValue((businessId) async {
          if (loadError != null) throw loadError;
          return waiters;
        }),
        reassignWaiterSubmitProvider.overrideWithValue((
            {required String sessionId,
            required String employeeId,
            String? reason}) async {
          sent
            ..calls += 1
            ..sessionId = sessionId
            ..employeeId = employeeId
            ..reason = reason;
          if (submitError != null) throw submitError;
          return result;
        }),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => showReassignWaiterDialog(
                context,
                ref,
                businessId: 'biz-1',
                sessionId: 'sess-1',
                tableLabel: 'Mesa 12',
                currentWaiterName: currentWaiterName,
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return sent;
}

void main() {
  testWidgets('dice qué pasa con lo ya consumido antes de elegir a nadie',
      (tester) async {
    await _pump(tester);

    expect(find.text('Asignar Mesa 12 a otro mesero'), findsOneWidget);
    expect(find.text('Ahora es de Claudia.'), findsOneWidget);
    expect(
      find.textContaining('sigue contando para quien lo digitó'),
      findsOneWidget,
    );
  });

  testWidgets('lista los meseros y no deja asignar sin elegir uno',
      (tester) async {
    await _pump(tester);

    expect(find.text('Claudia Perez'), findsOneWidget);
    expect(find.text('Pedro Gomez'), findsOneWidget);

    final boton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Asignar'),
    );
    expect(boton.onPressed, isNull);
  });

  testWidgets('manda la mesa, el mesero elegido y el motivo', (tester) async {
    final sent = await _pump(tester);

    await tester.tap(find.text('Pedro Gomez'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Ej. cambio de turno'),
      'se fue temprano',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Asignar'));
    await tester.pumpAndSettle();

    expect(sent.calls, 1);
    expect(sent.sessionId, 'sess-1');
    expect(sent.employeeId, 'emp-2');
    expect(sent.reason, 'se fue temprano');
  });

  testWidgets('al terminar avisa a quién quedó y que lo viejo no se movió',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Pedro Gomez'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Asignar'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.textContaining('Mesa 12 ahora es de Pedro Gomez'),
      findsOneWidget,
    );
    expect(
      find.textContaining('queda con quien lo digitó'),
      findsOneWidget,
    );
  });

  testWidgets('si ya era de ese mesero lo dice sin inventar un cambio',
      (tester) async {
    await _pump(tester, result: const {
      'changed': false,
      'to_employee_name': 'Pedro Gomez',
      'items_frozen': 0,
    });

    await tester.tap(find.text('Pedro Gomez'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Asignar'));
    await tester.pumpAndSettle();

    expect(find.textContaining('ya era de Pedro Gomez'), findsOneWidget);
  });

  testWidgets('un error del servidor se muestra y el diálogo NO se cierra',
      (tester) async {
    await _pump(
      tester,
      submitError: Exception(
        'Esta mesa ya se cobró y se cerró: su mesero no se puede cambiar.',
      ),
    );

    await tester.tap(find.text('Pedro Gomez'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Asignar'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('ya se cobró'), findsOneWidget);
  });

  testWidgets('un negocio sin meseros activos lo dice, no muestra vacío',
      (tester) async {
    await _pump(tester, waiters: const []);

    expect(
      find.text('Este negocio no tiene meseros activos registrados.'),
      findsOneWidget,
    );
  });

  testWidgets('con pocos meseros no estorba el buscador', (tester) async {
    await _pump(tester);
    expect(find.widgetWithText(TextField, 'Buscar mesero'), findsNothing);
  });

  testWidgets('con muchos meseros aparece el buscador y filtra',
      (tester) async {
    await _pump(
      tester,
      waiters: List.generate(
        8,
        (i) => ReassignWaiterOption(id: 'emp-$i', name: 'Mesero $i'),
      ),
    );

    expect(find.widgetWithText(TextField, 'Buscar mesero'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Buscar mesero'),
      'Mesero 3',
    );
    await tester.pumpAndSettle();

    // Acotado a la lista: el texto tecleado tambien vive en el buscador.
    expect(
      find.widgetWithText(RadioListTile<String>, 'Mesero 3'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(RadioListTile<String>, 'Mesero 4'),
      findsNothing,
    );
  });
}
