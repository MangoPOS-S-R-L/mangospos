// Soporte de impresoras Star TSP100 (StarGraphic / futurePRNT).
//
// Esas impresoras NO interpretan ESC/POS: aceptan los bytes y no imprimen
// nada. La app rasteriza el ticket que ya generó en ESC/POS y lo manda como
// bitmap. Estas pruebas cubren las piezas puras (detección, parser, encoder);
// el dibujado con dart:ui se valida contra hardware.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/escpos_parser.dart';
import 'package:mangopos/core/printing/star/mono_bitmap.dart';
import 'package:mangopos/core/printing/star/printer_emulation.dart';
import 'package:mangopos/core/printing/star/star_raster_encoder.dart';
import 'package:mangopos/core/printing/star/ticket_rasterizer.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';

PrinterConfig _printer({
  String name = 'Cocina',
  String? devicePath,
  String? mac,
  Map<String, dynamic> connectionConfig = const {},
  int paperWidth = 80,
}) => PrinterConfig(
  id: 'p1',
  businessId: 'b1',
  name: name,
  type: 'usb',
  devicePath: devicePath,
  mac: mac,
  isActive: true,
  paperWidth: paperWidth,
  connectionConfig: connectionConfig,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  group('Detección de emulación', () {
    test('vendor ID de Star (0x0519 = 1305 decimal) → raster', () {
      final p = _printer(name: 'Impresora 1', devicePath: '1305:3');
      expect(resolvePrinterEmulation(p), PrinterEmulation.starRaster);
    });

    test('el nombre del modelo también la identifica', () {
      expect(
        resolvePrinterEmulation(_printer(name: 'Star TSP143III')),
        PrinterEmulation.starRaster,
      );
      expect(
        resolvePrinterEmulation(_printer(name: 'TSP100 Cocina')),
        PrinterEmulation.starRaster,
      );
    });

    test('una térmica común queda en ESC/POS', () {
      final p = _printer(name: 'POS-80 Caja', devicePath: '1155:22304');
      expect(resolvePrinterEmulation(p), PrinterEmulation.escPos);
    });

    test('el override manual manda sobre la heurística', () {
      final forzadaEscPos = _printer(
        name: 'Star TSP143III',
        connectionConfig: const {'emulation': 'escpos'},
      );
      expect(resolvePrinterEmulation(forzadaEscPos), PrinterEmulation.escPos);

      final forzadaStar = _printer(
        name: 'Generica',
        connectionConfig: const {'emulation': 'star_raster'},
      );
      expect(resolvePrinterEmulation(forzadaStar), PrinterEmulation.starRaster);
    });
  });

  group('Parser de ESC/POS', () {
    test('reconstruye texto, alineación, negrita y tamaño', () {
      final gen = EscPosGenerator();
      gen.initialize();
      gen.setTextSize(width: 2, height: 2);
      gen.setBold(true);
      gen.textCentered('FACTURA');
      gen.setBold(false);
      gen.setTextSize();
      gen.text('Producto');
      gen.textRow('TOTAL:', 'RD\$ 100.00');
      gen.cut();

      final parsed = EscPosParser.parse(gen.getCommands());
      final lines = parsed.ops.whereType<TicketTextOp>().toList();

      final titulo = lines.firstWhere((l) => l.text.contains('FACTURA'));
      expect(titulo.align, TicketAlign.center);
      expect(titulo.bold, isTrue);
      expect(titulo.widthFactor, 2);
      expect(titulo.heightFactor, 2);

      final producto = lines.firstWhere((l) => l.text == 'Producto');
      expect(producto.align, TicketAlign.left);
      expect(producto.bold, isFalse);
      expect(producto.widthFactor, 1);

      // La fila izquierda/derecha llega ya con su relleno de espacios: el
      // raster la dibuja en celdas fijas y queda igual que en papel.
      final total = lines.firstWhere((l) => l.text.startsWith('TOTAL:'));
      expect(total.text.length, 48);
      expect(total.text.trimRight().endsWith('RD\$ 100.00'), isTrue);

      expect(parsed.cut, isTrue);
    });

    test('la franja inversa de la comanda conserva el flag', () {
      final gen = EscPosGenerator();
      gen.initialize();
      gen.setInverse(true);
      gen.text('PARA LLEVAR');
      gen.setInverse(false);
      gen.text('normal');

      final lines = EscPosParser.parse(
        gen.getCommands(),
      ).ops.whereType<TicketTextOp>().toList();

      expect(lines.firstWhere((l) => l.text == 'PARA LLEVAR').inverse, isTrue);
      expect(lines.firstWhere((l) => l.text == 'normal').inverse, isFalse);
    });

    test('el interlineado (ESC 3) viaja con la línea', () {
      // Es el avance de papel del ticket. Mientras se descartaba, el raster
      // dibujaba cada renglón pegado al siguiente aunque el builder pidiera
      // aire — el bug que hacía ver la factura moderna "toda amontonada".
      final gen = EscPosGenerator();
      gen.initialize();
      gen.setLineSpacing(40);
      gen.text('con aire');
      gen.resetLineSpacing();
      gen.text('de fabrica');

      final lines = EscPosParser.parse(
        gen.getCommands(),
      ).ops.whereType<TicketTextOp>().toList();

      expect(lines.firstWhere((l) => l.text == 'con aire').lineSpacing, 40);
      expect(
        lines.firstWhere((l) => l.text == 'de fabrica').lineSpacing,
        isNull,
        reason: 'ESC 2 devuelve la métrica de fábrica',
      );
    });

    test('conserva los renglones en blanco (son parte del layout)', () {
      final gen = EscPosGenerator();
      gen.initialize();
      gen.text('a');
      gen.lineFeed(3);
      gen.text('b');

      final lines = EscPosParser.parse(
        gen.getCommands(),
      ).ops.whereType<TicketTextOp>().toList();
      final blancos = lines.where((l) => l.text.isEmpty).length;
      expect(blancos, greaterThanOrEqualTo(3));
    });

    test('un comando desconocido no aborta el ticket', () {
      final bytes = <int>[
        0x1B, 0x40, // ESC @
        0x1B, 0x99, // comando inventado
        ...'HOLA'.codeUnits,
        0x0A,
      ];
      final lines = EscPosParser.parse(
        bytes,
      ).ops.whereType<TicketTextOp>().toList();
      expect(lines.map((l) => l.text), contains('HOLA'));
    });

    test('decodifica acentos en Latin-1', () {
      final gen = EscPosGenerator();
      gen.initialize();
      gen.text('RAZÓN SOCIAL ñ');

      final lines = EscPosParser.parse(
        gen.getCommands(),
      ).ops.whereType<TicketTextOp>().toList();
      expect(lines.any((l) => l.text == 'RAZÓN SOCIAL ñ'), isTrue);
    });

    test('lee una imagen GS v 0 como bloque de píxeles', () {
      // 1 byte de ancho (8 puntos) × 2 filas: 0b10000001 y 0b00011000.
      final bytes = <int>[
        0x1D, 0x76, 0x30, 0x00, // GS v 0 m
        0x01, 0x00, // xBytes = 1
        0x02, 0x00, // yDots = 2
        0x81, 0x18,
      ];
      final imagenes = EscPosParser.parse(
        bytes,
      ).ops.whereType<TicketImageOp>().toList();
      expect(imagenes, hasLength(1));
      final img = imagenes.single;
      expect(img.width, 8);
      expect(img.height, 2);
      expect(img.pixels[0], isTrue); // bit más alto de la fila 0
      expect(img.pixels[7], isTrue); // bit más bajo de la fila 0
      expect(img.pixels[1], isFalse);
      expect(img.pixels[8 + 3], isTrue); // fila 1
    });
  });

  group('Encoder raster de Star', () {
    test('el ancho en puntos sale del papel', () {
      expect(StarRasterEncoder.dotsForPaperWidth(80), 576);
      expect(StarRasterEncoder.dotsForPaperWidth(58), 384);
    });

    test('envuelve las filas con entrada/salida de modo raster', () {
      final bitmap = MonoBitmap(384)..setPixel(0, 0);
      final bytes = StarRasterEncoder.encode(bitmap, cut: true);

      // ESC @ … ESC * r A … ESC * r P 0 NUL
      expect(bytes.sublist(0, 2), [0x1B, 0x40]);
      expect(bytes.sublist(2, 6), [0x1B, 0x2A, 0x72, 0x41]);
      expect(bytes.sublist(6, 12), [0x1B, 0x2A, 0x72, 0x50, 0x30, 0x00]);

      // Primera fila de datos: 'b' + largo little-endian (48 bytes en 58mm).
      expect(bytes[12], 0x62);
      expect(bytes[13], 48);
      expect(bytes[14], 0);
      expect(bytes[15], 0x80); // el punto (0,0) es el bit más alto

      // Cierre: ESC FF NUL, ESC * r B y corte parcial.
      expect(bytes.sublist(bytes.length - 10), [
        0x1B, 0x0C, 0x00, // ESC FF NUL
        0x1B, 0x2A, 0x72, 0x42, // ESC * r B
        0x1B, 0x64, 0x33, // ESC d 3
      ]);
    });

    test('sin corte no emite ESC d', () {
      final bitmap = MonoBitmap(576)..ensureHeight(2);
      final bytes = StarRasterEncoder.encode(bitmap, cut: false);
      expect(bytes.sublist(bytes.length - 4), [0x1B, 0x2A, 0x72, 0x42]);
    });

    test('reconoce sus propios bytes para no convertir dos veces', () {
      final bitmap = MonoBitmap(576)..setPixel(1, 1);
      final bytes = StarRasterEncoder.encode(bitmap);
      expect(StarRasterEncoder.looksLikeStarRaster(bytes), isTrue);

      final gen = EscPosGenerator();
      gen.initialize();
      gen.text('hola');
      expect(StarRasterEncoder.looksLikeStarRaster(gen.getCommands()), isFalse);
    });
  });

  group('MonoBitmap', () {
    test('empaqueta MSB a la izquierda y crece solo', () {
      final bmp = MonoBitmap(16);
      bmp.setPixel(0, 0);
      bmp.setPixel(15, 2);
      expect(bmp.height, 3);
      expect(bmp.rows[0][0], 0x80);
      expect(bmp.rows[2][1], 0x01);
    });

    test('blit recorta lo que se sale por el costado', () {
      final bmp = MonoBitmap(8);
      bmp.blit([true, true, true], 3, 1, 6, 0);
      expect(bmp.rows[0][0], 0x03); // solo entraron los dos últimos puntos
    });

    test('trimTrailingBlankRows deja el contenido y quita el relleno', () {
      final bmp = MonoBitmap(8)..setPixel(0, 0);
      bmp.ensureHeight(50);
      bmp.trimTrailingBlankRows();
      expect(bmp.height, 1);
    });
  });

  group('Rasterizado', () {
    // El entorno de prueba dibuja cada glifo como un bloque sólido (fuente
    // de test), así que aquí no se valida la tipografía sino la GEOMETRÍA:
    // altura por línea, alineación y la banda inversa. El aspecto final se
    // verifica contra la impresora.

    /// ¿Hay tinta en la fila [y], entre [from] y [to]?
    bool inkInRow(MonoBitmap b, int y, int from, int to) {
      if (y >= b.height) return false;
      final row = b.rows[y];
      for (var x = from; x < to; x++) {
        if ((row[x ~/ 8] & (0x80 >> (x % 8))) != 0) return true;
      }
      return false;
    }

    test('cada línea ocupa una celda de 24 puntos', () async {
      final gen = EscPosGenerator(paperWidth: 58);
      gen.initialize();
      gen.text('A');
      gen.text('B');
      gen.text('C');

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        384,
      );
      // 3 líneas de 24 puntos; el recorte final solo quita blanco sobrante.
      expect(bmp.height, greaterThan(48));
      expect(bmp.height, lessThanOrEqualTo(72));
      expect(bmp.width, 384);
    });

    test('el interlineado pedido separa los renglones', () async {
      // La misma línea con y sin `ESC 3 40`: con interlineado el renglón
      // avanza 40 puntos en vez de 24, y esos 16 de diferencia son el aire
      // que el dueño pedía ver en la factura moderna.
      final pegado = EscPosGenerator(paperWidth: 58);
      pegado.initialize();
      pegado.text('A');
      pegado.text('B');

      final aireado = EscPosGenerator(paperWidth: 58);
      aireado.initialize();
      aireado.setLineSpacing(40);
      aireado.text('A');
      aireado.text('B');

      final bmpPegado = await TicketRasterizer.render(
        EscPosParser.parse(pegado.getCommands()),
        384,
      );
      final bmpAireado = await TicketRasterizer.render(
        EscPosParser.parse(aireado.getCommands()),
        384,
      );

      expect(bmpAireado.height, greaterThan(bmpPegado.height));
      // Y el aire está ENTRE los renglones, no todo al final: la franja justo
      // encima del segundo glifo tiene que quedar en blanco.
      expect(inkInRow(bmpAireado, 39, 0, 384), isFalse);
    });

    test('una línea en blanco avanza solo lo que pide el interlineado', () async {
      // Media línea de aire (`ModernInvoiceLayout.gap`): un renglón vacío no
      // tiene tinta que encimar, así que puede avanzar menos que el glifo.
      final gen = EscPosGenerator(paperWidth: 58);
      gen.initialize();
      gen.text('A');
      gen.setLineSpacing(20);
      gen.text('');
      gen.setLineSpacing(40);
      gen.text('B');

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        384,
      );
      // 24 (A) + 20 (aire) = el segundo glifo arranca en 44, no en 48.
      expect(inkInRow(bmp, 30, 0, 384), isFalse);
      expect(inkInRow(bmp, 56, 0, 384), isTrue);
    });

    test('en proporcional el aire NO depende del tamaño de la letra', () {
      // El TOTAL va en doble altura: su renglón tiene que crecer lo que crece
      // el glifo y ni un punto más. Multiplicar el renglón entero por el
      // factor —que es lo que se hacía— le regalaba el doble de aire a la
      // única línea que ya destacaba por tamaño.
      final normal = TicketRasterizer.proportionalPitch(1);
      final doble = TicketRasterizer.proportionalPitch(2);
      final cajaDelGlifo = normal - TicketRasterizer.proportionalLeading;

      expect(doble - normal, cajaDelGlifo);
      expect(doble - 2 * cajaDelGlifo, TicketRasterizer.proportionalLeading);
    });

    test('el renglón proporcional avanza el paso pedido', () async {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      gen.text('A');
      gen.text('B');

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        576,
        proportional: true,
      );

      bool filaConTinta(int y) {
        if (y >= bmp.height) return false;
        for (final b in bmp.rows[y]) {
          if (b != 0) return true;
        }
        return false;
      }

      final arranques = <int>[];
      var dentro = false;
      for (var y = 0; y < bmp.height; y++) {
        final tinta = filaConTinta(y);
        if (tinta && !dentro) arranques.add(y);
        dentro = tinta;
      }

      expect(arranques, hasLength(2), reason: 'dos renglones con tinta');
      expect(
        arranques[1] - arranques[0],
        TicketRasterizer.proportionalPitch(1),
      );
    });

    test('la regla se separa como cualquier otra línea', () async {
      // Una regla ocupaba un renglón entero de texto, así que quedaba con
      // casi el doble de aire que sus vecinas: "el espacio entre el lineado y
      // los textos es amplio, pero entre 2 líneas de texto es muy pegado".
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      gen.text('A');
      gen.text('.' * 48);
      gen.text('B');

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        576,
        proportional: true,
      );

      final huecos = <int>[];
      var blancoDesde = -1;
      for (var y = 0; y < bmp.height; y++) {
        final tinta = bmp.rows[y].any((b) => b != 0);
        if (!tinta && blancoDesde < 0) {
          blancoDesde = y;
        } else if (tinta && blancoDesde >= 0) {
          if (blancoDesde > 0) huecos.add(y - blancoDesde);
          blancoDesde = -1;
        }
      }

      expect(huecos, hasLength(2), reason: 'texto/regla y regla/texto');
      // Los dos huecos alrededor de la regla, iguales entre sí y del orden
      // del interlineado: el mismo aire que separa dos líneas de texto.
      expect((huecos[0] - huecos[1]).abs(), lessThanOrEqualTo(1));
      for (final hueco in huecos) {
        expect(hueco, closeTo(TicketRasterizer.proportionalLeading, 12));
      }
    });

    test('el nombre del producto arranca siempre en la misma columna', () async {
      // En el papel se veía "4x3 mille" arrancando antes que "4x3 coors
      // original": las columnas del medio se anclaban por la DERECHA, así que
      // cada nombre caía en un sitio distinto según su largo. Un nombre va
      // por la izquierda; solo las cifras se anclan por la derecha.
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      gen.textRow('1  4x3 mille', r'RD$527.34');
      gen.textRow('1  4x3 coors original', r'RD$585.94');

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        576,
        proportional: true,
      );

      bool ink(int y, int x) => (bmp.rows[y][x ~/ 8] & (0x80 >> (x % 8))) != 0;

      /// Primera columna con tinta pasada la cantidad, en el renglón [n].
      int inicioDelNombre(int n) {
        final desde = n * TicketRasterizer.proportionalPitch(1);
        final hasta = desde + TicketRasterizer.proportionalPitch(1);
        for (var x = 30; x < 300; x++) {
          for (var y = desde; y < hasta && y < bmp.height; y++) {
            if (ink(y, x)) return x;
          }
        }
        return -1;
      }

      final primero = inicioDelNombre(0);
      expect(primero, greaterThan(0));
      expect(inicioDelNombre(1), primero);
    });

    test('el blanco que trae un gráfico cuenta como aire', () async {
      // Un QR trae 4 módulos de quiet zone por norma y un logo suele traer su
      // propio margen. Si el margen del layout se suma a ese blanco, el
      // gráfico queda más lejos del texto que el resto del ticket.
      Future<int> huecoBajoImagen(int filasEnBlanco) async {
        const alto = 40;
        final pixeles = List<bool>.filled(24 * alto, false);
        for (var y = 0; y < alto - filasEnBlanco; y++) {
          for (var x = 0; x < 24; x++) {
            pixeles[y * 24 + x] = true;
          }
        }
        final ticket = ParsedTicket(
          ops: [
            TicketImageOp(width: 24, height: alto, pixels: pixeles),
            const TicketTextOp(text: 'Codigo de Seguridad: 1mjasw'),
          ],
          cut: false,
        );

        final bmp = await TicketRasterizer.render(
          ticket,
          576,
          proportional: true,
        );
        // El hueco entre la tinta de la imagen y la del texto.
        var y = 0;
        while (y < bmp.height && bmp.rows[y].any((b) => b != 0)) {
          y++;
        }
        final inicioHueco = y;
        while (y < bmp.height && !bmp.rows[y].any((b) => b != 0)) {
          y++;
        }
        return y - inicioHueco;
      }

      final sinMargenPropio = await huecoBajoImagen(0);
      final conMargenPropio = await huecoBajoImagen(20);
      expect(conMargenPropio, sinMargenPropio);
    });

    test('el texto de doble tamaño ocupa el doble de alto', () async {
      final normal = EscPosGenerator(paperWidth: 58);
      normal.initialize();
      normal.text('X');

      final grande = EscPosGenerator(paperWidth: 58);
      grande.initialize();
      grande.setTextSize(width: 2, height: 2);
      grande.text('X');

      final bmpNormal = await TicketRasterizer.render(
        EscPosParser.parse(normal.getCommands()),
        384,
      );
      final bmpGrande = await TicketRasterizer.render(
        EscPosParser.parse(grande.getCommands()),
        384,
      );
      expect(bmpGrande.height, greaterThan(bmpNormal.height));
    });

    test('la alineación decide de qué lado del papel cae la tinta', () async {
      final gen = EscPosGenerator(paperWidth: 58);
      gen.initialize();
      gen.text('L');
      gen.textRight('R');

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        384,
      );
      // Fila del medio de cada celda de 24.
      const yIzq = 12;
      const yDer = 36;
      expect(inkInRow(bmp, yIzq, 0, 40), isTrue);
      expect(inkInRow(bmp, yIzq, 200, 384), isFalse);
      expect(inkInRow(bmp, yDer, 344, 384), isTrue);
      expect(inkInRow(bmp, yDer, 0, 200), isFalse);
    });

    test('la franja inversa pinta la línea completa de negro', () async {
      final gen = EscPosGenerator(paperWidth: 58);
      gen.initialize();
      gen.setInverse(true);
      gen.text('PARA LLEVAR');
      gen.setInverse(false);

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        384,
      );
      // Los bordes de la banda son negros de lado a lado (el texto en
      // blanco vive adentro).
      expect(inkInRow(bmp, 1, 0, 384), isTrue);
      expect(inkInRow(bmp, 1, 370, 384), isTrue);
    });

    test('un ticket vacío no genera bitmap', () async {
      final gen = EscPosGenerator(paperWidth: 58);
      gen.initialize();
      gen.lineFeed(4);

      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        384,
      );
      expect(bmp.height, 0);
    });
  });
}
