class RegisterStep2State {
  final String businessName;
  final String branchName;
  final String businessType;
  /// País del negocio (nombre legible). La moneda base se DERIVA de aquí
  /// (ver CountryProfile) y se persiste en `business_settings.currency_code`
  /// al crear el negocio (modo legacy: country_code no se persiste aún).
  final String country;

  final String address;
  final String phone;
  final String subdomain;

  /// Consentimiento explícito del comercio al cobro recurrente (PRD §10.5).
  /// Required en Step 3 antes de submit. Se persiste en
  /// `memberships.consent_granted_at = now()` al confirmar el registro.
  /// Defensa primaria contra chargebacks.
  final bool consentGranted;

  const RegisterStep2State({
    this.businessName = '',
    this.branchName = '',
    this.businessType = 'Restaurante',
    this.country = 'República Dominicana',
    this.address = '',
    this.phone = '',
    this.subdomain = '',
    this.consentGranted = false,
  });

  RegisterStep2State copyWith({
    String? businessName,
    String? branchName,
    String? businessType,
    String? country,
    String? address,
    String? phone,
    String? subdomain,
    bool? consentGranted,
  }) {
    return RegisterStep2State(
      businessName: businessName ?? this.businessName,
      branchName: branchName ?? this.branchName,
      businessType: businessType ?? this.businessType,
      country: country ?? this.country,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      subdomain: subdomain ?? this.subdomain,
      consentGranted: consentGranted ?? this.consentGranted,
    );
  }
}
