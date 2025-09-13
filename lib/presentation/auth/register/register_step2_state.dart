class RegisterStep2State {
  final String branchName;
  final String country;
  final String address;

  const RegisterStep2State({
    this.branchName = '',
    this.country = 'Dominican Republic',
    this.address = '',
  });

  RegisterStep2State copyWith({
    String? branchName,
    String? country,
    String? address,
  }) {
    return RegisterStep2State(
      branchName: branchName ?? this.branchName,
      country: country ?? this.country,
      address: address ?? this.address,
    );
  }
}
