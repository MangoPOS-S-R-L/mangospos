// Modo raster para impresoras ESC/POS ("modo calidad", estilo Square).
//
// En vez de mandar TEXTO para que lo dibuje la fuente de matriz de puntos del
// firmware, se manda el ticket ya dibujado con `GS v 0`. Es la única forma de
// igualar el acabado de Square: ningún ajuste de layout suple la fuente
// interna de la impresora.
//
// Lo que se fija acá:
//  1. El comando `GS v 0` sale bien formado y en bandas (una térmica barata
//     no traga un raster de ticket entero de una sola vez).
//  2. La GAVETA sobrevive. En el camino de texto el `ESC p` viaja con el
//     resto de los bytes; en raster ese flujo se DESCARTA, así que si no se
//     reemite el cajón deja de abrirse al cobrar en efectivo.
//  3. El modo es OPT-IN por impresora: nadie despierta un lunes con los
//     tickets tardando 5 segundos por Bluetooth sin haberlo pedido.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/esc_pos_raster_encoder.dart';
import 'package:mangopos/core/printing/star/escpos_parser.dart';
import 'package:mangopos/core/printing/star/mono_bitmap.dart';
import 'package:mangopos/core/printing/star/printer_emulation.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';

MonoBitmap _bitmap({required int width, required int height}) {
  final bmp = MonoBitmap(width);
  bmp.ensureHeight(height);
  // Un punto por fila para que no se recorte como fila en blanco.
  for (var y = 0; y < height; y++) {
    bmp.setPixel(0, y);
  }
  return bmp;
}

PrinterConfig _printer({Map<String, dynamic> config = const {}}) =>
    PrinterConfig(
      id: 'p1',
      businessId: 'b1',
      name: 'Generic POS80',
      type: 'network',
      connectionConfig: config,
      isActive: true,
      createdAt: DateTime(2026, 1, 1),
    );

/// Posiciones donde aparece la secuencia [needle] dentro de [haystack].
List<int> _findAll(List<int> haystack, List<int> needle) {
  final hits = <int>[];
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) hits.add(i);
  }
  return hits;
}

void main() {
  group('Comando GS v 0', () {
    test('emite una sola banda para un ticket corto', () {
      final bytes = EscPosRasterEncoder.encode(
        _bitmap(width: 576, height: 40),
        cut: false,
      );

      final bands = _findAll(bytes, [0x1D, 0x76, 0x30, 0x00]);
      expect(bands, hasLength(1));

      // GS v 0 m xL xH yL yH — 576 puntos = 72 bytes por fila, 40 filas.
      final header = bytes.sublist(bands.first, bands.first + 8);
      expect(header[4], 72, reason: 'xL: bytes por fila');
      expect(header[5], 0, reason: 'xH');
      expect(header[6], 40, reason: 'yL: filas de la banda');
      expect(header[7], 0, reason: 'yH');
    });

    test('parte en bandas los tickets largos', () {
      // 300 filas con bandas de 128 → 3 comandos.
      final bytes = EscPosRasterEncoder.encode(
        _bitmap(width: 576, height: 300),
        cut: false,
      );

      final bands = _findAll(bytes, [0x1D, 0x76, 0x30, 0x00]);
      expect(bands, hasLength(3));
    });

    test('a 58mm son 48 bytes por fila', () {
      expect(EscPosRasterEncoder.dotsForPaperWidth(58), 384);
      expect(EscPosRasterEncoder.dotsForPaperWidth(80), 576);

      final bytes = EscPosRasterEncoder.encode(
        _bitmap(width: 384, height: 10),
        cut: false,
      );
      final band = _findAll(bytes, [0x1D, 0x76, 0x30, 0x00]).first;
      expect(bytes[band + 4], 48);
    });

    test('avanza papel antes de cortar', () {
      final bytes = EscPosRasterEncoder.encode(_bitmap(width: 576, height: 10));

      // ESC J n (avance en puntos) antes del GS V.
      final feeds = _findAll(bytes, [0x1B, 0x4A]);
      expect(feeds, isNotEmpty, reason: 'sin avance la cuchilla muerde');
      final cut = _findAll(bytes, [0x1D, 0x56]).single;
      expect(feeds.last, lessThan(cut));
    });

    test('reconoce sus propios bytes para no rasterizar dos veces', () {
      final bytes = EscPosRasterEncoder.encode(_bitmap(width: 576, height: 10));
      expect(EscPosRasterEncoder.looksLikeEscPosRaster(bytes), isTrue);
      expect(EscPosRasterEncoder.looksLikeEscPosRaster([0x1B, 0x40]), isFalse);
    });
  });

  group('La gaveta sobrevive al raster', () {
    test('el parser recuerda el ESC p del ticket', () {
      final gen = EscPosGenerator()
        ..initialize()
        ..text('TOTAL 500.00')
        ..cut()
        ..openCashDrawer();

      final parsed = EscPosParser.parse(gen.getCommands());

      expect(parsed.cut, isTrue);
      expect(parsed.openCashDrawer, isTrue);
    });

    test('un ticket sin gaveta no la inventa', () {
      final gen = EscPosGenerator()
        ..initialize()
        ..text('TOTAL 500.00')
        ..cut();

      expect(EscPosParser.parse(gen.getCommands()).openCashDrawer, isFalse);
    });

    test('el encoder la reemite después del corte', () {
      final bytes = EscPosRasterEncoder.encode(
        _bitmap(width: 576, height: 10),
        openCashDrawer: true,
      );

      final cut = _findAll(bytes, [0x1D, 0x56]).single;
      final kick = _findAll(bytes, [0x1B, 0x70]).single;
      expect(
        kick,
        greaterThan(cut),
        reason: 'la gaveta se abre junto con el recibo saliendo',
      );
    });
  });

  group('Opt-in por impresora', () {
    test('por defecto una ESC/POS sigue en texto', () {
      expect(printerWantsEscPosRaster(_printer()), isFalse);
    });

    test('se activa con connection_config.render', () {
      expect(
        printerWantsEscPosRaster(_printer(config: {'render': 'raster'})),
        isTrue,
      );
      expect(
        printerWantsEscPosRaster(_printer(config: {'render': 'IMAGE'})),
        isTrue,
      );
    });

    test('una Star no entra por acá: ya va en raster obligatorio', () {
      final star = PrinterConfig(
        id: 'p2',
        businessId: 'b1',
        name: 'Star TSP143III',
        type: 'usb',
        connectionConfig: const {'render': 'raster'},
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
      );

      expect(resolvePrinterEmulation(star).isStarRaster, isTrue);
      expect(printerWantsEscPosRaster(star), isFalse);
    });
  });
}
