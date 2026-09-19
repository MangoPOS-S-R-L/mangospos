import '../../core/utils/app_time.dart';

/// Texto de cada tipo del ledger `table_deposit_movements.type`.
String tableDepositMovementTypeLabel(String type) => switch (type) {
  'deposit' => 'Abono',
  'consumption' => 'Consumo',
  'reversal' => 'Devuelto por anulación',
  'refund' => 'Devolución en efectivo',
  'transfer_in' => 'Recibido de otra mesa',
  'transfer_out' => 'Enviado a otra mesa',
  'adjustment' => 'Ajuste',
  _ => type,
};

/// Un movimiento del período, ya con la mesa y el nombre resueltos.
class TableDepositReportMovement {
  const TableDepositReportMovement({
    required this.id,
    required this.accountId,
    required this.tableId,
    required this.tableLabel,
    required this.type,
    required this.amount,
    required this.balanceAfter,
    required this.createdAt,
    this.holderName,
    this.reference,
    this.note,
    this.methodName,
    this.createdByName,
  });

  final String id;
  final String accountId;
  final String tableId;
  final String tableLabel;

  /// deposit | consumption | reversal | refund | transfer_in | transfer_out |
  /// adjustment
  final String type;

  /// Firmado: positivo entra al saldo, negativo sale.
  final double amount;

  /// Saldo con el que quedó la mesa justo después de este movimiento.
  final double balanceAfter;

  /// Hora de pared AST.
  final DateTime createdAt;

  /// A nombre de quién está el abono. Solo viene cuando el movimiento es del
  /// abono VIGENTE de la mesa: el saldo vive en la mesa física y
  /// `holder_name` se sobrescribe con cada cliente nuevo, así que ponerle el
  /// nombre de hoy a un movimiento de un abono anterior sería atribuirle el
  /// dinero a otra persona.
  final String? holderName;

  final String? reference;
  final String? note;
  final String? methodName;
  final String? createdByName;

  String get typeLabel => tableDepositMovementTypeLabel(type);
  bool get isDeposit => type == 'deposit';
}

/// El abono vigente de una mesa: a nombre de quién, con qué referencia,
/// cuánto entró, cuánto se consumió y cuánto queda.
class TableDepositReportAccount {
  const TableDepositReportAccount({
    required this.accountId,
    required this.tableId,
    required this.tableLabel,
    required this.balance,
    this.zoneName,
    this.holderName,
    this.references = const [],
    this.deposited = 0,
    this.consumed = 0,
    this.returned = 0,
    this.adjusted = 0,
    this.openedAt,
    this.lastMovementAt,
  });

  final String accountId;
  final String tableId;
  final String tableLabel;
  final String? zoneName;
  final String? holderName;

  /// Referencias de los abonos del ciclo vigente (transferencia, voucher…),
  /// sin repetir y en el orden en que se registraron.
  final List<String> references;

  /// Abonado en el ciclo vigente (abonos + saldo recibido de otra mesa).
  final double deposited;

  /// Consumido en el ciclo vigente, neto de anulaciones.
  final double consumed;

  /// Devuelto en efectivo o movido a otra mesa en el ciclo vigente.
  final double returned;

  final double adjusted;

  /// Saldo ACTUAL de la mesa (la columna de la cuenta, no un cálculo).
  final double balance;

  /// Primer movimiento del ciclo vigente = cuándo se abrió este abono.
  final DateTime? openedAt;
  final DateTime? lastMovementAt;

  bool get hasBalance => balance > 0.005;
  String get referenceLabel => references.join(', ');
}

/// Reporte de abonos de mesa: saldos vigentes + movimientos del período.
///
/// Es un modelo puro: la consulta vive en `TableDepositRepository.getReport`
/// y toda la lógica de armado está en [TableDepositReport.build], que se
/// prueba sin red.
class TableDepositReport {
  const TableDepositReport({required this.accounts, required this.movements});

  /// Mesas con saldo hoy o con movimiento en el período. Mayor saldo primero.
  final List<TableDepositReportAccount> accounts;

