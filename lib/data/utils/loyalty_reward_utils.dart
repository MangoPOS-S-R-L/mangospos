/// Tarjetas de sellos («cada N compras, 1 gratis»): el marcador del premio en
/// las notas de la línea y las reglas de qué línea puede recibirlo.
///
/// Puro (sin Supabase) para poder probarlo. El servidor
/// (`fn_loyalty_redeem_reward`, mig 20260930_0053) aplica las MISMAS reglas y
/// es el que decide; esto solo sirve para no ofrecer en caja lo que el
/// servidor va a rechazar, y para que los otros descuentos respeten el premio.
///
/// El marcador es `[LOYALTY:<id del canje>:<unidades gratis>]`, en su propia
/// línea de notas. El canje vale mientras el marcador siga en la línea: si
/// una cortesía lo reemplaza, los sellos vuelven solos (se calculan en el
/// servidor a partir de las ventas cobradas).
library;

const loyaltyMarkerPrefix = '[LOYALTY:';

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

bool _isLoyaltyMarkerLine(String line) =>
    line.startsWith(loyaltyMarkerPrefix) && line.endsWith(']');

Iterable<String> _noteLines(String? notes) => (notes ?? '')
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty);

/// La línea del marcador tal cual está guardada, o null si no hay premio.
String? loyaltyMarkerLine(String? notes) {
  for (final line in _noteLines(notes)) {
    if (_isLoyaltyMarkerLine(line)) return line;
  }
  return null;
}

bool hasLoyaltyReward(String? notes) => loyaltyMarkerLine(notes) != null;

/// Las notas sin el marcador del premio ('' si no queda nada).
String stripLoyaltyMarkers(String? notes) =>
    _noteLines(notes).where((line) => !_isLoyaltyMarkerLine(line)).join('\n');

/// Unidades gratis que puso el premio (0 si la línea no tiene premio).
int loyaltyRewardUnits(String? notes) {
  final marker = loyaltyMarkerLine(notes);
  if (marker == null) return 0;
  final body = marker.substring(loyaltyMarkerPrefix.length, marker.length - 1);
  final parts = body.split(':');
  final units = parts.length > 1 ? int.tryParse(parts.last.trim()) : null;
  return (units == null || units < 1) ? 1 : units;
}

double _round2(double value) => double.parse(value.toStringAsFixed(2));

/// Lo que vale el premio en esta línea: gross por unidad × unidades gratis.
/// Es la misma cuenta que hace el servidor al canjear y que el reparto del
/// 2x1 (`bogo_promo_allocator.dart`).
double loyaltyRewardAmount({
  required double subtotal,
  required double tax,
  required double quantity,
  required String? notes,
}) {
  final units = loyaltyRewardUnits(notes);
  if (units <= 0 || quantity <= 0) return 0;
  final gross = (subtotal + tax).clamp(0, double.infinity).toDouble();
  final amount = (gross / quantity * units).clamp(0, gross).toDouble();
  return _round2(amount);
}

/// Descuento de una línea al aplicarle un descuento manual ENCIMA, sin
/// quitarle el premio: el premio se queda y el porcentaje (o la parte del
/// monto) se calcula sobre lo que el cliente sí paga.
///
/// `manualOnRest` recibe la base que queda (gross − premio) y devuelve el
/// descuento manual sobre esa base.
double discountKeepingLoyaltyReward({
  required double subtotal,
  required double tax,
  required double quantity,
  required String? notes,
  required double Function(double restBase) manualOnRest,
}) {
  final gross = (subtotal + tax).clamp(0, double.infinity).toDouble();
  final reward = loyaltyRewardAmount(
    subtotal: subtotal,
    tax: tax,
    quantity: quantity,
    notes: notes,
  );
  final rest = (gross - reward).clamp(0, gross).toDouble();
  final manual = manualOnRest(rest).clamp(0, rest).toDouble();
  return (reward + manual).clamp(0, gross).toDouble();
}

/// Base sobre la que se puede aplicar un descuento manual a la línea (lo que
/// no cubre el premio).
double loyaltyDiscountableBase({
  required double subtotal,
  required double tax,
  required double quantity,
  required String? notes,
}) {
  final gross = (subtotal + tax).clamp(0, double.infinity).toDouble();
  final reward = loyaltyRewardAmount(
    subtotal: subtotal,
    tax: tax,
    quantity: quantity,
    notes: notes,
  );
  return (gross - reward).clamp(0, gross).toDouble();
}

/// ¿La línea ya trae un descuento administrado (cortesía, oferta automática,
/// oferta de tile o premio)? Mismo criterio que el servidor.
bool hasManagedDiscountMarker(String? notes) {
  for (final line in _noteLines(notes)) {
    if (!line.endsWith(']')) continue;
    if (line.startsWith('[CORTESIA:') ||
        line.startsWith('[PROMO_AUTO:') ||
        line.startsWith('[DEAL') ||
        line.startsWith(loyaltyMarkerPrefix)) {
      return true;
    }
  }
  return false;
}

/// Línea de la orden vista por la tarjeta de sellos (solo lo que necesita).
class LoyaltyRewardLine {
  const LoyaltyRewardLine({
    required this.id,
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.subtotal,
    required this.tax,
    required this.discounts,
    required this.status,
    required this.customerId,
    this.notes,
  });

  final String id;
  final String? productId;
  final String productName;
  final double quantity;
  final double subtotal;
  final double tax;
  final double discounts;
  final String status;

  /// Cliente EFECTIVO de la línea: el de su subcuenta, o el de la mesa.
  final String? customerId;
  final String? notes;

  double get gross => (subtotal + tax).clamp(0, double.infinity).toDouble();
  double get perUnitGross => quantity > 0 ? gross / quantity : gross;
}

/// Líneas de [customerId] que pueden recibir el premio del programa, de la
/// más barata a la más cara (desempate por id: el mismo orden siempre).
///
/// Se excluyen: líneas cobradas o anuladas, sin guardar en el servidor, de
/// otro cliente, fuera del programa, con otro descuento (no se pisa), con
/// menos de una unidad (mitades de una cuenta dividida) o sin precio.
List<LoyaltyRewardLine> loyaltyRewardCandidates({
  required List<LoyaltyRewardLine> lines,
  required Set<String> eligibleProductIds,
  required String customerId,
}) {
  final result = lines
      .where((line) => line.status != 'paid' && line.status != 'void')
      .where((line) => _uuidPattern.hasMatch(line.id))
      .where((line) => line.customerId == customerId)
      .where(
        (line) =>
            line.productId != null &&
            eligibleProductIds.contains(line.productId),
      )
      .where((line) => line.discounts <= 0.009)
      .where((line) => !hasManagedDiscountMarker(line.notes))
      .where((line) => line.quantity >= 1 - 0.0001)
      .where((line) => line.gross > 0)
      .toList();
  result.sort((a, b) {
    final byUnit = a.perUnitGross.compareTo(b.perUnitGross);
    return byUnit != 0 ? byUnit : a.id.compareTo(b.id);
  });
  return result;
}
