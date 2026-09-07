// Volante de movimiento de caja (ingreso, retiro, gasto).
//
// El volante se entrega a quien recibe la plata y se firma. Antes la raya
// de firma salía pegada al MONTO: no quedaba papel donde apoyar la mano y
// la firma terminaba encima del texto. Estas pruebas fijan el aire mínimo
// entre el monto y la raya, y que la reimpresión salga marcada para que no
// se confunda con el volante original (los dos se firman igual).

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';

/// Renglones en blanco entre el MONTO y la raya de firma.
int _blankLinesBeforeSignature(String raw) {
  final lines = raw.split('\n');
  final signatureIndex = lines.indexWhere((l) => l.contains('_' * 30));
  if (signatureIndex < 0) return -1;
  var blanks = 0;
  for (var i = signatureIndex - 1; i >= 0; i--) {
    if (lines[i].trim().isEmpty) {
      blanks++;
    } else {
      break;
    }
  }
  return blanks;
}

void main() {
  String voucher({
    String movementType = 'expense',
    bool isReprint = false,
    String? approvedByName,
    int paperWidth = 80,
  }) {
    final ticket = PrintTicketService.generateCashMovementReceipt(
      businessName: 'Restaurante La Esquina del Sabor',
      movementType: movementType,
      amount: 1500,
      reasonLabel: 'Compra de gas para la cocina',
      cashierName: 'Juana',
      approvedByName: approvedByName,
      sessionId: 'session-12345678',
      when: DateTime(2026, 1, 1, 12, 0),
      paperWidth: paperWidth,
      isReprint: isReprint,
    );
    return ticket.rawText ?? '';
  }

  group('Espacio para firmar', () {
    test('el gasto deja aire entre el monto y la raya de firma', () {
      // 4 renglones de aire + el que ya había antes de la raya.
      expect(_blankLinesBeforeSignature(voucher()), greaterThanOrEqualTo(4));
    });

    test('el retiro deja el mismo aire que el gasto', () {
      expect(
        _blankLinesBeforeSignature(voucher(movementType: 'withdrawal')),
        equals(_blankLinesBeforeSignature(voucher())),
      );
    });

    test('la raya de firma sigue rotulada', () {
      final raw = voucher();
      expect(raw, contains('_' * 30));
      expect(raw, contains('Firma'));
    });

    test('a 58mm el aire no rompe el ancho del papel', () {
      final raw = voucher(paperWidth: 58);
      final widest = raw
          .split('\n')
          .map((l) => l.trimRight().length)
          .fold<int>(0, (a, b) => a > b ? a : b);
      expect(widest, lessThanOrEqualTo(32));
    });
  });

  group('Reimpresión', () {
    test('el volante original NO lleva la marca', () {
      expect(voucher(), isNot(contains('REIMPRESIÓN')));
    });

    test('la reimpresión sale marcada', () {
      expect(voucher(isReprint: true), contains('REIMPRESIÓN'));
    });

    test('la reimpresión conserva el espacio para firmar', () {
      expect(
        _blankLinesBeforeSignature(voucher(isReprint: true)),
        greaterThanOrEqualTo(4),
      );
    });
  });

  group('Autorización', () {
    test('imprime quién autorizó cuando el movimiento pidió PIN', () {
      expect(
        voucher(approvedByName: 'María Gómez'),
        contains('Autorizado por: MARÍA GÓMEZ'),
      );
    });

    test('sin autorizador no aparece el renglón', () {
      expect(voucher(), isNot(contains('Autorizado por')));
    });
  });
}
