/// Catálogo de unidades de medida — la fuente ÚNICA de qué unidades existen,
/// de qué clase son, cómo se muestran y cuánto valen.
///
/// Sigue el modelo de Toast/xtraCHEF: cuatro clases —peso, volumen, conteo y
/// contenedor— y el CONTENEDOR es solo de compra. Una caja no se cuenta ni
/// entra en una receta: se abre, y lo que trae vive en la unidad base del
/// insumo («24 ea / Caja», «50 lb / Saco», «750 mL / Botella»).
///
/// El [UnitDef.code] es lo que se GUARDA en `inventory_items.unit` y
/// `purchase_unit`, y a propósito es lo que ya había en la base (`unidad`,
/// `ml`, `L`, `lb`, `Caja`, `Botella`): la columna nace con `'unidad'` y medio
/// centenar de lugares de la app caen a ese valor. Lo que se escribió a mano
/// de otra forma («CAJAS», «LIBRA», «gr», «lt») se reconoce por alias, sin
/// migrar datos.
///
/// Las conversiones entre unidades viven en `unit_conversion.dart`.
/// Funciones puras, sin Flutter.
library;

/// Las cuatro clases de Toast. Peso, volumen y conteo convierten dentro de su
/// clase; el contenedor no convierte: se declara cuánto trae (`pack_size`).
enum UnitClass { weight, volume, count, container }

class UnitDef {
  /// Lo que se guarda en la base.
  final String code;
  final UnitClass unitClass;

  /// Cómo se muestra corto: lb, fl oz, mL, ea, CS.
  final String abbr;

  /// Nombre en español: Libra, Onza líquida, Unidad, Caja.
  final String label;

  /// Cuánto vale 1 de esta unidad en la base de su clase (g, ml o unidad).
  /// Null = no convierte por factor: contenedores, porción y rebanada.
  final double? toBase;

  /// La onza sin apellido. Su clase se decide por contexto: ver
  /// `unit_conversion.dart`.
  final bool ambiguous;

  /// Si se ofrece en los selectores. Las que no (mg, cl) siguen convirtiendo
  /// para no romper lo que ya estaba guardado con ellas.
  final bool offered;

  /// Si la abreviatura también identifica la unidad al leer texto. Funda
  /// comparte «BG» con Saco y no se la puede quitar.
  final bool matchAbbr;

  final List<String> aliases;

  const UnitDef(
    this.code,
    this.unitClass,
    this.abbr,
    this.label, {
    this.toBase,
    this.ambiguous = false,
    this.offered = true,
    this.matchAbbr = true,
    this.aliases = const [],
  });

  bool get isContainer => unitClass == UnitClass.container;
}

