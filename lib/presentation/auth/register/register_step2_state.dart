class RegisterStep2State {
  final String businessName;
  final String branchName;
  final String businessType;
  final String country;
  final String address;
  final String phone;
  final String subdomain;

  const RegisterStep2State({
    this.businessName = '',
    this.branchName = '',
    this.businessType = 'Restaurante',
    this.country = 'República Dominicana',
    this.address = '',
    this.phone = '',
    this.subdomain = '',
  });

  RegisterStep2State copyWith({
    String? businessName,
    String? branchName,
    String? businessType,
    String? country,
    String? address,
    String? phone,
    String? subdomain,
  }) {
    return RegisterStep2State(
      businessName: businessName ?? this.businessName,
      branchName: branchName ?? this.branchName,
      businessType: businessType ?? this.businessType,
      country: country ?? this.country,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      subdomain: subdomain ?? this.subdomain,
    );
  }
}
