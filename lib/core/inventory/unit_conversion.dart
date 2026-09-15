/// Conversión entre unidades de la MISMA clase (volumen, peso, conteo).
///
/// Qué unidades existen, cómo se llaman y cuánto valen vive en
/// [unit_catalog.dart]; acá está cómo se convierte entre ellas. Complementa
/// [pack_conversion.dart], que maneja el empaque por insumo (1 botella = N
/// unidades base). Esta capa permite escribir recetas en onzas, litros o
/// cucharadas y que el sistema descuente del stock en la unidad base del
/// insumo, convirtiendo automáticamente.
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

import 'unit_catalog.dart';

export 'unit_catalog.dart';

enum UnitFamily { volume, weight, count, unknown }

/// La ONZA no dice de qué familia es: en el bar son 29.5735 ml de ron y en la
/// cocina son 28.3495 g de pechuga. La misma palabra, dos cosas distintas.
///
/// No se puede elegir una y ya: si se fija en volumen, la receta de un sólido
/// no convierte y el descuento sale 16 veces más grande; si se fija en peso,
/// se rompen los cócteles. Se resuelve por CONTEXTO — contra la unidad del
/// otro lado de la conversión, que es como lo lee una persona. Quien quiera
/// decirlo sin ambigüedad tiene `fl oz` en el catálogo.
const double _ozVolume = 29.5735;
const double _ozWeight = 28.349523125;

UnitFamily _familyOf(UnitClass unitClass) {
  switch (unitClass) {
    case UnitClass.weight:
      return UnitFamily.weight;
    case UnitClass.volume:
      return UnitFamily.volume;
    case UnitClass.count:
      return UnitFamily.count;
    case UnitClass.container:
      return UnitFamily.unknown;
  }
}

/// Resuelve una unidad contra la familia de su contraparte. Devuelve null si
/// la unidad no está en el catálogo o no convierte por factor (contenedores).
({UnitFamily family, double toBase})? _resolve(String u, UnitFamily? hint) {
  final def = findUnit(u);
  final factor = def?.toBase;
  if (def == null || factor == null) return null;
  if (def.ambiguous) {
    // Sin pista, la onza es líquida: es el uso histórico y el del bar.
    final fam =
        (hint == UnitFamily.weight) ? UnitFamily.weight : UnitFamily.volume;
    return (
      family: fam,
      toBase: fam == UnitFamily.weight ? _ozWeight : _ozVolume,
    );
  }
  final fam = _familyOf(def.unitClass);
  if (fam == UnitFamily.unknown) return null;
  return (family: fam, toBase: factor);
}

/// La familia de una unidad SIN contexto — null si es ambigua.
UnitFamily? _fixedFamily(String u) {
  final def = findUnit(u);
  if (def == null || def.ambiguous || def.toBase == null) return null;
  final fam = _familyOf(def.unitClass);
  return fam == UnitFamily.unknown ? null : fam;
}

/// Familia de una unidad (o [UnitFamily.unknown] si no convierte).
UnitFamily unitFamily(String unit) =>
    _resolve(unit, null)?.family ?? UnitFamily.unknown;

/// ¿`from` y `to` son convertibles entre sí (misma familia conocida)?
bool areConvertible(String from, String to) => _pair(from, to) != null;

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
  final p = _pair(from, to);
  if (p == null || p.to.toBase == 0) return null;
  return qty * p.from.toBase / p.to.toBase;
}

/// ¿El insumo declara una equivalencia propia usable?
bool _hasConversion(String? unit, double? factor) =>
    unit != null && unit.trim().isNotEmpty && factor != null && factor > 0;

/// ¿Es una MEDIDA (lb, gal, docena) y no un contenedor ni una porción?
bool _isMeasure(String? unit) {
  final def = findUnit(unit);
  return def != null && !def.isContainer && def.toBase != null;
}

/// La familia de una unidad usada como EQUIVALENCIA. La onza a secas va con
/// el peso, que es donde la pone el selector: «1 porción = 8 oz».
UnitFamily _conversionFamily(String unit) {
  final def = findUnit(unit);
  if (def == null || def.toBase == null) return UnitFamily.unknown;
  return def.ambiguous ? UnitFamily.weight : _familyOf(def.unitClass);
}

