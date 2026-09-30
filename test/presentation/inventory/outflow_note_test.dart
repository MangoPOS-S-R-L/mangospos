// La nota de una salida trae el motivo de prefijo («Vencido — nevera 2»). La
// ficha del insumo, el A4 y la reimpresión lo separan con el mismo helper.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/utils/outflow_note.dart';

void main() {
  test('motivo + detalle', () {
    final n = splitOutflowNote('Vencido — nevera 2');
    expect(n.reason, 'Vencido');
    expect(n.detail, 'nevera 2');
  });

  test('solo el motivo', () {
    final n = splitOutflowNote('Rotura / dañado');
    expect(n.reason, 'Rotura / dañado');
    expect(n.detail, '');
  });

  test('una nota libre vieja es detalle de una «Merma»', () {
    final n = splitOutflowNote('se cayó la caja');
    expect(n.reason, 'Merma');
    expect(n.detail, 'se cayó la caja');
  });

  test('un prefijo que no es motivo de salida no se toma como motivo', () {
    final n = splitOutflowNote('Conteo físico — algo');
    expect(n.reason, 'Merma');
    expect(n.detail, 'Conteo físico — algo');
  });
}
