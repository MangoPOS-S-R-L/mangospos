// Velocidad de impresión por impresora y pulso de gaveta sin ticket.
//
// Cubre las piezas puras: dónde se inserta el comando según el formato que
// sale (ESC/POS o raster Star), que no se duplique cuando el adaptador corre
// dos veces, y que no rompa la detección de raster ni el parser. El efecto
// real en el papel se valida contra hardware.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/star/esc_pos_raster_encoder.dart';
import 'package:mangopos/core/printing/star/escpos_parser.dart';
import 'package:mangopos/core/printing/star/print_speed.dart';
import 'package:mangopos/core/printing/star/star_print_adapter.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/presentation/cashier/services/cash_drawer_service.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';

PrinterConfig _printer({
  String name = 'Caja',
  Map<String, dynamic> connectionConfig = const {},
}) => PrinterConfig(
  id: 'p1',
  businessId: 'b1',
  name: name,
  type: 'network',
  ipAddress: '192.168.1.50',
  isActive: true,
  connectionConfig: connectionConfig,
  createdAt: DateTime(2026, 1, 1),
);

List<int> _ticket() {
  final gen = EscPosGenerator()
    ..initialize()
    ..text('FACTURA')
    ..text('Total 100.00')
    ..cut(feedLines: 3);
  return gen.getCommands();
}

const _epsonSpeedPrefix = [0x1D, 0x28, 0x4B, 0x02, 0x00, 0x32];

int _count(List<int> data, List<int> pattern) {
  var n = 0;
  for (var i = 0; i + pattern.length <= data.length; i++) {
    var match = true;
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) {
        match = false;
        break;
      }
    }
    if (match) n++;
  }
  return n;
}