/// Convierte `quantity` (escrita en `fromUnit`) a la UNIDAD BASE del insumo.
///
/// Es la regla que usan el formulario de recetas y el de modificadores, en
/// este orden:
///   1. si la unidad escrita es la unidad de COMPRA del insumo → × `packSize`
///      (1 botella = 700 ml). «CAJAS» y «Caja» cuentan como la misma;
///   2. si es de la misma familia que la base → factor de conversión;
///   3. si convierte contra la EQUIVALENCIA propia del insumo (1 ea = 200 g)
///      → se lleva a esa unidad y se divide por el factor: 400 g de aguacate
///      son 2 aguacates;
///   4. si la compra es una MEDIDA (1 lb = 3 ea) y la unidad escrita convierte
///      contra ella → se lleva a esa medida y se multiplica por el empaque;
///   5. si no se reconoce → se asume que ya venía en unidad base.
///
/// Preserva el SIGNO: los modificadores guardan cantidades negativas para
/// anular lo que la receta base descuenta («sin queso»).
double toBaseQuantity({
  required double quantity,
  required String fromUnit,
  required String baseUnit,
  String? purchaseUnit,
  double packSize = 1,
  String? conversionUnit,
  double? conversionFactor,
}) {
  final from = fromUnit.trim();
  if (from.isEmpty) return quantity;

  final pu = purchaseUnit?.trim();
  if (pu != null && pu.isNotEmpty && sameUnit(from, pu)) {
    return quantity * (packSize <= 0 ? 1 : packSize);
  }

  final base = baseUnit.trim().isEmpty ? 'unidad' : baseUnit.trim();
  final direct = convertUnit(quantity, from, base);
  if (direct != null) return direct;

  if (_hasConversion(conversionUnit, conversionFactor)) {
    final inConversion = convertUnit(quantity, from, conversionUnit!.trim());
    if (inConversion != null) return inConversion / conversionFactor!;
  }

  if (pu != null && packSize > 0 && _isMeasure(pu)) {
    final inPurchase = convertUnit(quantity, from, pu);
    if (inPurchase != null) return inPurchase * packSize;
  }

  return quantity;
}

const List<String> _volumeOptions = [
  'ml', 'L', 'oz', 'fl oz', 'gal', 'qt', 'cup', 'tbsp', 'tsp', //
];
const List<String> _weightOptions = ['g', 'kg', 'lb', 'oz'];
const List<String> _countOptions = ['unidad', 'dz'];

List<String> _familyOptions(UnitFamily family) {
  switch (family) {
    case UnitFamily.volume:
      return _volumeOptions;
    case UnitFamily.weight:
      return _weightOptions;
    case UnitFamily.count:
      return _countOptions;
    case UnitFamily.unknown:
      return const [];
  }
}

/// Unidades que se le ofrecen al usuario para un insumo: su unidad base + las
/// de su misma familia + la unidad de compra (ej. Botella).
///
/// `oz` aparece en peso además de en volumen: contra un insumo de peso la
/// conversión la resuelve como onza de peso (la pechuga se compra por libra y
/// la receta la pide en onzas). Si la BASE es `oz` a secas se ofrecen las dos
/// familias, porque lo guardado así puede ser de la cocina o del bar.
///
/// Con una EQUIVALENCIA propia (1 ea = 200 g) se ofrece también la familia de
/// esa unidad, y lo mismo si se compra en una medida (por libra).
///
/// `current` conserva la unidad con que se escribió una fila aunque ya no se
/// ofrezca (`cl`), siempre que el insumo la pueda convertir.
List<String> unitOptionsFor({
  required String baseUnit,
  String? purchaseUnit,
  String? current,
  String? conversionUnit,
}) {
  final base = normalizeUnitCode(
    baseUnit.trim().isEmpty ? 'unidad' : baseUnit.trim(),
  );
  final opts = <String>[base];
  void add(String unit) {
    if (!opts.any((o) => sameUnit(o, unit))) opts.add(unit);
  }

  if (findUnit(base)?.ambiguous ?? false) {
    _weightOptions.forEach(add);
    _volumeOptions.forEach(add);
  } else if (unitFamily(base) != UnitFamily.count) {
    // En conteo va la base sola: la docena aparece si una equivalencia o la
    // compra la hacen convertible.
    _familyOptions(unitFamily(base)).forEach(add);
  }

  final pu = purchaseUnit?.trim();
  if (pu != null && pu.isNotEmpty) {
    add(normalizeUnitCode(pu));
    if (_isMeasure(pu)) _familyOptions(unitFamily(pu)).forEach(add);
  }

  final cu = conversionUnit?.trim();
  if (cu != null && cu.isNotEmpty) {
    add(normalizeUnitCode(cu));
    _familyOptions(_conversionFamily(cu)).forEach(add);
  }

  final cur = current?.trim();
  if (cur != null && cur.isNotEmpty) {
    final reachable = areConvertible(cur, base) ||
        (pu != null &&
            pu.isNotEmpty &&
            (sameUnit(cur, pu) || (_isMeasure(pu) && areConvertible(cur, pu)))) ||
        (cu != null && cu.isNotEmpty && areConvertible(cur, cu));
    if (reachable) add(cur);
  }
  return List.unmodifiable(opts);
}

