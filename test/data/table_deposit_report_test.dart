// Reporte de abonos de mesa.
//
// El saldo vive en la mesa FÍSICA y `holder_name` se sobrescribe con cada
// cliente nuevo. Estas pruebas fijan que el reporte no le atribuya el dinero
// (ni la referencia) de un abono anterior al cliente de hoy, y que los
// totales del rango salgan de los movimientos del rango en hora de RD.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/table_deposit_report.dart';

Map<String, dynamic> _account({
  required String id,
  required double balance,
  String? holder,
  String? label = 'Mesa 5',
  String code = 'M5',
  String? zone = 'Terraza',
  String tableId = 'table-1',
}) => {
  'id': id,
  'table_id': tableId,
  'balance': balance,
  'holder_name': holder,
  'last_movement_at': '2026-09-19T18:00:00+00:00',
  'dining_tables': {
    'code': code,
    'label': label,
    'zones': zone == null ? null : {'name': zone},
  },
};

int _seq = 0;

/// [at] en UTC: RD es UTC-4, así que 16:00Z = 12:00 del mediodía en RD.
Map<String, dynamic> _move(
  String account,
  String type,
  double amount,
  double balanceAfter,
  String at, {
  String? reference,
  String? note,
  String? method,
  String? createdBy,
}) => {
  'id': 'mov-${_seq++}',
  'account_id': account,
  'type': type,
  'amount': amount,
  'balance_after': balanceAfter,
  'reference': reference,
  'note': note,
  'created_at': at,
  'created_by': createdBy,
  'payment_methods': method == null ? null : {'name': method},
};

// Rango "hoy" = 19/09/2026 en hora de RD, `to` exclusivo.
final _from = DateTime(2026, 9, 19);
final _to = DateTime(2026, 9, 20);

TableDepositReport _build(
  List<Map<String, dynamic>> accounts,
  List<Map<String, dynamic>> movements, {
  DateTime? from,
  DateTime? to,
  Map<String, String> userNames = const {},
}) => TableDepositReport.build(
  accountRows: accounts,
  movementRows: movements,
  from: from ?? _from,
  to: to ?? _to,
  userNames: userNames,
);

