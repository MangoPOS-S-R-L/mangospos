double netPaymentAmount(dynamic amount, dynamic changeAmount) {
  final gross = _toDouble(amount);
  final change = _toDouble(changeAmount);
  final net = gross - change;
  return net < 0 ? 0 : net;
}

double _toDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}
