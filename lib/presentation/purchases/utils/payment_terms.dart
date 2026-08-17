/// Condiciones de pago del proveedor → plazo sugerido para la cuenta por pagar.
///
/// El proveedor guarda sus condiciones como texto libre («30 días»,
/// «contado», «50% anticipo») y, desde la migración 20260814_0003, también
/// como un número de días. De «50% anticipo» no sale ninguna fecha, y
/// adivinarla produciría cuentas por pagar con vencimientos falsos, que es
/// peor que no tenerlas.
///
/// Por eso la pantalla nunca deduce en silencio: muestra las condiciones tal
/// como están escritas y solo PRESELECCIONA una ficha de plazo cuando hay un
/// número que la respalde.
class PaymentTermsSuggestion {
  /// Días a preseleccionar. `null` = no hay plazo defendible; el vencimiento
  /// es obligatorio y se elige a mano.
  final int? days;

  /// true = el número vino del campo numérico del proveedor (dato).
  /// false = se dedujo del texto libre (sugerencia).
  final bool fromNumber;

  /// Condiciones tal como las escribió el negocio, para mostrarlas literales.
  final String text;

  const PaymentTermsSuggestion({
    this.days,
    this.fromNumber = false,
    this.text = '',
  });

  bool get hasSuggestion => days != null;

  bool get hasText => text.trim().isNotEmpty;
}

class PaymentTerms {
  const PaymentTerms._();

  /// Fichas de plazo que ofrece la pantalla, además del selector de fecha.
  static const offeredDays = <int>[15, 30, 45, 60];

  static PaymentTermsSuggestion resolve({int? days, String? freeText}) {
    final text = (freeText ?? '').trim();

    // 1. Número explícito del proveedor: es dato, no interpretación.
    if (days != null && days > 0 && days <= 365) {
      return PaymentTermsSuggestion(days: days, fromNumber: true, text: text);
    }

    // 2. Texto libre: solo si el número es INEQUÍVOCO.
    return PaymentTermsSuggestion(days: _daysFromText(text), text: text);
  }

  /// Un plazo se deduce del texto únicamente cuando no hay ambigüedad:
  /// - «50% anticipo» trae un porcentaje → no es un plazo.
  /// - «2/10 neto 30» trae dos números → no se sabe cuál manda.
  /// - «30 días» / «Neto 30» / «30» → un solo número, plazo defendible.
  static int? _daysFromText(String text) {
    if (text.isEmpty) return null;
    if (text.contains('%')) return null;
    final numbers = RegExp(r'\d+')
        .allMatches(text)
        .map((m) => int.tryParse(m.group(0)!))
        .whereType<int>()
        .toList(growable: false);
    if (numbers.length != 1) return null;
    final value = numbers.first;
    if (value <= 0 || value > 365) return null;
    return value;
  }
}