void main() {
  group('Abono vigente de la mesa', () {
    // Pedro abonó y se lo consumió todo el 10/09. Hoy Juan abona en la misma
    // mesa: el reporte no puede mostrarle a Juan la referencia de Pedro.
    final history = [
      _move(
        'acc-1',
        'deposit',
        5000,
        5000,
        '2026-09-10T16:00:00Z',
        reference: 'PEDRO-TRX',
      ),
      _move('acc-1', 'consumption', -5000, 0, '2026-09-10T22:00:00Z'),
      _move(
        'acc-1',
        'deposit',
        10000,
        10000,
        '2026-09-19T14:00:00Z',
        reference: 'JUAN-TRX',
        method: 'Transferencia',
      ),
      _move('acc-1', 'consumption', -3500, 6500, '2026-09-19T20:00:00Z'),
    ];

    test('la referencia y los totales son solo del abono de hoy', () {
      final report = _build([
        _account(id: 'acc-1', balance: 6500, holder: 'Juan Pérez'),
      ], history);
      final a = report.accounts.single;
      expect(a.holderName, 'Juan Pérez');
      expect(a.references, ['JUAN-TRX']);
      expect(a.deposited, 10000);
      expect(a.consumed, 3500);
      expect(a.balance, 6500);
      expect(a.openedAt, DateTime(2026, 9, 19, 10));
    });

    test('los movimientos de un abono anterior salen sin nombre', () {
      final report = _build(
        [_account(id: 'acc-1', balance: 6500, holder: 'Juan Pérez')],
        history,
        from: DateTime(2026, 9, 1),
      );
      final byRef = {
        for (final m in report.movements) '${m.type}:${m.amount}': m,
      };
      expect(byRef['deposit:5000.0']!.holderName, isNull);
      expect(byRef['consumption:-5000.0']!.holderName, isNull);
      expect(byRef['deposit:10000.0']!.holderName, 'Juan Pérez');
      expect(byRef['consumption:-3500.0']!.holderName, 'Juan Pérez');
    });

    test('un recargo del mismo cliente suma al mismo abono', () {
      final report = _build(
        [_account(id: 'acc-1', balance: 8000, holder: 'Ana')],
        [
          _move(
            'acc-1',
            'deposit',
            5000,
            5000,
            '2026-09-19T14:00:00Z',
            reference: 'A-1',
          ),
          _move('acc-1', 'consumption', -2000, 3000, '2026-09-19T15:00:00Z'),
          _move(
            'acc-1',
            'deposit',
            5000,
            8000,
            '2026-09-19T16:00:00Z',
            reference: 'A-2',
          ),
        ],
      );
      final a = report.accounts.single;
      expect(a.references, ['A-1', 'A-2']);
      expect(a.deposited, 10000);
      expect(a.consumed, 2000);
    });

    test('anular un cobro que dejó la mesa en cero NO abre otro abono', () {
      final report = _build(
        [_account(id: 'acc-1', balance: 1000, holder: 'Ana')],
        [
          _move(
            'acc-1',
            'deposit',
            1000,
            1000,
            '2026-09-19T14:00:00Z',
            reference: 'A-1',
          ),
          _move('acc-1', 'consumption', -1000, 0, '2026-09-19T15:00:00Z'),
          _move('acc-1', 'reversal', 1000, 1000, '2026-09-19T16:00:00Z'),
        ],
      );
      final a = report.accounts.single;
      expect(a.references, ['A-1']);
      expect(a.deposited, 1000);
      expect(a.consumed, 0);
      expect(report.movements.every((m) => m.holderName == 'Ana'), isTrue);
    });

    test('filas del mismo instante conservan el orden del servidor', () {
      // Sin desempate, el consumo podría quedar antes que el abono y el ciclo
      // se partiría en dos.
      final report = _build(
        [_account(id: 'acc-1', balance: 700, holder: 'Ana')],
        [
          _move(
            'acc-1',
            'deposit',
            1000,
            1000,
            '2026-09-19T14:00:00Z',
            reference: 'A-1',
          ),
          _move('acc-1', 'consumption', -300, 700, '2026-09-19T14:00:00Z'),
        ],
      );
      expect(report.accounts.single.references, ['A-1']);
      expect(report.accounts.single.consumed, 300);
    });
  });

  group('Qué mesas entran', () {
    test('sin saldo y sin movimiento en el rango no sale', () {
      final report = _build(
        [_account(id: 'acc-1', balance: 0, holder: 'Viejo')],
        [
          _move('acc-1', 'deposit', 500, 500, '2026-09-10T14:00:00Z'),
          _move('acc-1', 'consumption', -500, 0, '2026-09-10T15:00:00Z'),
        ],
      );
      expect(report.accounts, isEmpty);
      expect(report.isEmpty, isTrue);
    });

    test('se consumió todo HOY: sale con balance cero', () {
      final report = _build(
        [_account(id: 'acc-1', balance: 0, holder: 'Ana')],
        [
          _move('acc-1', 'deposit', 500, 500, '2026-09-18T14:00:00Z'),
          _move('acc-1', 'consumption', -500, 0, '2026-09-19T15:00:00Z'),
        ],
      );
      expect(report.accounts.single.balance, 0);
      expect(report.accountsWithBalance, 0);
      expect(report.movements, hasLength(1));
    });

    test('con saldo de un abono viejo sale aunque no se moviera hoy', () {
      final report = _build(
        [_account(id: 'acc-1', balance: 500, holder: 'Ana')],
        [
          _move(
            'acc-1',
            'deposit',
            500,
            500,
            '2026-09-01T14:00:00Z',
            reference: 'VIEJA',
          ),
        ],
      );
      expect(report.accounts.single.references, ['VIEJA']);
      expect(report.movements, isEmpty);
      expect(report.outstandingBalance, 500);
    });
  });

  group('Totales del rango', () {
    final report = _build(
      [
        _account(id: 'acc-1', balance: 3000, holder: 'Ana', tableId: 't1'),
        _account(
          id: 'acc-2',
          balance: 7000,
          holder: 'Luis',
          tableId: 't2',
          label: null,
          code: 'B2',
          zone: null,
        ),
      ],
      [
        _move('acc-1', 'deposit', 5000, 5000, '2026-09-19T13:00:00Z'),
        _move('acc-1', 'consumption', -1500, 3500, '2026-09-19T14:00:00Z'),
        _move('acc-1', 'refund', -500, 3000, '2026-09-19T15:00:00Z'),
        _move(
          'acc-2',
          'deposit',
          7000,
          7000,
          '2026-09-19T16:00:00Z',
          createdBy: 'user-1',
        ),
        _move('acc-2', 'consumption', -1000, 6000, '2026-09-19T17:00:00Z'),
        _move('acc-2', 'reversal', 1000, 7000, '2026-09-19T18:00:00Z'),
        // 23:30 del 18 en RD (03:30Z del 19): fuera del rango de hoy.
        _move('acc-2', 'deposit', 999, 999, '2026-09-19T03:30:00Z'),
      ],
      userNames: const {'user-1': 'Cajera Rosa'},
    );

    test('abonado, consumido (neto de anulaciones) y devuelto', () {
      expect(report.periodDeposited, 12000);
      expect(report.periodConsumed, 1500);
      expect(report.periodRefunded, 500);
      expect(report.outstandingBalance, 10000);
      expect(report.accountsWithBalance, 2);
    });

    test('el corte del día es en hora de RD, no en UTC', () {
      expect(report.movements.any((m) => m.amount == 999), isFalse);
    });

    test('mayor saldo primero; movimientos del más reciente al más viejo', () {
      expect(report.accounts.map((a) => a.holderName), ['Luis', 'Ana']);
      final dates = report.movements.map((m) => m.createdAt).toList();
      for (var i = 1; i < dates.length; i++) {
        expect(dates[i].isAfter(dates[i - 1]), isFalse);
      }
    });

    test('mesa sin label usa el código; zona opcional; quién registró', () {
      final luis = report.accounts.first;
      expect(luis.tableLabel, 'B2');
      expect(luis.zoneName, isNull);
      expect(report.accounts.last.zoneName, 'Terraza');
      final deposit = report.movements.firstWhere(
        (m) => m.accountId == 'acc-2' && m.isDeposit,
      );
      expect(deposit.createdByName, 'Cajera Rosa');
    });
  });
}
