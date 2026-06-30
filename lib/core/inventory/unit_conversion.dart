/// Conversión entre unidades de la MISMA familia (volumen, peso, conteo).
///
/// Complementa [pack_conversion.dart] (que maneja el empaque por insumo:
/// 1 botella = N unidades base). Esta capa permite escribir recetas en
/// onzas/litros/cl y que el sistema descuente del stock en la unidad base
/// del insumo (ml/g), convirtiendo automáticamente.
///
/// Unidad base canónica por familia: volumen → ml, peso → g, conteo → unidad.
/// Funciones puras, sin estado. La MISMA lógica vive en SQL
/// (`fn_recipe_qty_to_base`) para el descuento en backend; mantener en sync.
library;

enum UnitFamily { volume, weight, count, unknown }

/// Factor de cada unidad hacia la base canónica de su familia.
/// `1 unidad = toBase` (en la unidad base de la familia).
const Map<String, ({UnitFamily family, double toBase})> _units = {
  // Volumen (base: ml)
  'ml': (family: UnitFamily.volume, toBase: 1),
  'cc': (family: UnitFamily.volume, toBase: 1),
  'l': (family: UnitFamily.volume, toBase: 1000),
  'lt': (family: UnitFamily.volume, toBase: 1000),
  'litro': (family: UnitFamily.volume, toBase: 1000),
  'litros': (family: UnitFamily.volume, toBase: 1000),
  'cl': (family: UnitFamily.volume, toBase: 10),
  'oz': (family: UnitFamily.volume, toBase: 29.5735),
  'onza': (family: UnitFamily.volume, toBase: 29.5735),
  'onzas': (family: UnitFamily.volume, toBase: 29.5735),
  // Peso (base: g)
  'mg': (family: UnitFamily.weight, toBase: 0.001),
  'g': (family: UnitFamily.weight, toBase: 1),
  'gr': (family: UnitFamily.weight, toBase: 1),
  'gramo': (family: UnitFamily.weight, toBase: 1),
  'gramos': (family: UnitFamily.weight, toBase: 1),
  'kg': (family: UnitFamily.weight, toBase: 1000),
  'kilo': (family: UnitFamily.weight, toBase: 1000),
  'kilos': (family: UnitFamily.weight, toBase: 1000),
  // Conteo (base: unidad)
  'unidad': (family: UnitFamily.count, toBase: 1),
  'unidades': (family: UnitFamily.count, toBase: 1),
  'und': (family: UnitFamily.count, toBase: 1),
  'u': (family: UnitFamily.count, toBase: 1),
  'pieza': (family: UnitFamily.count, toBase: 1),
  'piezas': (family: UnitFamily.count, toBase: 1),
};

String _norm(String u) => u.trim().toLowerCase();

/// Familia de una unidad (o [UnitFamily.unknown] si no está en el catálogo).
UnitFamily unitFamily(String unit) =>
    _units[_norm(unit)]?.family ?? UnitFamily.unknown;

/// ¿`from` y `to` son convertibles entre sí (misma familia conocida)?
bool areConvertible(String from, String to) {
  final f = _units[_norm(from)];
  final t = _units[_norm(to)];
  if (f == null || t == null) return false;
  return f.family == t.family && f.family != UnitFamily.unknown;
}

/// Convierte `qty` de la unidad `from` a la unidad `to` (misma familia).
/// Devuelve `null` si no son convertibles (familias distintas o unidad
/// desconocida) — el caller decide el fallback.
double? convertUnit(double qty, String from, String to) {
  final f = _units[_norm(from)];
  final t = _units[_norm(to)];
  if (f == null || t == null || f.family != t.family) return null;
  if (t.toBase == 0) return null;
  return qty * f.toBase / t.toBase;
}

/// Unidades base canónicas ofrecidas en el selector del formulario de insumo.
const List<String> baseUnitOptions = <String>['unidad', 'ml', 'L', 'oz', 'g', 'kg'];

/// Unidades de compra/empaque comunes (no convertibles por factor: usan el
/// `pack_size` del insumo). Solo para sugerencias en el selector.
const List<String> purchaseUnitOptions = <String>[
  'Botella',
  'Caja',
  'Paquete',
  'Galón',
  'Lata',
  'Bolsa',
];
