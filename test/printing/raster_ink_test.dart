// Nitidez del raster ("Nitidez del texto" en Ajustes → Impresión).
//
// POR QUÉ EXISTE ESTE AJUSTE
//   El modo calidad manda el ticket como imagen de 1 bit. Decidir qué punto
//   es negro y cuál blanco es donde se pierde el trazo: con el umbral en la
//   mitad exacta, los palos de la letra caen unas veces en 2 puntos y otras
//   en 3 según dónde quede el glifo respecto a la rejilla del cabezal. En
//   papel eso se lee como "claro y poco nítido".
//
//   Y el resultado depende del CABEZAL: la misma imagen sale negra en una
//   térmica y gris en otra (el caso que lo motivó: una ELO con impresora
//   integrada). Por eso es por impresora y no una constante.
//
// Lo que se fija acá:
//  1. El ajuste viaja desde `connection_config` y el default no se guarda.
//  2. "Reforzada" pone MÁS tinta de verdad, y lo hace sin correr nada de
//     sitio: el ticket mide exactamente lo mismo.
//  3. El camino de CELDAS FIJAS (comandas, cierres, Star TSP100) no se toca.
//     Ahí cada carácter vive en una celda de 12 puntos y la `W` ya roza el
//     borde: engordarla la haría tocar a su vecina.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/escpos_parser.dart';
import 'package:mangopos/core/printing/star/mono_bitmap.dart';
import 'package:mangopos/core/printing/star/raster_ink.dart';
import 'package:mangopos/core/printing/star/ticket_rasterizer.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';

PrinterConfig _printer({Map<String, dynamic> config = const {}}) =>
    PrinterConfig(
      id: 'p1',
      businessId: 'b1',
      name: 'ELO built-in',
      type: 'usb',
      connectionConfig: config,
      isActive: true,
      paperWidth: 80,
      createdAt: DateTime(2026, 1, 1),
    );

int _inkDots(MonoBitmap bmp) {
  var n = 0;
  for (final row in bmp.rows) {
    for (final b in row) {
      n += b.toRadixString(2).split('').where((c) => c == '1').length;
    }
  }
  return n;
}

/// Un ticket cuya tinta NO depende de la fuente: una regla punteada, que el
/// modo proporcional dibuja como rectángulos. Así la prueba mide el engorde
/// y no la letra que cada plataforma tenga instalada.
ParsedTicket _ruledTicket() {
  final gen = EscPosGenerator(paperWidth: 80);
  gen.text('.' * gen.maxChars);
  return EscPosParser.parse(gen.getCommands());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Ajuste por impresora', () {
    test('sin la clave, una impresora queda en Normal', () {
      expect(resolveRasterInk(_printer()), RasterInk.normal);
    });

    test('lee el valor guardado', () {
      expect(
        resolveRasterInk(_printer(config: {'raster_ink': 'reforzada'})),
        RasterInk.reforzada,
      );
      expect(
        resolveRasterInk(_printer(config: {'raster_ink': 'fina'})),
        RasterInk.fina,
      );
    });

    test('un valor desconocido no rompe: cae en el default', () {
      expect(
        resolveRasterInk(_printer(config: {'raster_ink': 'turbo'})),
        RasterInk.normal,
      );
    });

    test('el default NO se escribe en connection_config', () {
      // Si se guardara, cambiar el default en el código no llegaría nunca a
      // las impresoras ya dadas de alta.
      expect(RasterInk.normal.wireValue, isNull);
      expect(RasterInk.fina.wireValue, 'fina');
      expect(RasterInk.reforzada.wireValue, 'reforzada');
    });

    test('Fina conserva el umbral con el que se imprimió hasta ahora', () {
      // Es la válvula de escape: si en algún cabezal el default emborrona los
      // huecos de las letras, se vuelve al trazo viejo sin build nuevo.
      expect(RasterInk.fina.threshold, 128);
      expect(RasterInk.fina.dilate, 0);
    });

    test('Normal engorda por el UMBRAL, no por dilatación', () {
      // El umbral crece el trazo por los bordes antialiaseados, así que no
      // mueve ninguna letra de sitio. La dilatación sí es un punto extra y se
      // reserva para el escalón siguiente.
      expect(RasterInk.normal.threshold, greaterThan(RasterInk.fina.threshold));
      expect(RasterInk.normal.dilate, 0);
      expect(RasterInk.reforzada.dilate, 1);
    });
  });

  group('Raster proporcional', () {
    test('Reforzada pone más tinta que Normal, y Normal más que Fina', () async {
      final ticket = _ruledTicket();
      final fina = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        ink: RasterInk.fina,
      );
      final normal = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        ink: RasterInk.normal,
      );
      final reforzada = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        ink: RasterInk.reforzada,
      );

      // La regla punteada se dibuja con rectángulos de borde entero, así que
      // el umbral no la toca: entre Fina y Normal la diferencia está en la
      // letra. El engorde sí la alcanza, y es lo que esta prueba fija.
      expect(_inkDots(normal), _inkDots(fina));
      expect(_inkDots(reforzada), greaterThan(_inkDots(normal)));
    });

    test('el engorde NO alarga el ticket ni lo desborda', () async {
      // Es tinta, no layout: si cambiara el alto, cambiaría el papel que
      // gasta cada factura y el ajuste dejaría de ser inocuo.
      final ticket = _ruledTicket();
      final normal = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        ink: RasterInk.normal,
      );
      final reforzada = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        ink: RasterInk.reforzada,
      );
      expect(reforzada.height, normal.height);
      expect(reforzada.width, 576);
    });

    test('el engorde no se propaga por toda la fila', () async {
      // Dilatar en sitio y de izquierda a derecha vuelve a encender el punto
      // recién encendido: la primera mota de tinta pintaría el resto de la
      // línea de negro. El punteado lo detecta al instante.
      final reforzada = await TicketRasterizer.render(
        _ruledTicket(),
        576,
        proportional: true,
        ink: RasterInk.reforzada,
      );
      final fila = reforzada.rows.firstWhere(
        (r) => r.any((b) => b != 0),
        orElse: () => throw StateError('la regla no pintó nada'),
      );
      expect(
        fila.every((b) => b == 0xFF),
        isFalse,
        reason: 'la fila quedó toda negra: el engorde se propagó',
      );
    });
  });

  group('Celdas fijas (comandas, cierres, Star)', () {
    test('la nitidez no altera ese camino', () async {
      // Su salida lleva tiempo funcionando y no se cambia sin que alguien lo
      // pida. Además ahí cada carácter vive en una celda de 12 puntos.
      final ticket = _ruledTicket();
      final normal = await TicketRasterizer.render(ticket, 576);
      final reforzada = await TicketRasterizer.render(
        ticket,
        576,
        ink: RasterInk.reforzada,
      );
      expect(_inkDots(reforzada), _inkDots(normal));
      expect(reforzada.height, normal.height);
    });
  });
}