  /// Movimientos del período, el más reciente primero.
  final List<TableDepositReportMovement> movements;

  static const empty = TableDepositReport(accounts: [], movements: []);

  bool get isEmpty => accounts.isEmpty && movements.isEmpty;

  /// Lo que el negocio le debe hoy a sus clientes en saldo de mesa.
  double get outstandingBalance =>
      _round2(accounts.fold(0.0, (s, a) => s + a.balance));

  int get accountsWithBalance => accounts.where((a) => a.hasBalance).length;

  List<TableDepositReportMovement> get periodDeposits =>
      movements.where((m) => m.isDeposit).toList(growable: false);

  double get periodDeposited =>
      _round2(periodDeposits.fold(0.0, (s, m) => s + m.amount));

  /// Consumido en el período, neto de anulaciones.
  double get periodConsumed => _round2(
    movements.fold(0.0, (s, m) {
      if (m.type == 'consumption') return s - m.amount;
      if (m.type == 'reversal') return s - m.amount;
      return s;
    }),
  );

  /// Devuelto en efectivo en el período. Las transferencias entre mesas no
  /// cuentan: el dinero sigue dentro del negocio.
  double get periodRefunded => _round2(
    movements
        .where((m) => m.type == 'refund')
        .fold(0.0, (s, m) => s - m.amount),
  );

  /// Arma el reporte.
  ///
  /// - [accountRows]: `table_deposit_accounts` con `dining_tables(code, label,
  ///   zones(name))` embebido.
  /// - [movementRows]: la historia COMPLETA de esas cuentas, en cualquier
  ///   orden. Hace falta entera (no solo el período) para saber dónde empezó
  ///   el abono vigente de cada mesa.
  /// - [from]/[to]: período en hora de pared AST, [to] exclusivo.
  /// - [userNames]: `profiles.full_name` por id, para "Registrado por".
  factory TableDepositReport.build({
    required List<Map<String, dynamic>> accountRows,
    required List<Map<String, dynamic>> movementRows,
    required DateTime from,
    required DateTime to,
    Map<String, String> userNames = const {},
  }) {
    final byAccount = <String, List<_Row>>{};
    for (var i = 0; i < movementRows.length; i++) {
      final row = _Row.parse(movementRows[i], i);
      if (row == null) continue;
      byAccount.putIfAbsent(row.accountId, () => []).add(row);
    }

    bool inPeriod(DateTime at) => !at.isBefore(from) && at.isBefore(to);

    final accounts = <TableDepositReportAccount>[];
    final movements = <TableDepositReportMovement>[];

    for (final raw in accountRows) {
      final accountId = raw['id']?.toString() ?? '';
      if (accountId.isEmpty) continue;
      final tableId = raw['table_id']?.toString() ?? '';
      final table = raw['dining_tables'] is Map
          ? Map<String, dynamic>.from(raw['dining_tables'] as Map)
          : const <String, dynamic>{};
      final zone = table['zones'] is Map
          ? Map<String, dynamic>.from(table['zones'] as Map)
          : const <String, dynamic>{};
      final tableLabel =
          _clean(table['label']) ?? _clean(table['code']) ?? 'Mesa';
      final holderName = _clean(raw['holder_name']);
      final balance = _round2(_toDouble(raw['balance']));

      // Postgres guarda created_at con microsegundos; aun así, dos filas del
      // mismo instante no deben reordenarse (List.sort no es estable).
      final history = [...?byAccount[accountId]]
        ..sort((a, b) {
          final byDate = a.createdAt.compareTo(b.createdAt);
          return byDate != 0 ? byDate : a.index.compareTo(b.index);
        });

      // Ciclos: un abono empieza cuando entra dinero a una mesa que estaba en
      // cero. Una anulación que devuelve saldo NO abre ciclo nuevo: ese
      // saldo sigue siendo del mismo cliente.
      final cycleOf = <String, int>{};
      var cycle = -1;
      for (final m in history) {
        final before = m.balanceAfter - m.amount;
        final entersMoney = m.type == 'deposit' || m.type == 'transfer_in';
        if (cycle < 0 || (entersMoney && before <= 0.005)) cycle++;
        cycleOf[m.id] = cycle;
      }

      final current = history.where((m) => cycleOf[m.id] == cycle).toList();
      var deposited = 0.0;
      var consumed = 0.0;
      var returned = 0.0;
      var adjusted = 0.0;
      final references = <String>[];
      for (final m in current) {
        switch (m.type) {
          case 'deposit':
          case 'transfer_in':
            deposited += m.amount;
            final ref = m.reference;
            if (m.type == 'deposit' &&
                ref != null &&
                !references.contains(ref)) {
              references.add(ref);
            }
          case 'consumption':
          case 'reversal':
            consumed -= m.amount;
          case 'refund':
          case 'transfer_out':
            returned -= m.amount;
          default:
            adjusted += m.amount;
        }
      }

      final periodRows = history.where((m) => inPeriod(m.createdAt)).toList();
      if (balance <= 0.005 && periodRows.isEmpty) continue;

      accounts.add(
        TableDepositReportAccount(
          accountId: accountId,
          tableId: tableId,
          tableLabel: tableLabel,
          zoneName: _clean(zone['name']),
          holderName: holderName,
          references: references,
          deposited: _round2(deposited),
          consumed: _round2(consumed),
          returned: _round2(returned),
          adjusted: _round2(adjusted),
          balance: balance,
          openedAt: current.isEmpty ? null : current.first.createdAt,
          lastMovementAt: history.isEmpty
              ? AppTime.tryParseServerToAst(raw['last_movement_at'])
              : history.last.createdAt,
        ),
      );

      for (final m in periodRows) {
        movements.add(
          TableDepositReportMovement(
            id: m.id,
            accountId: accountId,
            tableId: tableId,
            tableLabel: tableLabel,
            type: m.type,
            amount: m.amount,
            balanceAfter: m.balanceAfter,
            createdAt: m.createdAt,
            holderName: cycleOf[m.id] == cycle ? holderName : null,
            reference: m.reference,
            note: m.note,
            methodName: m.methodName,
            createdByName: m.createdBy == null ? null : userNames[m.createdBy],
          ),
        );
      }
    }

    accounts.sort((a, b) {
      final byBalance = b.balance.compareTo(a.balance);
      return byBalance != 0
          ? byBalance
          : a.tableLabel.toLowerCase().compareTo(b.tableLabel.toLowerCase());
    });
    movements.sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      return byDate != 0 ? byDate : a.id.compareTo(b.id);
    });

    return TableDepositReport(accounts: accounts, movements: movements);
  }
}

