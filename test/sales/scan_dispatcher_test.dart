// Despachador del lector de código de barras HID.
//
// Los tres bugs que estas pruebas fijan salieron del reporte de campo "la
// pistola no me agrega nada, ni en venta rápida ni por zona":
//
//  1. UN SOLO DESTINATARIO. `HardwareKeyboard` llama a TODOS los handlers
//     registrados, y en esta app hay más de un `PosBarcodeScanner` vivo a la
//     vez (la rama de ventas del shell no se desmonta al abrir una mesa,
//     porque la mesa se empuja fuera del shell). El escaneo tiene que ir solo
//     a la pantalla de arriba.
//
//  2. SUFIJO DEL LECTOR. Solo se escuchaba Enter. Los lectores configurados
//     con sufijo Tab —o sin sufijo— nunca disparaban nada.
//
//  3. NO INVENTAR ESCANEOS. El cierre por inactividad no puede dispararse
//     con tecleo humano en un campo de texto.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/widgets/pos_barcode_scanner.dart';

/// Construye un KeyDownEvent utilizable sin motor de teclado real.
KeyDownEvent _down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: key,
  character: character,
  timeStamp: Duration.zero,
);

KeyDownEvent _char(String c) =>
    _down(LogicalKeyboardKey(c.codeUnitAt(0)), character: c);

/// Teclea [code] carácter por carácter, como haría el lector.
void _type(String code) {
  for (final c in code.split('')) {
    ScanDispatcher.instance.feedKey(_char(c));
  }
}

void main() {
  // El despachador se engancha a `HardwareKeyboard`, que necesita binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  final dispatcher = ScanDispatcher.instance;

  setUp(dispatcher.resetForTest);
  tearDown(dispatcher.resetForTest);

  group('Un solo destinatario', () {
    test('con dos pantallas montadas, solo la de arriba recibe', () {
      final abajo = <String>[];
      final arriba = <String>[];

      dispatcher.subscribe(abajo.add);
      dispatcher.subscribe(arriba.add);

      _type('7501234567890');
      dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(arriba, ['7501234567890']);
      expect(abajo, isEmpty, reason: 'la pantalla de abajo no debe recibirlo');
    });

    test('al cerrarse la de arriba, la de abajo vuelve a mandar', () {
      final abajo = <String>[];
      final arriba = <String>[];
      dispatcher.subscribe(abajo.add);
      dispatcher.subscribe(arriba.add);

      dispatcher.unsubscribe(arriba.add);
      _type('123456');
      dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(abajo, ['123456']);
      expect(arriba, isEmpty);
    });

    test('re-suscribir no duplica: mueve al tope', () {
      void a(String _) {}
      dispatcher.subscribe(a);
      dispatcher.subscribe(a);

      expect(dispatcher.subscriberCount, 1);
    });

    test('sin suscriptores no se procesa nada', () {
      expect(dispatcher.feedKey(_char('1')), isFalse);
      expect(dispatcher.feedKey(_down(LogicalKeyboardKey.enter)), isFalse);
    });
  });

  group('Sufijo del lector', () {
    test('Enter cierra el código y se consume la tecla', () {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      _type('7501234567890');
      final consumed = dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(scans, ['7501234567890']);
      expect(consumed, isTrue, reason: 'el Enter del escaneo no debe propagar');
    });

    test('Tab también cierra el código', () {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      _type('ABC-123');
      final consumed = dispatcher.feedKey(_down(LogicalKeyboardKey.tab));

      expect(scans, ['ABC-123']);
      expect(consumed, isTrue);
    });

    test('sin sufijo, cierra por inactividad', () async {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      _type('7501234567890');
      expect(scans, isEmpty, reason: 'todavía no venció la ventana');

      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(scans, ['7501234567890']);
    });

    test('un Enter suelto no dispara nada y sigue su curso', () {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      final consumed = dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(scans, isEmpty);
      expect(consumed, isFalse, reason: 'el Enter humano debe propagar');
    });

    test('un código de menos de 3 caracteres se descarta', () {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      _type('12');
      dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(scans, isEmpty);
    });
  });

  group('No inventar escaneos', () {
    test('tecleo humano lento nunca acumula código', () async {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      for (final c in '7501234'.split('')) {
        dispatcher.feedKey(_char(c));
        // Por encima de _interKeyResetMs: cada tecla reinicia el buffer.
        await Future<void>.delayed(const Duration(milliseconds: 130));
      }
      dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(scans, isEmpty);
    });

    test('tecleo humano rápido NO cierra por inactividad', () async {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      // Entre 50ms y 120ms: no reinicia el buffer, pero tampoco es ráfaga de
      // lector. Es el caso del cajero escribiendo rápido en el buscador.
      for (final c in '750123'.split('')) {
        dispatcher.feedKey(_char(c));
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }

      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(
        scans,
        isEmpty,
        reason: 'sin ráfaga, la inactividad no puede inventar un escaneo',
      );
    });

    test('pero ese mismo tecleo sí cierra si el usuario pulsa Enter', () async {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      for (final c in '750123'.split('')) {
        dispatcher.feedKey(_char(c));
        await Future<void>.delayed(const Duration(milliseconds: 70));
      }
      dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(scans, ['750123']);
    });

    test('las teclas no imprimibles no entran al código', () {
      final scans = <String>[];
      dispatcher.subscribe(scans.add);

      _type('750');
      dispatcher.feedKey(_down(LogicalKeyboardKey.shiftLeft));
      _type('123');
      dispatcher.feedKey(_down(LogicalKeyboardKey.enter));

      expect(scans, ['750123']);
    });
  });
}