void main() {
  group('Lectura del ajuste', () {
    test('sin print_speed → predeterminada de la impresora', () {
      expect(resolvePrintSpeed(_printer()), PrintSpeed.printerDefault);
    });

    test('lee connection_config.print_speed', () {
      expect(
        resolvePrintSpeed(_printer(connectionConfig: {'print_speed': 'slow'})),
        PrintSpeed.slow,
      );
      expect(
        resolvePrintSpeed(_printer(connectionConfig: {'print_speed': 'FAST'})),
        PrintSpeed.fast,
      );
    });

    test('un valor desconocido no inventa velocidad', () {
      expect(
        resolvePrintSpeed(_printer(connectionConfig: {'print_speed': 'x'})),
        PrintSpeed.printerDefault,
      );
    });

    test('wireValue ida y vuelta', () {
      for (final speed in PrintSpeed.values) {
        expect(PrintSpeed.fromWire(speed.wireValue), speed);
      }
    });
  });

  group('ESC/POS (GS ( K fn 50)', () {
    test('predeterminada deja los bytes idénticos', () {
      final data = _ticket();
      expect(applyPrintSpeed(data, PrintSpeed.printerDefault), data);
    });

    test('va justo después del ESC @ inicial, con el nivel correcto', () {
      final data = _ticket();
      for (final (speed, level) in [
        (PrintSpeed.slow, 1),
        (PrintSpeed.normal, 5),
        (PrintSpeed.fast, 9),
      ]) {
        final out = applyPrintSpeed(data, speed);
        expect(out.sublist(0, 2), [0x1B, 0x40]);
        expect(out.sublist(2, 9), [..._epsonSpeedPrefix, level]);
        expect(out.sublist(9), data.sublist(2));
      }
    });

    test('idempotente: el adaptador puede correr dos veces', () {
      final once = applyPrintSpeed(_ticket(), PrintSpeed.slow);
      final twice = applyPrintSpeed(once, PrintSpeed.slow);
      expect(twice, once);
      expect(_count(twice, _epsonSpeedPrefix), 1);
    });

    test('no toca bytes que no son un ticket (pulso de gaveta)', () {
      final kick = (EscPosGenerator()..openCashDrawer()).getCommands();
      expect(applyPrintSpeed(kick, PrintSpeed.slow), kick);
    });

    test('el parser lo salta completo: el texto no se contamina', () {
      final plain = EscPosParser.parse(_ticket());
      final withSpeed = EscPosParser.parse(
        applyPrintSpeed(_ticket(), PrintSpeed.slow),
      );
      expect(withSpeed.ops.length, plain.ops.length);
      expect(withSpeed.ops.toString(), plain.ops.toString());
      expect(withSpeed.cut, isTrue);
    });

    test('un raster ESC/POS con velocidad sigue detectándose como raster', () {
      const raster = [
        0x1B, 0x40, // ESC @
        0x1D, 0x76, 0x30, 0x00, 0x01, 0x00, 0x01, 0x00, 0xFF, // GS v 0
      ];
      expect(EscPosRasterEncoder.looksLikeEscPosRaster(raster), isTrue);
      expect(
        EscPosRasterEncoder.looksLikeEscPosRaster(
          applyPrintSpeed(raster, PrintSpeed.fast),
        ),
        isTrue,
      );
    });

    test('StarPrintAdapter aplica la velocidad de la impresora', () async {
      final printer = _printer(connectionConfig: {'print_speed': 'normal'});
      final out = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: _ticket(),
      );
      expect(out.sublist(2, 9), [..._epsonSpeedPrefix, 5]);

      final again = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: out,
      );
      expect(_count(again, _epsonSpeedPrefix), 1);
    });
  });

  group('Star raster (ESC * r Q)', () {
    const starJob = [
      0x1B, 0x40, // ESC @
      0x1B, 0x2A, 0x72, 0x41, // ESC * r A
      0x1B, 0x2A, 0x72, 0x50, 0x30, 0x00, // ESC * r P 0 NUL
      0x62, 0x01, 0x00, 0x00, // b — una fila
      0x1B, 0x2A, 0x72, 0x42, // ESC * r B
    ];

    test('va después de ESC * r A con el dígito ASCII', () {
      for (final (speed, digit) in [
        (PrintSpeed.fast, 0x30),
        (PrintSpeed.normal, 0x31),
        (PrintSpeed.slow, 0x32),
      ]) {
        final out = applyPrintSpeed(starJob, speed);
        expect(out.sublist(6, 12), [0x1B, 0x2A, 0x72, 0x51, digit, 0x00]);
        expect(out.sublist(12), starJob.sublist(6));
        // No se cuela el comando ESC/POS.
        expect(_count(out, _epsonSpeedPrefix), 0);
      }
    });

    test('idempotente', () {
      final once = applyPrintSpeed(starJob, PrintSpeed.slow);
      expect(applyPrintSpeed(once, PrintSpeed.slow), once);
    });
  });

  group('Pulso de gaveta sin ticket', () {
    test('ESC/POS: el mismo ESC p del recibo en efectivo', () {
      expect(
        CashDrawerService.kickBytesFor(_printer()),
        [0x1B, 0x70, 0x00, 0x19, 0xFA],
      );
    });

    test('Star TSP100: ESC * r D 1 dentro del modo raster', () {
      final kick = CashDrawerService.kickBytesFor(
        _printer(name: 'Star TSP143III'),
      );
      expect(_count(kick, [0x1B, 0x2A, 0x72, 0x44, 0x31, 0x00]), 1);
      expect(_count(kick, [0x1B, 0x70]), 0);
    });

    test('el adaptador deja el pulso Star intacto (no lo rasteriza)', () async {
      final printer = _printer(name: 'Star TSP143III');
      final kick = CashDrawerService.kickBytesFor(printer);
      final out = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: kick,
      );
      expect(out, kick);
    });

    test('el adaptador no le agrega velocidad al pulso ESC/POS', () async {
      final printer = _printer(connectionConfig: {'print_speed': 'slow'});
      final kick = CashDrawerService.kickBytesFor(printer);
      final out = await StarPrintAdapter.adapt(
        printer: printer,
        escPosData: kick,
      );
      expect(out, kick);
    });
  });
}