class _Row {
  const _Row({
    required this.index,
    required this.id,
    required this.accountId,
    required this.type,
    required this.amount,
    required this.balanceAfter,
    required this.createdAt,
    this.reference,
    this.note,
    this.methodName,
    this.createdBy,
  });

  final int index;
  final String id;
  final String accountId;
  final String type;
  final double amount;
  final double balanceAfter;
  final DateTime createdAt;
  final String? reference;
  final String? note;
  final String? methodName;
  final String? createdBy;

  static _Row? parse(Map<String, dynamic> row, int index) {
    final id = row['id']?.toString() ?? '';
    final accountId = row['account_id']?.toString() ?? '';
    final createdAt = AppTime.tryParseServerToAst(row['created_at']);
    if (id.isEmpty || accountId.isEmpty || createdAt == null) return null;
    final method = row['payment_methods'];
    return _Row(
      index: index,
      id: id,
      accountId: accountId,
      type: row['type']?.toString() ?? '',
      amount: _toDouble(row['amount']),
      balanceAfter: _toDouble(row['balance_after']),
      createdAt: createdAt,
      reference: _clean(row['reference']),
      note: _clean(row['note']),
      methodName: method is Map ? _clean(method['name']) : null,
      createdBy: _clean(row['created_by']),
    );
  }
}

String? _clean(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

double _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

double _round2(double v) => (v * 100).roundToDouble() / 100;
