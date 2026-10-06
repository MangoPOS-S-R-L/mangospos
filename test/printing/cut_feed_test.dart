// Avance extra antes del corte ("Avance antes del corte" en Ajustes →
// Impresión).
//
// POR QUÉ EXISTE
//   La cuchilla va por delante del cabezal y cuánto depende del modelo. En la
//   impresora que lo motivó, el "Cambio" y el "Gracias por su preferencia" de
//   cada factura quedaban del otro lado del corte y salían arriba de la
//   factura siguiente. Subir el avance para todos gastaría papel en todas las
//   demás: es un ajuste por impresora.
//
// Lo que se fija acá:
//  1. El ajuste viaja desde `connection_config`, acotado, y el default no se
//     guarda.
//  2. Los renglones van JUSTO antes del corte final — en texto y en raster —
//     y la gaveta sigue después del corte.
//  3. Es idempotente: un job que rebota por la cola no suma avance en cada
//     vuelta.
//  4. Sin el ajuste, o sin corte al final, los bytes no se tocan.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/cut_feed.dart';
import 'package:mangopos/core/printing/star/esc_pos_raster_encoder.dart';
import 'package:mangopos/core/printing/star/mono_bitmap.dart';
import 'package:mangopos/core/printing/star/print_width.dart';
import 'package:mangopos/core/printing/star/star_print_adapter.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

PrinterConfig _printer({
  Map<String, dynamic> config = const {},
  String name = 'Caja principal',
}) => PrinterConfig(
  id: 'p1',
  businessId: 'b1',
  name: name,
  type: 'network',
  connectionConfig: config,
  isActive: true,
  paperWidth: 80,
  createdAt: DateTime(2026, 1, 1),
);

/// El bloque que se agrega delante del corte: marca, `ESC 2` y N saltos.
List<int> _block(int lines) => [
  0x1B, 0x4A, 0x00, //
  0x1B, 0x32,
  for (var i = 0; i < lines; i++) 0x0A,
];

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

List<int> _textTicket() {
  final gen = EscPosGenerator(paperWidth: 80);
  gen.initialize();
  gen.text('Cambio                                  RD\$705.00');
  gen.text('Gracias por su preferencia');
  gen.cut(feedLines: EscPosGenerator.safeCutFeedLines);
  return gen.getCommands();
}

