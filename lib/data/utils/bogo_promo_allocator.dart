/// Reparto de unidades gratis para las auto-ofertas "lleva X paga Y" (bogo).
///
/// Vive fuera del viewmodel porque es matemática de dinero y ya regresionó dos
/// veces en producción: primero repartiendo por FILA en vez de por unidad
/// (descontaba 3 cervezas cuando solo tocaba 1), y después juntando PRODUCTOS
/// distintos en un mismo pozo (mesa A21: 2 Margaritas de 400 + 2 Palomas de 430
/// con un 2x1 daban −800 con la Margarita en RD$0.00, en vez de −830 = 1 gratis
/// de cada una). Aislada y pura se puede testear sin Supabase.
library;

/// Línea de orden vista por el repartidor de BOGO (solo lo que necesita).
class BogoLine {
  const BogoLine({
    required this.id,
    required this.quantity,
    required this.gross,
    this.checkId,
    this.productId,
  });

  /// `order_items.id` — también es el desempate determinista del orden.
  final String id;

  /// Unidades de la fila (una fila qty=3 vale 3 unidades, no 1).
  final int quantity;

  /// Gross de la FILA completa (subtotal + tax, antes de descuento).
  final double gross;

  /// Cuenta (split bill). Cada cuenta arma su propia oferta.
  final String? checkId;

  /// Producto. Cada producto arma su propia oferta: un 2x1 que cubre varios
  /// productos NO mezcla unidades entre ellos.
  final String? productId;

  double get perUnitGross => quantity > 0 ? gross / quantity : gross;
}

/// Devuelve el descuento (en dinero) que le toca a cada línea, indexado por id.
///
/// Reglas:
/// - Agrupa por **cuenta + producto**.
/// - Cuenta **unidades**, no filas: `freeUnits = (unidades ~/ buy) * free`.
/// - Las unidades gratis salen de las más baratas **de ese producto**, y se
///   descuenta solo esas unidades (descuento parcial de fila).
/// - Orden determinista (precio por unidad, luego id) → el mismo reparto en
///   cada recarga, sin churn.
///
/// Solo aparecen en el mapa las líneas que efectivamente liberaron unidades.
Map<String, double> allocateBogoDiscounts({
  required List<BogoLine> lines,
  required int buyQuantity,
  required int freeQuantity,
}) {
  final result = <String, double>{};
  if (buyQuantity <= 1 || freeQuantity <= 0) return result;

  final groups = <String, List<BogoLine>>{};
  for (final line in lines) {
    final productId = line.productId?.trim() ?? '';
    // Sin product_id (no debería pasar en bogo: exige target_ids) la línea
    // queda en su propio grupo antes que mezclarse con otro producto.
    final productKey = productId.isNotEmpty ? productId : 'item:${line.id}';
    final key = '${line.checkId ?? ''}|$productKey';
    groups.putIfAbsent(key, () => <BogoLine>[]).add(line);
  }

  for (final group in groups.values) {
    final totalUnits = group.fold<int>(0, (sum, line) => sum + line.quantity);
    var freeUnits = (totalUnits ~/ buyQuantity) * freeQuantity;
    if (freeUnits <= 0) continue;

    final sorted = [...group]
      ..sort((a, b) {
        final byUnit = a.perUnitGross.compareTo(b.perUnitGross);
        return byUnit != 0 ? byUnit : a.id.compareTo(b.id);
      });

    for (final line in sorted) {
      if (freeUnits <= 0) break;
      if (line.quantity <= 0) continue;
      final unitsFree = freeUnits < line.quantity ? freeUnits : line.quantity;
      final discount = (line.perUnitGross * unitsFree)
          .clamp(0, double.infinity)
          .toDouble();
      result[line.id] = double.parse(discount.toStringAsFixed(2));
      freeUnits -= unitsFree;
    }
  }

  return result;
}
