// Ancho del ticket en columnas ("Ancho del ticket" en Ajustes → Impresión).
//
// POR QUÉ EXISTE
//   El raster se compone a 48 columnas de 12 puntos en 80mm (576), que es el
//   cabezal de una térmica de 203 dpi. Una Epson TM-T88 y sus clones van a
//   180 dpi y su cabezal de 80mm mide 512: la imagen no cabe, la impresora
//   tira lo que sobra por la derecha y se cortan los montos ("RD$" sin la
//   cifra). Además cada punto mide más, así que la letra sale ~13% grande.
//   El dueño elige a mano las columnas (p. ej. 42) y sale el mismo ticket,
//   más angosto.
//
// Lo que se fija acá:
//  1. El ajuste viaja desde `connection_config`, acotado al papel, y el
//     default no se guarda.
//  2. Con menos columnas el ticket sale a `columnas × 12` puntos, sin cortar
//     nada y con el mismo layout (mismo ticket, escalado).
//  3. Un ticket angosto sale CENTRADO: `ESC a 1` en ESC/POS, con todas las
//     bandas del mismo ancho; relleno a los lados en Star.
//  4. Sin el ajuste, el raster y los bytes son los de siempre.
//  5. Un logo o QR que cabe se pega SIN re-muestrear (un QR re-muestreado se
//     lee peor); uno que no cabe se achica en vez de salir cortado.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/esc_pos_raster_encoder.dart';
import 'package:mangopos/core/printing/star/escpos_parser.dart';
import 'package:mangopos/core/printing/star/mono_bitmap.dart';
import 'package:mangopos/core/printing/star/print_width.dart';
import 'package:mangopos/core/printing/star/star_print_adapter.dart';
import 'package:mangopos/core/printing/star/ticket_rasterizer.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

PrinterConfig _printer({
  Map<String, dynamic> config = const {},
  int paperWidth = 80,
}) => PrinterConfig(
  id: 'p1',
  businessId: 'b1',
  name: 'Epson TM-T88V',
  type: 'network',
  connectionConfig: config,
  isActive: true,
  paperWidth: paperWidth,
  createdAt: DateTime(2026, 1, 1),
);

/// La precuenta de la foto que lo motivó: un producto, subtotal, ITBIS y
/// TOTAL, todos con el monto pegado al borde derecho.
PrintTicket _precheck() => PrintTicketService.generatePrecheck(
  order: Order(
    id: 'a785abcd-0000',
    sessionId: 'session-1',
    status: 'open',
    subtotal: 38.14,
    discounts: 0,
    serviceFee: 0,
    tax: 6.86,
    total: 45,
    createdAt: DateTime(2026, 10, 6, 8, 34, 45),
  ),
  items: [
    OrderItem(
      id: 'item-1',
      orderId: 'a785abcd-0000',
      productName: 'AROMA CAFE-CORTADITO 1152',
      quantity: 1,
      unitPrice: 45,
      subtotal: 38.14,
      discounts: 0,
      tax: 6.86,
      total: 45,
      isTakeout: false,
      status: 'pending',
      taxMode: 'inclusive',
      taxRate: 18,
      createdAt: DateTime(2026, 10, 6, 8, 30),
    ),
  ],
  tableName: 'MESA1',
  waiterName: 'ISAMAR',
  businessName: 'PETRONAN PUNAL',
  businessAddress: 'Autopista duarte kilometro 10 1/2',
  businessRnc: '131831151',
  template: 'modern',
  taxBreakdown: const [(label: 'ITBIS (18%)', amount: 6.86)],
);

bool _pixel(MonoBitmap bmp, int x, int y) =>
    (bmp.rows[y][x ~/ 8] & (0x80 >> (x % 8))) != 0;

/// Columna más a la derecha con tinta en todo el bitmap (-1 si no hay).
int _rightmostInk(MonoBitmap bmp) {
  var right = -1;
  for (var y = 0; y < bmp.height; y++) {
    final row = bmp.rows[y];
    for (var i = row.length - 1; i >= 0; i--) {
      final b = row[i];
      if (b == 0) continue;
      // El bit menos significativo encendido es el punto más a la derecha.
      var bit = 0;
      while ((b >> bit) & 1 == 0) {
        bit++;
      }
      final x = i * 8 + (7 - bit);
      if (x > right) right = x;
      break;
    }
  }
  return right;
}

/// Columna más a la izquierda con tinta en todo el bitmap.
int _leftmostInk(MonoBitmap bmp) {
  var left = bmp.width;
  for (var y = 0; y < bmp.height; y++) {
    for (var x = 0; x < left; x++) {
      if (_pixel(bmp, x, y)) {
        left = x;
        break;
      }
    }
  }
  return left;
}