/// Contenido por empaque que sale SOLO: cuando la unidad de compra es una
/// medida que convierte contra la base (1 lb = 453.59 g, 1 gal = 3785.41 mL,
/// 1 dz = 12 unidades), o contra la equivalencia del insumo (con 1 ea = 200 g,
/// una libra trae 2.27 unidades). Null si la compra es un contenedor (una caja
/// trae lo que el proveedor diga) o si no hay cómo convertir.
double? autoPackSize({
  required String purchaseUnit,
  required String baseUnit,
  String? conversionUnit,
  double? conversionFactor,
}) {
  final pu = findUnit(purchaseUnit);
  if (pu == null || pu.isContainer || pu.toBase == null) return null;
  final base = baseUnit.trim().isEmpty ? 'unidad' : baseUnit;
  final direct = convertUnit(1, pu.code, base);
  if (direct != null) return direct;
  if (!_hasConversion(conversionUnit, conversionFactor)) return null;
  final inConversion = convertUnit(1, pu.code, conversionUnit!.trim());
  return inConversion == null ? null : inConversion / conversionFactor!;
}

/// El `pack_size` a guardar. Sin unidad de compra → 1 (sin empaque). Si la
/// compra es una medida convertible manda la conversión, aunque se haya
/// escrito otro número. Si no, lo escrito (o 1 si no es válido).
double resolvePackSize({
  required String purchaseUnit,
  required String baseUnit,
  double? manual,
  String? conversionUnit,
  double? conversionFactor,
}) {
  if (purchaseUnit.trim().isEmpty) return 1;
  final auto = autoPackSize(
    purchaseUnit: purchaseUnit,
    baseUnit: baseUnit,
    conversionUnit: conversionUnit,
    conversionFactor: conversionFactor,
  );
  if (auto != null && auto > 0) return auto;
  return (manual == null || manual <= 0) ? 1 : manual;
}

/// Secciones del selector de EQUIVALENCIA: las medidas de las OTRAS clases.
/// Contra una base en unidades se ofrece peso y volumen; contra una en libras,
/// volumen y conteo. Si la base no convierte («bolsa», porción) se ofrecen
/// todas. `current` conserva la guardada aunque ya no aplique, para que el
/// selector no reviente cuando se cambia la base.
List<UnitSection> conversionUnitSections({
  required String baseUnit,
  String? current,
}) {
  final base = baseUnit.trim().isEmpty ? 'unidad' : baseUnit.trim();
  final baseFamily = (findUnit(base)?.ambiguous ?? false)
      ? UnitFamily.unknown
      : unitFamily(base);
  final sections = <UnitSection>[
    for (final unitClass in const [
      UnitClass.weight,
      UnitClass.volume,
      UnitClass.count,
    ])
      if (_familyOf(unitClass) != baseFamily)
        UnitSection(unitClassTitles[unitClass]!, [
          for (final code in offeredUnitCodes(unitClass))
            if (findUnit(code)?.toBase != null) code,
        ]),
  ];
  final raw = current?.trim() ?? '';
  if (raw.isEmpty ||
      sections.any((s) => s.codes.any((c) => sameUnit(c, raw)))) {
    return sections;
  }
  return [
    UnitSection('Actual', [raw], legacy: true),
    ...sections,
  ];
}

/// La equivalencia que se guarda, o null si no sirve: sin unidad, factor no
/// positivo, unidad fuera del catálogo o que no convierte (contenedor,
/// porción), o de la MISMA familia que la base — 1 lb = 453.59 g ya lo sabe el
/// catálogo, y una propia distinta lo contradiría.
({String unit, double factor})? resolveItemConversion({
  required String baseUnit,
  required String? unit,
  required double? factor,
}) {
  final raw = unit?.trim() ?? '';
  if (raw.isEmpty || factor == null || factor <= 0) return null;
  final def = findUnit(raw);
  if (def == null || def.isContainer || def.toBase == null) return null;
  final base = baseUnit.trim().isEmpty ? 'unidad' : baseUnit.trim();
  final baseAmbiguous = findUnit(base)?.ambiguous ?? false;
  if (!baseAmbiguous && _conversionFamily(def.code) == unitFamily(base)) {
    return null;
  }
  return (unit: def.code, factor: factor);
}

/// Cómo se lee una equivalencia: «1 ea = 200 g».
String conversionLabel({
  required String baseUnit,
  required String unit,
  required double factor,
}) {
  final base = baseUnit.trim().isEmpty ? 'unidad' : baseUnit;
  return '1 ${unitShortLabel(base)} = ${formatUnitQty(factor)} '
      '${unitShortLabel(unit)}';
}

/// Cómo se lee un empaque, al estilo Toast: «24 ea / Caja»,
/// «750 mL / Botella», «50 lb / Saco».
String packLabel({
  required double packSize,
  required String baseUnit,
  required String purchaseUnit,
}) {
  final base = baseUnit.trim().isEmpty ? 'unidad' : baseUnit;
  return '${formatUnitQty(packSize)} ${unitShortLabel(base)} / '
      '${unitShortLabel(purchaseUnit)}';
}

/// Cantidad sin ceros sobrantes: 2 decimales desde 1, 4 por debajo (una onza
/// en libras es 0.0625).
String formatUnitQty(double value) {
  var s = value.toStringAsFixed(value.abs() >= 1 ? 2 : 4);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}
