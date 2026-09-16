/// Cantidades de COMPRA: cuánto pedir de verdad a partir de lo sugerido.
///
/// Todo lo calculado (proyección, reorden) sale en UNIDAD BASE del insumo, pero
/// al suplidor no se le piden 10 latas sueltas si vende por caja de 24. Esta
/// capa redondea HACIA ARRIBA a empaques completos y respeta el mínimo de
/// compra del suplidor (decisión D7 del PRD de compras), diciendo cuánto sobra
/// para que la pantalla lo muestre en vez de esconderlo.
///
/// Funciones puras, sin estado.
library;

/// Tiempo de entrega que se usa mientras el suplidor no tenga el suyo cargado
/// (decisión D9). Se puede corregir por suplidor desde la pantalla de pedido.
const int kDefaultSupplierLeadTimeDays = 2;

/// Resultado de redondear una cantidad sugerida a lo que se puede comprar.
class PurchaseRounding {
  /// Cuántas unidades de COMPRA pedir (cajas, sacos; o unidades base si el
  /// insumo no tiene empaque).
  final double packs;

  /// Lo mismo en unidad base: `packs × packSize`. Es lo que va a la orden.
  final double baseQuantity;

  /// Lo que se pide de más sobre lo sugerido, en unidad base. Nunca negativo.
  final double surplusBase;

  /// Si el mínimo de compra del suplidor subió la cantidad.
  final bool raisedToMinimum;

  const PurchaseRounding({
    required this.packs,
    required this.baseQuantity,
    required this.surplusBase,
    this.raisedToMinimum = false,
  });

  static const zero = PurchaseRounding(packs: 0, baseQuantity: 0, surplusBase: 0);
}

// Tolerancia de coma flotante: 0.3 / 0.1 da 2.9999999999999996 y ceil lo
// convertiría en 3 → bien, pero 0.30000000000000004 / 0.1 da
// 3.0000000000000004 y ceil lo subiría a 4. Se resta antes de redondear.
const double _eps = 1e-9;

double _ceil(double value) => (value - _eps).ceilToDouble();

/// Redondea [suggestedBase] (unidad base) a lo que se le puede pedir al
/// suplidor.
///
/// - Con empaque (`packSize` distinto de 1): empaques completos hacia arriba.
///   Una caja de 24 y 10 sugeridas → 1 caja = 24, sobran 14.
/// - Sin empaque y base CONTABLE (unidad, docena): enteros hacia arriba.
/// - Sin empaque y base MEDIBLE (lb, g, mL): se deja tal cual; 2.5 lb es una
///   compra válida y subirla a 3 inventaría gasto.
/// - [minOrderPacks]: mínimo de compra del suplidor en unidades de compra. Si
///   no hace falta pedir nada (sugerido ≤ 0) NO se fuerza el mínimo.
PurchaseRounding roundUpToPurchase({
  required double suggestedBase,
  double packSize = 1,
  double? minOrderPacks,
  bool baseIsCountable = true,
}) {
  if (suggestedBase <= 0) return PurchaseRounding.zero;

  final pack = packSize > 0 ? packSize : 1.0;
  final hasPack = (pack - 1).abs() > _eps;

  double packs;
  if (hasPack) {
    packs = _ceil(suggestedBase / pack);
  } else if (baseIsCountable) {
    packs = _ceil(suggestedBase);
  } else {
    packs = suggestedBase;
  }

  var raised = false;
  final minimum = minOrderPacks ?? 0;
  if (minimum > 0 && packs < minimum - _eps) {
    packs = (hasPack || baseIsCountable) ? _ceil(minimum) : minimum;
    raised = true;
  }

  final base = hasPack ? packs * pack : packs;
  final surplus = base - suggestedBase;
  return PurchaseRounding(
    packs: packs,
    baseQuantity: base,
    surplusBase: surplus > _eps ? surplus : 0,
    raisedToMinimum: raised,
  );
}