/// Anchos (en bytes) de todas las bandas `GS v 0` de un trabajo raster.
List<int> _rasterBandWidths(List<int> bytes) {
  final widths = <int>[];
  var i = 0;
  while (i + 7 < bytes.length) {
    if (bytes[i] == 0x1D && bytes[i + 1] == 0x76 && bytes[i + 2] == 0x30) {
      final w = bytes[i + 4] | (bytes[i + 5] << 8);
      final h = bytes[i + 6] | (bytes[i + 7] << 8);
      widths.add(w);
      i += 8 + w * h;
      continue;
    }
    i++;
  }
  return widths;
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Ajuste por impresora', () {
    int columns(Object? value, {int paperWidth = 80}) => resolvePrintColumns(
      _printer(
        config: value == null ? const {} : {kPrintColumnsConfigKey: value},
        paperWidth: paperWidth,
      ),
    );

    test('sin la clave: 48 columnas en 80mm y 32 en 58mm', () {
      expect(columns(null), 48);
      expect(columns(null, paperWidth: 58), 32);
      expect(resolvePrintDots(_printer()), 576);
      expect(resolvePrintDots(_printer(paperWidth: 58)), 384);
    });

    test('lee las columnas elegidas: 42 = 504 puntos', () {
      expect(columns(42), 42);
      expect(columns('40'), 40);
      expect(
        resolvePrintDots(_printer(config: {kPrintColumnsConfigKey: 42})),
        504,
      );
    });

    test('un valor fuera de rango se acota al papel', () {
      // Más ancho que el papel no cabe; tan angosto no se lee.
      expect(columns(60), 48);
      expect(columns(10), minColumnsForPaperWidth(80));
      expect(columns(42, paperWidth: 58), 32);
      expect(columns('turbo'), 48);
    });

    test('el default NO se escribe en connection_config', () {
      // Si se guardara, cambiar el default en el código no llegaría nunca a
      // las impresoras ya dadas de alta.
      expect(printColumnsWireValue(48, 80), isNull);
      expect(printColumnsWireValue(32, 58), isNull);
      expect(printColumnsWireValue(42, 80), 42);
      expect(printColumnsWireValue(99, 80), isNull);
    });
  });

  group('Raster a cabezal angosto', () {
    test('la precuenta Moderna a 576 se sale de un cabezal de 512', () async {
      // Es el bug de la foto: los montos llegan al borde del layout, más
      // allá de lo que una TM-T88 puede imprimir.
      final ticket = _precheck();
      expect(ticket.preferRaster, isTrue);
      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(ticket.escPosCommands),
        576,
        proportional: true,
      );
      expect(_rightmostInk(bmp), greaterThanOrEqualTo(512));
    });

    test('con 42 columnas sale a 504 y los montos llegan al borde', () async {
      final ticket = EscPosParser.parse(_precheck().escPosCommands);
      final full = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
      );
      final narrow = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        printDots: 504,
      );

      expect(narrow.width, 504);
      // No se corta nada: lo que en el layout llegaba al borde derecho
      // ahora llega al borde del cabezal, y nada lo pasa.
      final rightFull = _rightmostInk(full);
      final rightNarrow = _rightmostInk(narrow);
      expect(rightNarrow, lessThan(504));
      expect(rightNarrow, closeTo(rightFull * 504 / 576, 4));
      // Es el MISMO ticket, escalado: el alto baja en la misma proporción.
      expect(narrow.height, closeTo(full.height * 504 / 576, 8));
    });

    test('lo centrado sigue centrado en el cabezal angosto', () async {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      gen.textCentered('PETRONAN PUNAL');
      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        576,
        proportional: true,
        printDots: 504,
      );
      final left = _leftmostInk(bmp);
      final right = 503 - _rightmostInk(bmp);
      expect((left - right).abs(), lessThanOrEqualTo(2));
    });

    test('sin el ajuste el raster es idéntico al de siempre', () async {
      // printDots igual al layout = camino sin escalar, punto por punto. Es
      // lo que garantiza que las impresoras que hoy imprimen bien no cambian.
      final ticket = EscPosParser.parse(_precheck().escPosCommands);
      final before = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
      );
      final same = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        printDots: 576,
      );
      expect(same.height, before.height);
      for (var y = 0; y < before.height; y++) {
        expect(same.rows[y], equals(before.rows[y]), reason: 'fila $y');
      }
    });

    test('la rejilla de celdas fijas también respeta las columnas', () async {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      gen.textRow('Subtotal', 'RD\$38.14');
      final bmp = await TicketRasterizer.render(
        EscPosParser.parse(gen.getCommands()),
        576,
        printDots: 504,
      );
      expect(bmp.width, 504);
      expect(_rightmostInk(bmp), inInclusiveRange(504 - 16, 503));
    });

    test('un QR que cabe se pega tal cual, sin re-muestrear', () async {
      const size = 40;
      final pixels = List<bool>.generate(
        size * size,
        (i) => ((i ~/ size) ~/ 4 + (i % size) ~/ 4).isEven,
      );
      final ticket = ParsedTicket(
        ops: [TicketImageOp(width: size, height: size, pixels: pixels)],
        cut: false,
      );
      final bmp = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        printDots: 504,
      );
      final dx = (504 - size) ~/ 2;
      final top = bmp.height - size;
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          expect(
            _pixel(bmp, dx + x, top + y),
            pixels[y * size + x],
            reason: 'módulo ($x, $y)',
          );
        }
      }
    });

    test('un logo más ancho que el ticket se achica, no se corta', () async {
      final ticket = ParsedTicket(
        ops: [
          TicketImageOp(
            width: 576,
            height: 60,
            pixels: List<bool>.filled(576 * 60, true),
          ),
        ],
        cut: false,
      );
      final bmp = await TicketRasterizer.render(
        ticket,
        576,
        proportional: true,
        printDots: 504,
      );
      expect(bmp.width, 504);
      expect(_leftmostInk(bmp), 0);
      expect(_rightmostInk(bmp), 503);
    });
  });

  group('Centrado de un ticket angosto', () {
    MonoBitmap bitmapDePrueba(int width) {
      final bmp = MonoBitmap(width);
      for (var y = 0; y < 300; y++) {
        bmp.setPixel(0, y);
        // Bandas de anchos distintos, como un ticket real: la primera llega
        // al borde y las siguientes se quedan en un tercio.
        bmp.setPixel(y < 128 ? width - 1 : width ~/ 3, y);
      }
      return bmp;
    }

    test('ESC/POS: ESC a 1 y todas las bandas del mismo ancho', () {
      final bytes = EscPosRasterEncoder.encode(
        bitmapDePrueba(504),
        center: true,
      );
      expect(bytes.sublist(0, 5), [0x1B, 0x40, 0x1B, 0x61, 0x01]);
      final widths = _rasterBandWidths(bytes);
      expect(widths, isNotEmpty);
      // Con el recorte derecho cada banda se centraría por su cuenta y el
      // ticket saldría en escalera.
      expect(widths.toSet(), {63});
      // Y la alineación vuelve a la izquierda antes del corte.
      expect(_indexOf(bytes, [0x1B, 0x61, 0x00]), greaterThan(0));
    });

    test('el guard sigue reconociendo un raster centrado', () {
      // Si no, un job que rebota por la cola se rasterizaría dos veces.
      final bytes = EscPosRasterEncoder.encode(
        bitmapDePrueba(504),
        center: true,
      );
      expect(EscPosRasterEncoder.looksLikeEscPosRaster(bytes), isTrue);
    });

    test('un ticket de TEXTO con logo sigue sin pasar por raster', () {
      // `initialize` emite `ESC t` detrás del `ESC @`: tolerar `ESC a` no
      // puede hacer que un ticket de texto se dé por rasterizado.
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      final bytes = [
        ...gen.getCommands(),
        0x1B, 0x61, 0x01, //
        0x1D, 0x76, 0x30, 0x00, 0x01, 0x00, 0x01, 0x00, 0xFF,
      ];
      expect(EscPosRasterEncoder.looksLikeEscPosRaster(bytes), isFalse);
    });

    test('sin centrar, el encoder no cambia', () {
      final bytes = EscPosRasterEncoder.encode(bitmapDePrueba(576));
      expect(_indexOf(bytes, [0x1B, 0x61]), -1);
      expect(_rasterBandWidths(bytes).toSet().length, greaterThan(1));
    });

    test('Star: se rellena a los lados hasta el cabezal', () {
      final narrow = bitmapDePrueba(504);
      final centered = narrow.centeredOn(576);
      expect(centered.width, 576);
      expect(centered.height, narrow.height);
      // (576 - 504) / 2 = 36 puntos, redondeado a byte: 32.
      expect(_pixel(centered, 32, 0), isTrue);
      expect(_pixel(centered, 31, 0), isFalse);
      expect(_rightmostInk(centered), 32 + 503);
    });
  });

  group('Cadena completa', () {
    test('con 42 columnas sale centrado y a 504 puntos', () async {
      final ticket = _precheck();
      final printer = _printer(config: {kPrintColumnsConfigKey: 42});
      final bytes = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: ticket.escPosCommands,
        preferRaster: ticket.preferRaster,
      );
      expect(bytes.sublist(0, 5), [0x1B, 0x40, 0x1B, 0x61, 0x01]);
      expect(_rasterBandWidths(bytes).toSet(), {63});

      // Un segundo paso (la cola offline rebota jobs) no lo toca.
      final again = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: bytes,
        preferRaster: true,
      );
      expect(again, equals(bytes));
    });

    test('sin el ajuste sale a 576 y sin centrar, como siempre', () async {
      final ticket = _precheck();
      final bytes = await StarPrintAdapter.adapt(
        printer: _printer(),
        escPosData: ticket.escPosCommands,
        preferRaster: ticket.preferRaster,
      );
      final widths = _rasterBandWidths(bytes);
      expect(widths.any((w) => w > 63), isTrue, reason: '$widths');
      expect(widths.every((w) => w <= 72), isTrue, reason: '$widths');
      expect(_indexOf(bytes, [0x1B, 0x61]), -1);
    });
  });
}
