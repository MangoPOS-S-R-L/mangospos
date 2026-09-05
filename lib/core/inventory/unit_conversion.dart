/// Conversión entre unidades de la MISMA familia (volumen, peso, conteo).
///
/// Complementa [pack_conversion.dart] (que maneja el empaque por insumo:
/// 1 botella = N unidades base). Esta capa permite escribir recetas en
/// onzas/litros/cl y que el sistema descuente del stock en la unidad base
/// del insumo (ml/g), convirtiendo automáticamente.
///
/// Unidad base canónica por familia: volumen → ml, peso → g, conteo → unidad.
/// Funciones puras, sin estado.
///
/// OJO: la conversión ocurre al GUARDAR la receta, no al descontar —
/// `recipe_ingredients.quantity` se persiste ya en la unidad base del insumo,
/// y por eso el SQL la lee cruda. Consecuencia: cambiarle la unidad a un
/// insumo NO re-convierte las recetas ya guardadas, que quedaron en la unidad
/// vieja. Si se cambia una unidad con recetas vivas, hay que rehacerlas.
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
  // Peso (base: g)
  'mg': (family: UnitFamily.weight, toBase: 0.001),
  'g': (family: UnitFamily.weight, toBase: 1),
  'gr': (family: UnitFamily.weight, toBase: 1),
  'gramo': (family: UnitFamily.weight, toBase: 1),
  'gramos': (family: UnitFamily.weight, toBase: 1),
  'kg': (family: UnitFamily.weight, toBase: 1000),
  'kilo': (family: UnitFamily.weight, toBase: 1000),
  'kilos': (family: UnitFamily.weight, toBase: 1000),
  // La libra es la unidad de compra real de una cocina dominicana: la carne,
  // el queso y el embutido se piden por libra, no por kilo. Faltaba, y su
  // ausencia empujaba a la gente a escoger «L» en el selector — que es litro.
  'lb': (family: UnitFamily.weight, toBase: 453.59237),
  'lbs': (family: UnitFamily.weight, toBase: 453.59237),
  'libra': (family: UnitFamily.weight, toBase: 453.59237),
  'libras': (family: UnitFamily.weight, toBase: 453.59237),
  // Conteo (base: unidad)
  'unidad': (family: UnitFamily.count, toBase: 1),
  'unidades': (family: UnitFamily.count, toBase: 1),
  'und': (family: UnitFamily.count, toBase: 1),
  'u': (family: UnitFamily.count, toBase: 1),
  'pieza': (family: UnitFamily.count, toBase: 1),
  'piezas': (family: UnitFamily.count, toBase: 1),
};

/// La ONZA no dice de qué familia es: en el bar son 29.5735 ml de ron y en la
/// cocina son 28.3495 g de pechuga. La misma palabra, dos cosas distintas.
///
/// No se puede elegir una y ya: si se fija en volumen, la receta de un sólido
/// no convierte y el descuento sale 16 veces más grande; si se fija en peso,
/// se rompen los cócteles. Se resuelve por CONTEXTO — contra la unidad del
/// otro lado de la conversión, que es como lo lee una persona.
const Map<String, ({double volume, double weight})> _ambiguous = {
  'oz': (volume: 29.5735, weight: 28.349523125),
  'onz': (volume: 29.5735, weight: 28.349523125),
  'onza': (volume: 29.5735, weight: 28.349523125),
  'onzas': (volume: 29.5735, weight: 28.349523125),
};

String _norm(String u) => u.trim().toLowerCase();

/// Resuelve una unidad contra la familia de su contraparte. Devuelve null si
/// la unidad no existe en ninguna de las dos tablas.
({UnitFamily family, double toBase})? _resolve(String u, UnitFamily? hint) {
  final fixed = _units[u];
  if (fixed != null) return fixed;
  final amb = _ambiguous[u];
  if (amb == null) return null;
  // Sin pista, la onza es líquida: es el uso histórico y el del bar.
  final fam = (hint == UnitFamily.weight) ? UnitFamily.weight : UnitFamily.volume;
  return (
    family: fam,
    toBase: fam == UnitFamily.weight ? amb.weight : amb.volume,
  );
}

/// La familia de una unidad SIN contexto — null si es ambigua.
UnitFamily? _fixedFamily(String u) => _units[u]?.family;

/// Familia de una unidad (o [UnitFamily.unknown] si no está en el catálogo).
UnitFamily unitFamily(String unit) =>
    _resolve(_norm(unit), null)?.family ?? UnitFamily.unknown;

/// ¿`from` y `to` son convertibles entre sí (misma familia conocida)?
bool areConvertible(String from, String to) =>
    _pair(_norm(from), _norm(to)) != null;

/// Resuelve AMBAS unidades tomando cada una como pista de la otra. Null si
/// alguna es desconocida o si acaban en familias distintas.
({({UnitFamily family, double toBase}) from, ({UnitFamily family, double toBase}) to})?
    _pair(String from, String to) {
  final f = _resolve(from, _fixedFamily(to));
  final t = _resolve(to, _fixedFamily(from));
  if (f == null || t == null) return null;
  if (f.family != t.family || f.family == UnitFamily.unknown) return null;
  return (from: f, to: t);
}

/// Convierte `qty` de la unidad `from` a la unidad `to` (misma familia).
/// Devuelve `null` si no son convertibles (familias distintas o unidad
/// desconocida) — el caller decide el fallback.
double? convertUnit(double qty, String from, String to) {
  final p = _pair(_norm(from), _norm(to));
  if (p == null || p.to.toBase == 0) return null;
  return qty * p.from.toBase / p.to.toBase;
}

/// Unidades base canónicas ofrecidas en el selector del formulario de insumo.
///
/// `lb` va junto a `g`/`kg` porque es la unidad con que de verdad se compra en
/// la cocina. `oz` queda en la familia de VOLUMEN (onza líquida) porque es la
/// que usa el bar en sus cócteles; para un sólido que viene en onzas —una
/// bolsa de 10 oz— la unidad base es la bolsa y el peso se declara en el
/// empaque (`pack_size`), que es justamente para lo que existe.
const List<String> baseUnitOptions = <String>[
  'unidad',
  'ml',
  'L',
  'oz',
  'g',
  'kg',
  'lb',
];

/// Unidades de compra/empaque comunes (no convertibles por factor: usan el
/// `pack_size` del insumo). Solo para sugerencias en el selector.
const List<String> purchaseUnitOptions = <String>[
  'Botella',
  'Caja',
  'Paquete',
  'Galón',
  'Lata',
  'Bolsa',
  'Libra',
  'Saco',
  'Funda',
];
