/// Descuento digitado en el registro de compra: un número simple es un
/// MONTO en RD$ y un número terminado en `%` es un porcentaje sobre la base.
/// Ejemplos: `150` → RD$150 · `10%` → 10% de la base · vacío/ilegible → 0.
class DiscountInput {
  final double value;
  final bool isPercent;

  const DiscountInput(this.value, this.isPercent);

  static const zero = DiscountInput(0, false);

  factory DiscountInput.parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return zero;
    final isPercent = text.endsWith('%');
    final numeric = isPercent
        ? text.substring(0, text.length - 1).trim()
        : text;
    final parsed = double.tryParse(numeric) ?? 0;
    if (parsed <= 0) return zero;
    return DiscountInput(parsed, isPercent);
  }

  bool get isZero => value <= 0;

  /// Monto en RD$ a descontar sobre [base], clampado a `[0, base]` (un
  /// descuento nunca deja la base negativa ni "regala" dinero de más).
  double amountOn(double base) {
    if (base <= 0 || value <= 0) return 0;
    final amount = isPercent ? base * value / 100 : value;
    return amount.clamp(0, base).toDouble();
  }
}
