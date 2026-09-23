// Las REGLAS del modelo moderno, en el camino rasterizado.
//
// POR QUÉ SE TOCARON
//   Sobre la foto de una precuenta impresa en una ELO con impresora
//   integrada se midió la tinta fila por fila: de las CINCO reglas del
//   ticket, la detección solo encontró una — la sólida de encima del TOTAL.
//   Las punteadas no se distinguían del papel.
//
//   Una térmica no quema igual una marca corta y aislada que un trazo
//   seguido: el elemento del cabezal apenas se calienta y se vuelve a
//   apagar. Por eso el arreglo va por los dos lados, trazo más largo y una
//   fila más de alto, y no por subir el umbral del binarizado — a la regla
//   el umbral NO la toca, porque se dibuja como rectángulo de negro puro.
//
// EL EQUILIBRIO QUE ESTAS PRUEBAS CUIDAN
//   La regla tiene que verse Y tiene que seguir leyéndose como PUNTEADA. Es
//   lo que separa bloques sin cortar el ticket en cajas, que es justo lo que
//   distingue este modelo del estándar con sus filas de `=====`. Una regla
//   que se vuelve sólida gris pierde esa diferencia sin avisar.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/escpos_parser.dart';
import 'package:mangopos/core/printing/star/mono_bitmap.dart';
import 'package:mangopos/core/printing/star/ticket_rasterizer.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';

Future<MonoBitmap> _render(String ruleText) async {
  final gen = EscPosGenerator(paperWidth: 80);
  gen.text(ruleText * gen.maxChars);
  return TicketRasterizer.render(
    EscPosParser.parse(gen.getCommands()),
    576,
    proportional: true,
  );
}

/// Filas que llevan tinta, y cuántos puntos tiene cada una.
List<int> _inkedRows(MonoBitmap bmp) {
  final out = <int>[];
  for (final row in bmp.rows) {
    var n = 0;
    for (final b in row) {
      n += b.toRadixString(2).split('').where((c) => c == '1').length;
    }
    if (n > 0) out.add(n);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Regla punteada', () {
    test('se ve: trazo de 3 filas y más de la mitad del ancho', () async {
      final rows = _inkedRows(await _render('.'));
      expect(rows.length, 3, reason: 'el trazo tiene que medir 3 puntos');
      // 5 de tinta cada 9 = 55% del paso.
      final duty = rows.first / 576;
      expect(duty, greaterThan(0.45));
    });

    test('pero NO se vuelve una línea sólida', () async {
      // El día que alguien suba el trazo "para que se vea más", esto falla.
      // Una regla sólida gris no separa bloques: encajona el ticket, que es
      // exactamente lo que este modelo evita.
      final bmp = await _render('.');
      final duty = _inkedRows(bmp).first / 576;
      expect(
        duty,
        lessThan(0.62),
        reason: 'a un brazo de distancia ya se leería como línea continua',
      );

      final fila = bmp.rows.firstWhere((r) => r.any((b) => b != 0));
      expect(
        fila.every((b) => b == 0xFF),
        isFalse,
        reason: 'la regla punteada perdió sus huecos',
      );
    });
  });

  group('Regla sólida (la de encima del TOTAL)', () {
    test('sigue siendo continua y del mismo grosor', () async {
      // Es la única línea continua del ticket y por eso el ojo cae en el
      // importe. Si la punteada la alcanzara en peso, dejaría de funcionar.
      final rows = _inkedRows(await _render('-'));
      expect(rows.length, 3);
      expect(rows.first, 576, reason: 'la sólida cruza el papel entero');
    });
  });

  group('El aire no se lo come el trazo', () {
    test('engordar la regla no acerca sus vecinos', () async {
      // El renglón de una regla es TRAZO + aire, no un alto fijo: por eso
      // subir el grosor alarga el ticket 1 punto por regla en vez de robarle
      // separación a las líneas de al lado. Es el invariante de R4b — un
      // solo ritmo en todo el ticket.
      final gen = EscPosGenerator(paperWidth: 80);
      gen.text('Subtotal');
      gen.text('.' * gen.maxChars);
      gen.text('Total');
      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        576,
        proportional: true,
      );

      // Blanco entre la tinta de la regla y la del texto de abajo.
      final inked = <int>[];
      for (var y = 0; y < bmp.height; y++) {
        if (bmp.rows[y].any((b) => b != 0)) inked.add(y);
      }
      final huecos = <int>[];
      for (var i = 1; i < inked.length; i++) {
        final g = inked[i] - inked[i - 1] - 1;
        if (g > 10) huecos.add(g);
      }
      expect(huecos, isNotEmpty);
      for (final h in huecos) {
        expect(
          h,
          inInclusiveRange(40, 80),
          reason: 'el ritmo del ticket es ~58 puntos de aire en todas partes',
        );
      }
    });
  });
}
