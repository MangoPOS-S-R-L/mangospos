// Modelos del módulo contable. Se mantienen ligeros: los reportes (diario,
// mayor, balanza, estados financieros) vienen de RPCs que devuelven filas
// planas, así que se tipan solo las entidades que la UI edita.

/// Naturaleza de la cuenta. Define el signo con el que se presenta el saldo:
/// activo y gasto son deudoras, el resto acreedoras.
enum AccountType { asset, liability, equity, income, expense }

extension AccountTypeX on AccountType {
  String get code => switch (this) {
        AccountType.asset => 'asset',
        AccountType.liability => 'liability',
        AccountType.equity => 'equity',
        AccountType.income => 'income',
        AccountType.expense => 'expense',
      };

  String get label => switch (this) {
        AccountType.asset => 'Activo',
        AccountType.liability => 'Pasivo',
        AccountType.equity => 'Patrimonio',
        AccountType.income => 'Ingresos',
        AccountType.expense => 'Gastos y costos',
      };

  bool get isDebitNature =>
      this == AccountType.asset || this == AccountType.expense;

  static AccountType fromCode(String? value) => switch (value) {
        'liability' => AccountType.liability,
        'equity' => AccountType.equity,
        'income' => AccountType.income,
        'expense' => AccountType.expense,
        _ => AccountType.asset,
      };
}

class AccountingAccount {
  final String id;
  final String code;
  final String name;
  final AccountType type;
  final String? parentId;
  final bool isPostable;
  final bool isActive;
  final String? description;

  const AccountingAccount({
    required this.id,
    required this.code,
    required this.name,
    required this.type,
    this.parentId,
    this.isPostable = true,
    this.isActive = true,
    this.description,
  });

  /// Nivel jerárquico derivado del código (2 dígitos por nivel), que es como
  /// se siembra el catálogo: 1 → 11 → 1101 → 110101.
  int get depth => (code.length / 2).ceil() - 1;

  factory AccountingAccount.fromMap(Map<String, dynamic> map) {
    return AccountingAccount(
      id: map['id'] as String,
      code: (map['code'] ?? '') as String,
      name: (map['name'] ?? '') as String,
      type: AccountTypeX.fromCode(map['account_type'] as String?),
      parentId: map['parent_id'] as String?,
      isPostable: (map['is_postable'] ?? true) as bool,
      isActive: (map['is_active'] ?? true) as bool,
      description: map['description'] as String?,
    );
  }
}

class AccountingCostCenter {
  final String id;
  final String code;
  final String name;
  final String kind;
  final bool isActive;

  const AccountingCostCenter({
    required this.id,
    required this.code,
    required this.name,
    required this.kind,
    this.isActive = true,
  });

  String get kindLabel => switch (kind) {
        'department' => 'Departamento',
        'project' => 'Proyecto',
        'branch' => 'Sucursal',
        _ => 'Centro de costo',
      };

  factory AccountingCostCenter.fromMap(Map<String, dynamic> map) {
    return AccountingCostCenter(
      id: map['id'] as String,
      code: (map['code'] ?? '') as String,
      name: (map['name'] ?? '') as String,
      kind: (map['kind'] ?? 'cost_center') as String,
      isActive: (map['is_active'] ?? true) as bool,
    );
  }
}

class AccountingPeriod {
  final String id;
  final int year;
  final int month;
  final String status;
  final DateTime? closedAt;

  const AccountingPeriod({
    required this.id,
    required this.year,
    required this.month,
    required this.status,
    this.closedAt,
  });

  bool get isClosed => status == 'closed';

  factory AccountingPeriod.fromMap(Map<String, dynamic> map) {
    return AccountingPeriod(
      id: map['id'] as String,
      year: (map['year'] as num).toInt(),
      month: (map['month'] as num).toInt(),
      status: (map['status'] ?? 'open') as String,
      closedAt: map['closed_at'] == null
          ? null
          : DateTime.tryParse(map['closed_at'] as String),
    );
  }
}

/// Una línea en construcción dentro del editor de asientos manuales.
class JournalLineDraft {
  String? accountId;
  String? costCenterId;
  double debit;
  double credit;
  String? description;

  JournalLineDraft({
    this.accountId,
    this.costCenterId,
    this.debit = 0,
    this.credit = 0,
    this.description,
  });

  bool get isEmpty => accountId == null || (debit == 0 && credit == 0);

  Map<String, dynamic> toJson() => {
        'account_id': accountId,
        if (costCenterId != null) 'cost_center_id': costCenterId,
        'debit': debit,
        'credit': credit,
        if (description != null && description!.trim().isNotEmpty)
          'description': description!.trim(),
      };
}

class AccountingEntry {
  final String id;
  final int number;
  final DateTime date;
  final String description;
  final String? reference;
  final String sourceType;
  final String status;
  final double totalDebit;
  final double totalCredit;
  final String? reversedByEntryId;
  final String? reversesEntryId;

  const AccountingEntry({
    required this.id,
    required this.number,
    required this.date,
    required this.description,
    required this.sourceType,
    required this.status,
    required this.totalDebit,
    required this.totalCredit,
    this.reference,
    this.reversedByEntryId,
    this.reversesEntryId,
  });

  bool get isReversed => status == 'reversed';
  bool get isReversal => reversesEntryId != null;

  String get sourceLabel => switch (sourceType) {
        'sales' => 'Ventas',
        'purchase' => 'Compra',
        'cash_txn' => 'Caja',
        'credit_payment' => 'Abono CxC',
        'supplier_payment' => 'Pago CxP',
        'reversal' => 'Reversión',
        _ => 'Manual',
      };

  factory AccountingEntry.fromMap(Map<String, dynamic> map) {
    return AccountingEntry(
      id: map['id'] as String,
      number: (map['entry_number'] as num?)?.toInt() ?? 0,
      date: DateTime.tryParse((map['entry_date'] ?? '') as String) ??
          DateTime.now(),
      description: (map['description'] ?? '') as String,
      reference: map['reference'] as String?,
      sourceType: (map['source_type'] ?? 'manual') as String,
      status: (map['status'] ?? 'posted') as String,
      totalDebit: (map['total_debit'] as num?)?.toDouble() ?? 0,
      totalCredit: (map['total_credit'] as num?)?.toDouble() ?? 0,
      reversedByEntryId: map['reversed_by_entry_id'] as String?,
      reversesEntryId: map['reverses_entry_id'] as String?,
    );
  }
}
