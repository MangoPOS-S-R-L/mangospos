// Ticket del reporte de abonos (impresora térmica).
//
// Lo que el dueño pidió ver en papel: a nombre de quién está cada abono, su
// referencia y su balance. Y que a 58mm (32 columnas) nada se salga del
// papel: el firmware corta la línea a mitad de palabra.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/data/models/table_deposit_report.dart';
import 'package:mangopos/services/printing/table_deposit_report_ticket.dart';

int _widestLine(String? text) => (text ?? '')
    .split('\n')
    .map((line) => line.trimRight().length)
    .fold(0, (a, b) => a > b ? a : b);

void main() {
  final report = TableDepositReport(
    accounts: [
      TableDepositReportAccount(
        accountId: 'acc-1',
        tableId: 't1',
        tableLabel: 'Mesa 5',
        zoneName: 'Terraza',
        holderName: 'Juan Pérez de los Santos Almonte',
        references: const ['TRX-000123456789', 'VOUCHER-99'],
        deposited: 10000,
        consumed: 3500,
        balance: 6500,
      ),
      const TableDepositReportAccount(
        accountId: 'acc-2',
        tableId: 't2',
        tableLabel: 'VIP 1',
        balance: 0,
        deposited: 2000,
        consumed: 1500,
        returned: 500,
      ),
    ],
    movements: [
      TableDepositReportMovement(
        id: 'm2',
        accountId: 'acc-1',
        tableId: 't1',
        tableLabel: 'Mesa 5',
        type: 'consumption',
        amount: -3500,
        balanceAfter: 6500,
        createdAt: DateTime(2026, 9, 19, 16),
        holderName: 'Juan Pérez de los Santos Almonte',
      ),
      TableDepositReportMovement(
        id: 'm1',
        accountId: 'acc-1',
        tableId: 't1',
        tableLabel: 'Mesa 5',
        type: 'deposit',
        amount: 10000,
        balanceAfter: 10000,
        createdAt: DateTime(2026, 9, 19, 10, 5),
        holderName: 'Juan Pérez de los Santos Almonte',
        reference: 'TRX-000123456789',
        methodName: 'Transferencia',
      ),
    ],
  );

  String ticket({int paperWidth = 80, TableDepositReport? data}) =>
      TableDepositReportTicket.generate(
        report: data ?? report,
        businessName: 'Restaurante La Esquina del Sabor',
        from: DateTime(2026, 9, 19),
        to: DateTime(2026, 9, 20),
        paperWidth: paperWidth,
        printedAt: DateTime.utc(2026, 9, 19, 22),
      ).rawText ??
      '';

  final money = BusinessCurrency.fallbackDop.formatAmount;

  test('trae nombre, referencia y balance de cada mesa', () {
    final raw = ticket();
    expect(raw, contains('REPORTE DE ABONOS'));
    expect(raw, contains('Rango: 19/09/2026'));
    expect(raw, contains('MESA 5 - Terraza'));
    expect(raw, contains('JUAN PÉREZ DE LOS SANTOS ALMONTE'));
    expect(raw, contains('Ref: TRX-000123456789, VOUCHER-99'));
    expect(raw, contains(money(6500)));
    expect(raw, contains('BALANCE:'));
    expect(raw, contains('TOTAL BALANCE:'));
  });

  test('una mesa sin nombre ni referencia no inventa datos', () {
    final raw = ticket();
    expect(raw, contains('VIP 1'));
    expect(raw, contains('A nombre de: -'));
    expect(raw, contains('Devuelto/movido:'));
  });

  test('lista los abonos del rango, no cada consumo', () {
    final raw = ticket();
    final section = raw.substring(raw.indexOf('ABONOS DEL RANGO'));
    expect(section, contains('19/09/2026 10:05'));
    expect(section, contains('Ref: TRX-000123456789 - Transferencia'));
    expect(section, contains(money(10000)));
    expect(section, isNot(contains(money(3500))));
    expect(section, contains('Total abonado (1):'));
  });

  test('la hora de impresión sale en hora de RD', () {
    // 22:00Z = 18:00 en RD.
    expect(ticket(), contains('Impreso: 19/09/2026 18:00'));
  });

  test('a 58mm ninguna línea pasa de 32 columnas', () {
    expect(_widestLine(ticket(paperWidth: 58)), lessThanOrEqualTo(32));
  });

  test('a 80mm ninguna línea pasa de 48 columnas', () {
    expect(_widestLine(ticket()), lessThanOrEqualTo(48));
  });

  test('reporte vacío: imprime el aviso en vez de tablas vacías', () {
    final raw = ticket(data: TableDepositReport.empty);
    expect(raw, contains('No hay mesas con saldo'));
    expect(raw, contains('Sin abonos en el rango.'));
  });
}