PrintTicket _modernPrecheck() => PrintTicketService.generatePrecheck(
  order: Order(
    id: 'e647cddb-0000',
    sessionId: 'session-1',
    status: 'open',
    subtotal: 250,
    discounts: 0,
    serviceFee: 0,
    tax: 45,
    total: 295,
    createdAt: DateTime(2026, 10, 6, 10, 40, 10),
  ),
  items: [
    OrderItem(
      id: 'item-1',
      orderId: 'e647cddb-0000',
      productName: 'MOTTS APPLE',
      quantity: 1,
      unitPrice: 100,
      subtotal: 84.75,
      discounts: 0,
      tax: 15.25,
      total: 100,
      isTakeout: false,
      status: 'pending',
      taxMode: 'inclusive',
      taxRate: 18,
      createdAt: DateTime(2026, 10, 6, 10, 30),
    ),
  ],
  tableName: 'quick',
  businessName: '007 BAR N SNACK',
  template: 'modern',
  taxBreakdown: const [(label: 'ITBIS (18%)', amount: 45)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Ajuste por impresora', () {
    int lines(Object? value) => resolveCutFeedLines(
      _printer(config: value == null ? const {} : {kCutFeedConfigKey: value}),
    );

    test('sin la clave no hay avance extra', () {
      expect(lines(null), 0);
    });

    test('lee los renglones guardados y los acota', () {
      expect(lines(4), 4);
      expect(lines('3'), 3);
      expect(lines(99), kMaxCutFeedLines);
      expect(lines(-2), 0);
      expect(lines('turbo'), 0);
    });

    test('el default NO se escribe en connection_config', () {
      expect(cutFeedWireValue(0), isNull);
      expect(cutFeedWireValue(4), 4);
      expect(cutFeedWireValue(99), kMaxCutFeedLines);
    });
  });

  group('Dónde va el avance', () {
    test('ticket de texto: justo antes del corte final', () {
      final original = _textTicket();
      final out = applyCutFeed(original, 4);
      final cutAt = original.length - 3; // GS V 0
      expect(out.sublist(0, cutAt), original.sublist(0, cutAt));
      expect(out.sublist(cutAt, cutAt + _block(4).length), _block(4));
      expect(out.sublist(out.length - 3), [0x1D, 0x56, 0x00]);
    });

    test('raster con gaveta: el avance antes del corte, la gaveta después', () {
      final bmp = MonoBitmap(576);
      for (var y = 0; y < 40; y++) {
        bmp.setPixel(10, y);
      }
      final original = EscPosRasterEncoder.encode(
        bmp,
        openCashDrawer: true,
      );
      final out = applyCutFeed(original, 3);
      // Termina en corte + pulso de gaveta, igual que antes.
      expect(out.sublist(out.length - 8), [
        0x1D, 0x56, 0x00, //
        0x1B, 0x70, 0x00, 0x19, 0xFA,
      ]);
      expect(
        out.sublist(out.length - 8 - _block(3).length, out.length - 8),
        _block(3),
      );
      // Y el guard de raster lo sigue reconociendo (mira el principio).
      expect(EscPosRasterEncoder.looksLikeEscPosRaster(out), isTrue);
    });

    test('también con los cortes viejos (ESC m) de la impresión de muestra', () {
      final original = [0x1B, 0x40, 0x41, 0x0A, 0x0A, 0x1B, 0x6D];
      final out = applyCutFeed(original, 2);
      expect(out, [0x1B, 0x40, 0x41, 0x0A, 0x0A, ..._block(2), 0x1B, 0x6D]);
    });
  });

  group('Sin cambios cuando no corresponde', () {
    test('con 0 renglones los bytes son los mismos', () {
      final original = _textTicket();
      expect(identical(applyCutFeed(original, 0), original), isTrue);
    });

    test('sin corte al final no se toca nada', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      gen.text('Sin corte');
      final original = gen.getCommands();
      expect(applyCutFeed(original, 4), original);
    });

    test('bytes de imagen que terminan como un corte no se toman por uno', () {
      // Un corte de verdad siempre viene detrás de un avance.
      final original = [0x1D, 0x76, 0x30, 0x00, 0x03, 0x00, 0x01, 0x00,
        0x55, 0x1D, 0x56, 0x00];
      expect(applyCutFeed(original, 4), original);
    });

    test('Star: su raster corta con sus propios comandos y no se toca', () async {
      final ticket = _modernPrecheck();
      final star = _printer(
        name: 'Star TSP143III',
        config: {kCutFeedConfigKey: 4},
      );
      final plain = _printer(name: 'Star TSP143III');
      final withSetting = await StarPrintAdapter.adapt(
        printer: star,
        escPosData: ticket.escPosCommands,
        preferRaster: true,
      );
      final without = await StarPrintAdapter.adapt(
        printer: plain,
        escPosData: ticket.escPosCommands,
        preferRaster: true,
      );
      expect(withSetting, equals(without));
    });
  });

  group('Cadena completa', () {
    test('factura Moderna con 42 columnas y +4 renglones', () async {
      final ticket = _modernPrecheck();
      final printer = _printer(
        config: {kCutFeedConfigKey: 4, kPrintColumnsConfigKey: 42},
      );
      final out = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: ticket.escPosCommands,
        preferRaster: ticket.preferRaster,
      );
      expect(EscPosRasterEncoder.looksLikeEscPosRaster(out), isTrue);
      final at = _indexOf(out, [..._block(4), 0x1D, 0x56, 0x00]);
      expect(at, greaterThan(0));
      expect(at + _block(4).length + 3, out.length);
    });

    test('un job que rebota por la cola no suma avance otra vez', () async {
      final ticket = _modernPrecheck();
      final printer = _printer(config: {kCutFeedConfigKey: 4});
      final once = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: ticket.escPosCommands,
        preferRaster: true,
      );
      final twice = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: once,
        preferRaster: true,
      );
      expect(twice, equals(once));

      // Y en texto igual.
      final text = applyCutFeed(_textTicket(), 4);
      expect(applyCutFeed(text, 4), equals(text));
    });

    test('sin el ajuste el adaptador devuelve lo de siempre', () async {
      final original = _textTicket();
      final out = await StarPrintAdapter.adapt(
        printer: _printer(),
        escPosData: original,
      );
      expect(out, equals(original));
    });
  });
}
