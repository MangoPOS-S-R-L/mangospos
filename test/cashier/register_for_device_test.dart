import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';

/// Que registradora opera ESTE equipo. Es lo que separa dos cajas fisicas:
/// la registradora elegida define la impresora de recibos
/// (`cash_registers.receipt_printer_id`) que usan factura, cierre y
/// movimientos de esta estacion.
void main() {
  Map<String, dynamic> reg(String id, String name, {bool active = true}) =>
      {'id': id, 'name': name, 'is_active': active};

  group('pickRegisterForDevice', () {
    test('sin eleccion previa toma la primera', () {
      final registers = [reg('r1', 'Caja 1'), reg('r2', 'Caja 2')];

      expect(
        CashierViewModel.pickRegisterForDevice(registers, null)['id'],
        'r1',
      );
    });

    test('respeta la registradora elegida por el equipo', () {
      // El equipo de la barra opera "Caja 2" aunque "Caja 1" sea la primera.
      final registers = [reg('r1', 'Caja 1'), reg('r2', 'Caja 2')];

      expect(
        CashierViewModel.pickRegisterForDevice(registers, 'r2')['id'],
        'r2',
      );
    });

    test('si la elegida ya no esta en la lista cae a la primera', () {
      // La registradora se desactivo desde otro equipo: no dejamos al POS
      // colgado de una caja que ya no existe.
      final registers = [reg('r1', 'Caja 1')];

      expect(
        CashierViewModel.pickRegisterForDevice(registers, 'r-borrada')['id'],
        'r1',
      );
    });

    test('preferencia vacia se ignora', () {
      final registers = [reg('r1', 'Caja 1'), reg('r2', 'Caja 2')];

      expect(
        CashierViewModel.pickRegisterForDevice(registers, '')['id'],
        'r1',
      );
    });

    test('dos equipos con la misma lista resuelven cajas distintas', () {
      // El caso completo: misma consulta, dos resultados, cada equipo con su
      // impresora.
      final registers = [reg('r1', 'Caja 1'), reg('r2', 'Caja 2')];

      final equipoA = CashierViewModel.pickRegisterForDevice(registers, 'r1');
      final equipoB = CashierViewModel.pickRegisterForDevice(registers, 'r2');

      expect(equipoA['name'], 'Caja 1');
      expect(equipoB['name'], 'Caja 2');
    });
  });
}
