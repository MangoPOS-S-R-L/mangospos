// Modelo de cuenta bancaria del negocio. Usado en Ajustes → Tipos de
// Pago para que el admin configure las cuentas donde se reciben
// transferencias, y en el modal de cobro para que el cajero seleccione
// destino.

enum BankAccountType { corriente, ahorro, otro }

extension BankAccountTypeX on BankAccountType {
  String get code {
    switch (this) {
      case BankAccountType.corriente:
        return 'corriente';
      case BankAccountType.ahorro:
        return 'ahorro';
      case BankAccountType.otro:
        return 'otro';
    }
  }

  String get displayName {
    switch (this) {
      case BankAccountType.corriente:
        return 'Corriente';
      case BankAccountType.ahorro:
        return 'Ahorro';
      case BankAccountType.otro:
        return 'Otro';
    }
  }

  static BankAccountType fromCode(String? code) {
    switch ((code ?? '').toLowerCase().trim()) {
      case 'corriente':
        return BankAccountType.corriente;
      case 'ahorro':
        return BankAccountType.ahorro;
      default:
        return BankAccountType.otro;
    }
  }
}

class BankAccount {
  final String id;
  final String businessId;
  final String bankName;
  final String accountNumber;
  final String? accountHolder;
  final BankAccountType accountType;
  final String currency; // 'DOP', 'USD', 'EUR'
  final String? alias;
  final bool isActive;
  final int sortOrder;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const BankAccount({
    required this.id,
    required this.businessId,
    required this.bankName,
    required this.accountNumber,
    this.accountHolder,
    required this.accountType,
    required this.currency,
    this.alias,
    required this.isActive,
    required this.sortOrder,
    this.createdAt,
    this.updatedAt,
  });

  /// Etiqueta amigable para mostrar en listas: alias si existe, si no
  /// el banco. Ej. "Cuenta principal" o "Banreservas".
  String get displayLabel {
    final a = alias?.trim();
    if (a != null && a.isNotEmpty) return a;
    return bankName.trim();
  }

  /// Última 4 dígitos del número de cuenta para previews compactas. Si
  /// el número es muy corto, devuelve el completo.
  String get accountTail {
    final digits = accountNumber.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length <= 4) return digits.isEmpty ? accountNumber : digits;
    return digits.substring(digits.length - 4);
  }

  factory BankAccount.fromMap(Map<String, dynamic> m) {
    DateTime? toDate(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return DateTime.tryParse(v.toString());
    }

    return BankAccount(
      id: m['id'] as String,
      businessId: m['business_id'] as String,
      bankName: (m['bank_name'] ?? '') as String,
      accountNumber: (m['account_number'] ?? '') as String,
      accountHolder: m['account_holder'] as String?,
      accountType: BankAccountTypeX.fromCode(m['account_type'] as String?),
      currency: ((m['currency'] ?? 'DOP') as String).toUpperCase(),
      alias: m['alias'] as String?,
      isActive: (m['is_active'] ?? true) as bool,
      sortOrder: ((m['sort_order'] ?? 0) as num).toInt(),
      createdAt: toDate(m['created_at']),
      updatedAt: toDate(m['updated_at']),
    );
  }

  Map<String, dynamic> toInsert() => {
        'id': id,
        'business_id': businessId,
        'bank_name': bankName,
        'account_number': accountNumber,
        'account_holder': accountHolder,
        'account_type': accountType.code,
        'currency': currency,
        'alias': alias,
        'is_active': isActive,
        'sort_order': sortOrder,
      };

  BankAccount copyWith({
    String? id,
    String? businessId,
    String? bankName,
    String? accountNumber,
    Object? accountHolder = _sentinel,
    BankAccountType? accountType,
    String? currency,
    Object? alias = _sentinel,
    bool? isActive,
    int? sortOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return BankAccount(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      bankName: bankName ?? this.bankName,
      accountNumber: accountNumber ?? this.accountNumber,
      accountHolder: identical(accountHolder, _sentinel)
          ? this.accountHolder
          : accountHolder as String?,
      accountType: accountType ?? this.accountType,
      currency: currency ?? this.currency,
      alias: identical(alias, _sentinel) ? this.alias : alias as String?,
      isActive: isActive ?? this.isActive,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

const Object _sentinel = Object();