/// En el orden en que se muestran, que es el de la tabla de Toast.
const List<UnitDef> unitCatalog = [
  // ── Peso (base: g) ────────────────────────────────────────────────────────
  // La libra primero: es como compra una cocina dominicana la carne, el queso
  // y el embutido.
  UnitDef('lb', UnitClass.weight, 'lb', 'Libra',
      toBase: 453.59237, aliases: ['lbs', 'libras']),
  // `oz` a secas. En el selector es la de PESO (Toast separa OZ de FL OZ),
  // pero lo guardado antes con «oz» puede ser del bar, así que la conversión
  // la sigue resolviendo por contexto.
  UnitDef('oz', UnitClass.weight, 'oz', 'Onza',
      toBase: 28.349523125, ambiguous: true, aliases: ['onz', 'onzas']),
  UnitDef('kg', UnitClass.weight, 'kg', 'Kilo',
      toBase: 1000, aliases: ['kgs', 'kilos', 'kilogramo', 'kilogramos']),
  UnitDef('g', UnitClass.weight, 'g', 'Gramo',
      toBase: 1, aliases: ['gr', 'grs', 'gramos']),
  UnitDef('mg', UnitClass.weight, 'mg', 'Miligramo',
      toBase: 0.001, offered: false),

  // ── Volumen (base: ml) ────────────────────────────────────────────────────
  UnitDef('gal', UnitClass.volume, 'gal', 'Galón',
      toBase: 3785.411784, aliases: ['gl', 'galones']),
  // Galón, cuarto, taza, cucharada y cucharadita son los de EE. UU. y salen
  // todos del galón: ÷4, ÷16, ÷256, ÷768.
  UnitDef('qt', UnitClass.volume, 'qt', 'Cuarto',
      toBase: 946.352946, aliases: ['cuartos']),
  UnitDef('fl oz', UnitClass.volume, 'fl oz', 'Onza líquida',
      toBase: 29.5735,
      aliases: ['floz', 'oz fl', 'oz liquida', 'onzas liquidas']),
  UnitDef('L', UnitClass.volume, 'L', 'Litro',
      toBase: 1000, aliases: ['lt', 'lts', 'litros']),
  UnitDef('ml', UnitClass.volume, 'mL', 'Mililitro',
      toBase: 1, aliases: ['cc', 'mililitros']),
  UnitDef('cl', UnitClass.volume, 'cL', 'Centilitro',
      toBase: 10, offered: false),
  UnitDef('cup', UnitClass.volume, 'cup', 'Taza',
      toBase: 236.5882365, aliases: ['tazas']),
  UnitDef('tbsp', UnitClass.volume, 'tbsp', 'Cucharada',
      toBase: 14.78676478125, aliases: ['cda', 'cdas', 'cucharadas']),
  UnitDef('tsp', UnitClass.volume, 'tsp', 'Cucharadita',
      toBase: 4.92892159375, aliases: ['cdta', 'cdtas', 'cucharaditas']),

  // ── Conteo (base: unidad) ─────────────────────────────────────────────────
  UnitDef('unidad', UnitClass.count, 'ea', 'Unidad', toBase: 1, aliases: [
    'unidades', 'und', 'ud', 'uds', 'u', 'each', 'ct', 'pieza', 'piezas', //
  ]),
  UnitDef('dz', UnitClass.count, 'dz', 'Docena',
      toBase: 12, aliases: ['docenas']),
  // Porción y rebanada son de conteo pero NO valen «1 unidad» del insumo: una
  // rebanada de queso no es un queso. Sirven de base propia; no convierten.
  UnitDef('porcion', UnitClass.count, 'porción', 'Porción',
      aliases: ['porciones', 'portion']),
  UnitDef('rebanada', UnitClass.count, 'rebanada', 'Rebanada',
      aliases: ['rebanadas', 'slice', 'lonja', 'lonjas']),

  // ── Contenedor (solo compra) ──────────────────────────────────────────────
  UnitDef('Caja', UnitClass.container, 'CS', 'Caja',
      aliases: ['cajas', 'case']),
  UnitDef('Caja chica', UnitClass.container, 'BX', 'Caja chica',
      aliases: ['box', 'cajita']),
  UnitDef('Saco', UnitClass.container, 'BG', 'Saco',
      aliases: ['sacos', 'bag']),
  UnitDef('Funda', UnitClass.container, 'BG', 'Funda',
      matchAbbr: false, aliases: ['fundas', 'bolsa', 'bolsas']),
  UnitDef('Paquete', UnitClass.container, 'PK', 'Paquete',
      aliases: ['paquetes', 'paq', 'pack']),
  UnitDef('Botella', UnitClass.container, 'BTL', 'Botella',
      aliases: ['botellas']),
  UnitDef('Lata', UnitClass.container, 'CAN', 'Lata', aliases: ['latas']),
  UnitDef('Pote', UnitClass.container, 'JAR', 'Pote',
      aliases: ['potes', 'frasco', 'frascos', 'tarro', 'tub']),
  UnitDef('Cubeta', UnitClass.container, 'PAIL', 'Cubeta',
      aliases: ['cubetas', 'balde', 'baldes']),
  UnitDef('Bandeja', UnitClass.container, 'TRAY', 'Bandeja',
      aliases: ['bandejas']),
  UnitDef('Cartón', UnitClass.container, 'FLAT', 'Cartón',
      aliases: ['cartones']),
  UnitDef('Barril', UnitClass.container, 'KEG', 'Barril',
      aliases: ['barriles']),
  UnitDef('Caja post-mix', UnitClass.container, 'BIB', 'Caja post-mix',
      aliases: ['postmix', 'bag in box']),
];

