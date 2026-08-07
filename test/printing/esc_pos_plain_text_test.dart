// Espejo en texto plano del EscPosGenerator — la fuente de lo que ve el
// cajero en el "modo sin impresora" y de lo que se exporta a PDF.
//
// Lo crítico acá es doble: que el texto refleje el layout del papel, y que
// agregarlo NO haya cambiado un solo byte ESC/POS.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/services/printing/esc_pos_generator.dart';

void main() {
  group('EscPosGenerator.getPlainText', () {
    test('respeta columnas de textRow y el ancho del papel', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.textRow('Subtotal:', 'RD\$ 678.00');

      final lines = gen.getPlainText().split('\n');
      expect(lines, hasLength(1));
      expect(lines.first.length, 48); // 80mm = 48 columnas
      expect(lines.first, startsWith('Subtotal:'));
      expect(lines.first, endsWith('RD\$ 678.00'));
    });

    test('centra y alinea a la derecha como lo haría el firmware', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.textCentered('FACTURA');
      gen.textRight('fin');
      gen.text('izquierda');

      final lines = gen.getPlainText().split('\n');
      expect(lines[0].trimLeft(), 'FACTURA');
      expect(lines[0].indexOf('F'), (48 - 'FACTURA'.length) ~/ 2);
      expect(lines[1], 'fin'.padLeft(48));
      expect(lines[2], 'izquierda');
    });

    test('separator y lineFeed producen las mismas líneas que el papel', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.text('arriba');
      gen.separator();
      gen.lineFeed(2);
      gen.text('abajo');

      expect(gen.getPlainText().split('\n'), [
        'arriba',
        '-' * 48,
        '',
        '',
        'abajo',
      ]);
    });

    test('el ancho sigue al tamaño de texto (doble ancho = 24 columnas)', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.setTextSize(width: 2, height: 2);
      gen.textRow('TOTAL:', 'RD\$ 800.00');

      expect(gen.getPlainText().length, 24);
    });

    test('58mm usa 32 columnas', () {
      final gen = EscPosGenerator(paperWidth: 58);
      gen.textRow('Total:', '100.00');

      expect(gen.getPlainText().length, 32);
    });

    test('los gráficos aparecen solo si el caller pasa un marcador', () {
      final conMarcador = EscPosGenerator(paperWidth: 80)
        ..appendRaw([0x1B, 0x2A], plainPlaceholder: '[ QR ]');
      final sinMarcador = EscPosGenerator(paperWidth: 80)
        ..appendRaw([0x1B, 0x2A]);

      expect(conMarcador.getPlainText(), '[ QR ]');
      expect(sinMarcador.getPlainText(), isEmpty);
      // El marcador es solo pantalla: los bytes salen idénticos.
      expect(conMarcador.getCommands(), sinMarcador.getCommands());
    });

    test('recorta los feeds finales que preceden al corte', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.text('contenido');
      gen.lineFeed(4);
      gen.cut(feedLines: EscPosGenerator.safeCutFeedLines);

      expect(gen.getPlainText(), 'contenido');
    });

    test('el espejo no altera los bytes ESC/POS', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.initialize();
      gen.setBold(true);
      gen.text('HOLA');
      gen.setBold(false);

      expect(gen.getCommands(), [
        0x1B, 0x40, // ESC @
        0x1B, 0x74, 16, // ESC t 16
        0x1B, 0x45, 1, // ESC E 1
        0x48, 0x4F, 0x4C, 0x41, // HOLA
        0x0A, // LF
        0x1B, 0x45, 0, // ESC E 0
      ]);
      expect(gen.getPlainText(), 'HOLA');
    });

    test('clear() limpia bytes y texto a la vez', () {
      final gen = EscPosGenerator(paperWidth: 80);
      gen.text('algo');
      gen.clear();

      expect(gen.getCommands(), isEmpty);
      expect(gen.getPlainText(), isEmpty);
    });
  });
}
