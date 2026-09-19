/// Cómo cae el abono de la mesa sobre una cuenta, para la PRECUENTA: cuánto
/// tiene la mesa, cuánto le toca pagar al cliente y con cuánto quedaría.
///
/// Es informativo — el descuento real del saldo pasa al cobrar. Pero el número
/// tiene que coincidir con lo que el cobro le va a proponer al cajero (el
/// método "Saldo mesa" precarga `min(saldo, total)`), así que la regla vive
/// aquí y no en el ticket.
class TableDepositCoverage {
  const TableDepositCoverage._({
    required this.available,
    required this.covered,
    required this.toPay,
    required this.remaining,
  });

  /// Saldo que la mesa tiene abonado.
  final double available;

  /// Parte de la cuenta que cubre el abono.
  final double covered;

  /// Lo que el cliente tiene que pagar aparte: la diferencia.
  final double toPay;

  /// Con cuánto quedaría la mesa si se cobra esta cuenta con el saldo.
  final double remaining;

  /// El abono alcanza para toda la cuenta.
  bool get coversAll => toPay <= 0.005;

  /// `null` si la mesa no tiene saldo: la precuenta sale como siempre.
  static TableDepositCoverage? of({
    required double total,
    required double? available,
  }) {
    final balance = _round2(available ?? 0);
    if (balance <= 0.005) return null;
    final cuenta = _round2(total < 0 ? 0 : total);
    final covered = balance < cuenta ? balance : cuenta;
    return TableDepositCoverage._(
      available: balance,
      covered: covered,
      toPay: _round2(cuenta - covered),
      remaining: _round2(balance - covered),
    );
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}