/// Clave de búsqueda: minúsculas, sin tildes, sin puntos y con un solo
/// espacio. «Galón», «GALON» y «galon» son la misma; «fl. oz» es «fl oz».
String normalizeUnitKey(String raw) {
  const accents = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u'};
  final out = StringBuffer();
  for (final rune in raw.trim().toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    out.write(accents[ch] ?? ch);
  }
  return out
      .toString()
      .replaceAll('.', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Código, nombre, abreviatura y alias → unidad. Gana la primera en el
/// catálogo, y un test verifica que ninguna clave apunte a dos unidades.
final Map<String, UnitDef> _index = () {
  final index = <String, UnitDef>{};
  for (final def in unitCatalog) {
    final keys = [def.code, def.label, if (def.matchAbbr) def.abbr, ...def.aliases];
    for (final key in keys) {
      index.putIfAbsent(normalizeUnitKey(key), () => def);
    }
  }
  return index;
}();

/// La unidad del catálogo que corresponde a un texto, o null si no está.
UnitDef? findUnit(String? raw) {
  if (raw == null) return null;
  final key = normalizeUnitKey(raw);
  return key.isEmpty ? null : _index[key];
}

/// El código a guardar para un texto: el del catálogo, o el texto tal cual
/// si no está (nunca se inventa una unidad).
String normalizeUnitCode(String raw) => findUnit(raw)?.code ?? raw.trim();

/// ¿Son la misma unidad escrita de dos formas («CAJAS» y «Caja»)?
bool sameUnit(String a, String b) {
  final ka = normalizeUnitKey(a);
  final kb = normalizeUnitKey(b);
  if (ka.isEmpty || kb.isEmpty) return false;
  if (ka == kb) return true;
  final def = _index[ka];
  return def != null && identical(def, _index[kb]);
}

/// Etiqueta corta, la que va junto a una cantidad: «lb», «mL», «ea» — y el
/// nombre para un contenedor, que se lee mejor que su código («Caja»).
String unitShortLabel(String raw) {
  final def = findUnit(raw);
  if (def == null) return raw.trim();
  return def.isContainer ? def.label : def.abbr;
}

/// Etiqueta del menú: «Libra (lb)», «Caja (CS)», «Porción».
String unitMenuLabel(String raw) {
  final def = findUnit(raw);
  if (def == null) return raw.trim();
  if (normalizeUnitKey(def.label) == normalizeUnitKey(def.abbr)) {
    return def.label;
  }
  return '${def.label} (${def.abbr})';
}

/// Un grupo del selector: el título de la clase y sus códigos.
class UnitSection {
  final String title;
  final List<String> codes;

  /// La unidad GUARDADA que no está en el catálogo («bolsa» usada como base,
  /// «manojo»). Se muestra tal cual para no perderla al editar.
  final bool legacy;

  const UnitSection(this.title, this.codes, {this.legacy = false});
}

const Map<UnitClass, String> unitClassTitles = {
  UnitClass.weight: 'Peso',
  UnitClass.volume: 'Volumen',
  UnitClass.count: 'Conteo',
  UnitClass.container: 'Contenedor',
};

/// Códigos que se ofrecen de una clase, en el orden del catálogo.
List<String> offeredUnitCodes(UnitClass unitClass) => [
      for (final def in unitCatalog)
        if (def.offered && def.unitClass == unitClass) def.code,
    ];

/// Secciones del selector de unidad BASE: peso, volumen y conteo. El
/// contenedor no va porque es solo de compra.
List<UnitSection> baseUnitSections({String? current}) => _sections(
      const [UnitClass.weight, UnitClass.volume, UnitClass.count],
      current,
    );

/// Secciones del selector de unidad de COMPRA: contenedores primero y
/// después las medidas (se puede comprar por libra o por galón).
List<UnitSection> purchaseUnitSections({String? current}) => _sections(
      const [
        UnitClass.container,
        UnitClass.weight,
        UnitClass.volume,
        UnitClass.count,
      ],
      current,
    );

List<UnitSection> _sections(List<UnitClass> classes, String? current) {
  final sections = [
    for (final c in classes) UnitSection(unitClassTitles[c]!, offeredUnitCodes(c)),
  ];
  final raw = current?.trim() ?? '';
  if (raw.isEmpty) return sections;
  final known = sections.any((s) => s.codes.any((c) => sameUnit(c, raw)));
  if (known) return sections;
  return [
    UnitSection('Actual', [raw], legacy: true),
    ...sections,
  ];
}

/// El valor que queda seleccionado para lo guardado: el mismo texto si está
/// entre las opciones, si no su equivalente del catálogo («gr» → g), y si no
/// el `fallback`.
String unitSelectionValue(
  List<UnitSection> sections,
  String? current, {
  required String fallback,
}) {
  final raw = current?.trim() ?? '';
  if (raw.isEmpty) return fallback;
  for (final section in sections) {
    if (section.codes.contains(raw)) return raw;
  }
  for (final section in sections) {
    if (section.legacy) continue;
    for (final code in section.codes) {
      if (sameUnit(code, raw)) return code;
    }
  }
  return fallback;
}

/// La opción de una lista plana que es la misma unidad que `current`.
String? matchUnitOption(List<String> options, String current) {
  for (final option in options) {
    if (option == current.trim()) return option;
  }
  for (final option in options) {
    if (sameUnit(option, current)) return option;
  }
  return null;
}

/// Unidades base ofrecidas en los formularios de insumo.
final List<String> baseUnitOptions = [
  for (final section in baseUnitSections()) ...section.codes,
];

/// Unidades de compra ofrecidas: contenedores y medidas.
final List<String> purchaseUnitOptions = [
  for (final section in purchaseUnitSections()) ...section.codes,
];
