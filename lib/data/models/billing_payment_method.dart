// PRD-Azul-Subscriptions §5.1 — Payment Method (tarjeta tokenizada).
//
// Mapea la vista `public.azul_payment_methods_public` (que oculta el
// data_vault_token — secreto que NUNCA debe llegar al cliente).

enum BillingPaymentMethodStatus {
  pendingVerification,
  verified,
  failedVerification,
  expired,
  revoked,
  unknown;

  static BillingPaymentMethodStatus fromWire(String? s) {
    switch (s) {
      case 'pending_verification':
        return BillingPaymentMethodStatus.pendingVerification;
      case 'verified':
        return BillingPaymentMethodStatus.verified;
      case 'failed_verification':
        return BillingPaymentMethodStatus.failedVerification;
      case 'expired':
        return BillingPaymentMethodStatus.expired;
      case 'revoked':
        return BillingPaymentMethodStatus.revoked;
      default:
        return BillingPaymentMethodStatus.unknown;
    }
  }
}

class BillingPaymentMethod {
  final String id;
  final String businessId;
  final String brand; // VISA, MASTERCARD, AMEX, etc.
  final String cardNumberMasked; // ej. ************1732
  final String dataVaultExpiration; // AAAAMM (ej. 202812)
  final BillingPaymentMethodStatus status;
  final bool isDefault;
  final DateTime createdAt;
  final DateTime? revokedAt;

  const BillingPaymentMethod({
    required this.id,
    required this.businessId,
    required this.brand,
    required this.cardNumberMasked,
    required this.dataVaultExpiration,
    required this.status,
    required this.isDefault,
    required this.createdAt,
    required this.revokedAt,
  });

  /// Últimos 4 dígitos legibles. Si no se puede parsear, devuelve "****".
  String get last4 {
    final masked = cardNumberMasked.replaceAll(RegExp(r'[^0-9]'), '');
    if (masked.length < 4) return '****';
    return masked.substring(masked.length - 4);
  }

  /// "12/28" formato MM/YY desde dataVaultExpiration AAAAMM.
  String get formattedExpiration {
    if (dataVaultExpiration.length != 6) return dataVaultExpiration;
    final year = dataVaultExpiration.substring(2, 4);
    final month = dataVaultExpiration.substring(4, 6);
    return '$month/$year';
  }

  /// true si la tarjeta ya expiró (mes actual o anterior).
  bool get isExpired {
    if (dataVaultExpiration.length != 6) return false;
    final year = int.tryParse(dataVaultExpiration.substring(0, 4)) ?? 0;
    final month = int.tryParse(dataVaultExpiration.substring(4, 6)) ?? 0;
    if (year == 0 || month == 0) return false;
    final now = DateTime.now();
    return year < now.year || (year == now.year && month < now.month);
  }

  factory BillingPaymentMethod.fromJson(Map<String, dynamic> json) {
    return BillingPaymentMethod(
      id: json['id'] as String,
      businessId: json['business_id'] as String,
      brand: (json['data_vault_brand'] as String?) ?? 'UNKNOWN',
      cardNumberMasked: (json['card_number_masked'] as String?) ?? '************',
      dataVaultExpiration: (json['data_vault_expiration'] as String?) ?? '000000',
      status: BillingPaymentMethodStatus.fromWire(json['status'] as String?),
      isDefault: (json['is_default'] as bool?) ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      revokedAt: json['revoked_at'] != null
          ? DateTime.parse(json['revoked_at'] as String)
          : null,
    );
  }
}
