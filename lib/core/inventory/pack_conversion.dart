/// Conversión de empaque para insumos.
///
/// Un insumo tiene una unidad BASE de stock (ej. ml) y, opcionalmente, una
/// unidad de COMPRA (ej. botella) con un `pack_size` = unidades base por
/// empaque (ej. 750). El stock, recetas y consumo viven en unidad base; la
/// app convierte solo al ENTRAR (compras/recepción) y al MOSTRAR.
///
/// Funciones puras, sin estado, para reusar en todos los flujos.
library;

/// Convierte una cantidad en unidad de COMPRA a unidad BASE.
/// Ej: 6 botellas × 750 = 4500 ml. Si `packSize <= 0` asume 1 (sin empaque).
double packToBase(double packQty, double packSize) {
  return packQty * (packSize <= 0 ? 1 : packSize);
}

/// Convierte una cantidad en unidad BASE a unidad de COMPRA.
/// Ej: 4500 ml ÷ 750 = 6 botellas. Si `packSize <= 0` devuelve la base.
double baseToPack(double baseQty, double packSize) {
  return packSize <= 0 ? baseQty : baseQty / packSize;
}

/// Convierte un costo por unidad de COMPRA a costo por unidad BASE.
/// Ej: RD$1000 por botella ÷ 750 = RD$1.333 por ml.
double packCostToBaseCost(double packCost, double packSize) {
  return packSize <= 0 ? packCost : packCost / packSize;
}

/// True si el insumo se compra en una unidad distinta a la base (tiene
/// empaque real): `packSize > 1` y `purchaseUnit` definido y distinto de la
/// unidad base. Controla si la UI muestra la conversión.
bool hasPack(double packSize, String? purchaseUnit, {String? baseUnit}) {
  if (packSize <= 1) return false;
  final pu = purchaseUnit?.trim();
  if (pu == null || pu.isEmpty) return false;
  final bu = baseUnit?.trim().toLowerCase();
  if (bu != null && pu.toLowerCase() == bu) return false;
  return true;
}

/// Texto corto "≈ X botellas" para mostrar junto al stock base. Devuelve
/// null si el insumo no tiene empaque. Redondea a 2 decimales sin ceros
/// sobrantes (ej. "6", "6.2", "6.27").
String? packEquivalentLabel(
  double baseQty,
  double packSize,
  String? purchaseUnit,
) {
  if (!hasPack(packSize, purchaseUnit)) return null;
  final packs = baseToPack(baseQty, packSize);
  return '≈ ${_trim(packs)} ${purchaseUnit!.trim()}';
}

String _trim(double v) {
  final s = v.toStringAsFixed(2);
  if (s.endsWith('.00')) return s.substring(0, s.length - 3);
  if (s.endsWith('0')) return s.substring(0, s.length - 1);
  return s;
}
