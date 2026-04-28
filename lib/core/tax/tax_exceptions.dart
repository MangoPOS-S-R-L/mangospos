/// Thrown when fiscal/tax configuration cannot be loaded or is invalid for the
/// current business. The system must fail loudly instead of falling back to
/// hardcoded defaults that would produce incorrect totals (PRD 1).
class TaxConfigException implements Exception {
  final String message;
  TaxConfigException(this.message);

  @override
  String toString() => 'TaxConfigException: $message';
}

/// Thrown when a payment cannot be processed because the order's fiscal
/// configuration is in an error state. Surfaced to the operator instead of
/// silently completing a payment with wrong taxes (PRD 1).
class PaymentBlockedException implements Exception {
  final String message;
  PaymentBlockedException(this.message);

  @override
  String toString() => 'PaymentBlockedException: $message';
}
