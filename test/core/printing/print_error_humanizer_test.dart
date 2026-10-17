import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/print_error_humanizer.dart';

void main() {
  group('errores de datos antes de enviar el comprobante', () {
    final cases = <({String reason, String title})>[
      (
        reason: 'No se encontró el comprobante original. Recarga el historial.',
        title: 'Comprobante original no disponible',
      ),
      (
        reason:
            'No se identificó el comprobante original. Recarga el historial.',
        title: 'Comprobante original no disponible',
      ),
      (
        reason:
            'El comprobante emitido tiene importes incompletos. '
            'Recarga el historial antes de reimprimir.',
        title: 'Importes del comprobante incompletos',
      ),
      (
        reason:
            'Factura inconsistente: el comprobante contiene importes inválidos. '
            'Recarga el comprobante original antes de reimprimir.',
        title: 'Importes del comprobante incompletos',
      ),
      (
        reason:
            'No se puede reimprimir una factura en cero con un cobro registrado. '
            'Recarga el comprobante original.',
        title: 'Total del comprobante no válido',
      ),
      (
        reason:
            'El detalle está incompleto o no coincide con el comprobante emitido. '
            'No se imprimió: revisa los productos originales antes de reimprimir.',
        title: 'Detalle del comprobante incompleto',
      ),
      (
        reason:
            'Faltan los productos del comprobante original. No se envió papel: '
            'recarga el historial antes de reimprimir.',
        title: 'Detalle del comprobante incompleto',
      ),
      (
        reason:
            'No se puede imprimir la factura: faltan los productos del '
            'comprobante. Recarga la venta antes de reimprimir.',
        title: 'Detalle del comprobante incompleto',
      ),
      (
        reason:
            'Factura inconsistente: el subtotal, impuestos, servicio, delivery '
            'y descuento suman 6800.00, pero el total guardado es 6900.00. '
            'Recarga el comprobante original antes de reimprimir.',
        title: 'Datos del comprobante no coinciden',
      ),
      (
        reason:
            'Factura inconsistente: 1 de 2 productos no pertenecen a la orden '
            'original. No se imprime: el comprobante ampararía mercancía de '
            'otra cuenta.',
        title: 'Datos del comprobante no coinciden',
      ),
    ];

    for (final spec in cases) {
      test(spec.reason, () {
        final result = humanizePrintError(
          StateError(spec.reason),
          printerName: 'Caja',
        );

        expect(result.title, spec.title);
        expect(result.message, spec.reason);
        expect(result.message, isNot(contains('Bad state:')));
        expect(result.hint, contains('Recarga'));
        expect(result.hint, isNot(contains('encendida')));
        expect(result.hint, isNot(contains('conectada')));
      });
    }
  });

  test('un error mecánico de papel conserva su diagnóstico', () {
    final result = humanizePrintError(Exception('Impresora sin papel'));

    expect(result.title, 'Problema con la impresora');
    expect(result.hint, contains('papel'));
  });

  test('una conexión rechazada conserva el nombre de la impresora', () {
    final result = humanizePrintError(
      Exception('Connection refused'),
      printerName: 'Caja',
    );

    expect(result.title, 'Impresora no responde');
    expect(result.message, contains('«Caja»'));
  });

  test('un StateError ajeno a integridad conserva el fallback', () {
    final result = humanizePrintError(StateError('Error desconocido'));

    expect(result.title, 'No se pudo imprimir');
  });
}
