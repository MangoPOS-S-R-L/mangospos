// Catálogo único de tipos de comprobante fiscal (NCF / e-NCF) de la DGII
// de República Dominicana.
//
// Antes este mapeo vivía duplicado en al menos 4 archivos del módulo de
// reportes y otros 9+ archivos del resto de la app — cada uno con un set
// distinto de códigos cubiertos. Si DGII agrega un código nuevo o
// renombra uno, había que tocar 13+ lugares. Y al divergir, distintas
// pantallas mostraban distintos nombres para el mismo código.
//
// Fuente: norma DGII para NCF (Bxx serie física) y e-CF (Exx serie
// electrónica). Cada par Bxx/Exx comparte el mismo tipo conceptual.

const Map<String, String> _ncfTypeNames = {
  // Crédito fiscal (B01) y e-CF (E31)
  'B01': 'Crédito Fiscal',
  'E31': 'Crédito Fiscal',
  // Consumo (B02 / E32)
  'B02': 'Consumo',
  'E32': 'Consumo',
  // Nota de débito (B03 / E33)
  'B03': 'Nota de Débito',
  'E33': 'Nota de Débito',
  // Nota de crédito (B04 / E34)
  'B04': 'Nota de Crédito',
  'E34': 'Nota de Crédito',
  // Compras (B11 / E41)
  'B11': 'Compras',
  'E41': 'Compras',
  // Gastos menores (B13 / E43)
  'B13': 'Gastos Menores',
  'E43': 'Gastos Menores',
  // Regímenes especiales (B14 / E44)
  'B14': 'Regímenes Especiales',
  'E44': 'Regímenes Especiales',
  // Gubernamental (B15 / E45)
  'B15': 'Gubernamental',
  'E45': 'Gubernamental',
  // Exportaciones (B16 / E46)
  'B16': 'Exportaciones',
  'E46': 'Exportaciones',
};

/// Nombre legible del tipo de NCF dado el código DGII.
///
/// Si el código no está mapeado (típicamente porque DGII agregó uno nuevo
/// y este catálogo aún no se actualizó), devuelve el código tal cual —
/// preferimos mostrar "B17" que nada, así el usuario sabe que hay info
/// que no estamos interpretando.
///
/// Acepta strings vacíos o nulos defensivamente: devuelve "—".
String ncfTypeName(String? code) {
  if (code == null || code.trim().isEmpty) return '—';
  final clean = code.trim().toUpperCase();
  return _ncfTypeNames[clean] ?? clean;
}

/// Lista de todos los códigos NCF/e-NCF conocidos, ordenados por código.
/// Útil para dropdowns/filtros que necesiten enumerar opciones.
List<String> get allKnownNcfCodes =>
    _ncfTypeNames.keys.toList(growable: false)..sort();

// ---------------------------------------------------------------------------
// Serie: electronica (Exx) vs papel (Bxx)
// ---------------------------------------------------------------------------

/// Sufijos numericos de la serie ELECTRONICA (e-CF).
const Set<String> _electronicSuffixes = {
  '31', '32', '33', '34', '41', '43', '44', '45', '46',
};

/// Sufijos numericos de la serie de PAPEL (NCF tradicional).
const Set<String> _paperSuffixes = {
  '01', '02', '03', '04', '11', '13', '14', '15', '16',
};

/// True si el comprobante es electronico (e-CF).
///
/// Acepta las tres formas en que el codigo circula por la app: con letra
/// ('E32', 'B02') y **pelado** ('32', '02'). El pelado no es un caso raro:
/// `SalesViewModel._normalizeFiscalTypeValue` le quita la letra antes de
/// guardarlo en el estado de la orden, asi que es exactamente lo que recibe
/// el modal de cobro. Un `startsWith('E')` sobre ese valor da false siempre y
/// hace creer que un e-CF es papel.
bool isElectronicNcf(String? code) {
  final c = code?.trim().toUpperCase();
  if (c == null || c.isEmpty) return false;
  if (c.startsWith('E')) return true;
  if (c.startsWith('B')) return false;
  return _electronicSuffixes.contains(c);
}

/// Codigo DGII completo, reponiendo la letra si viene pelado.
/// '32' -> 'E32', '02' -> 'B02', 'E31' -> 'E31'.
///
/// Devuelve el valor tal cual si no reconoce el sufijo: preferimos mostrar
/// algo raro a inventarle una serie que no es.
String? fullNcfCode(String? code) {
  final c = code?.trim().toUpperCase();
  if (c == null || c.isEmpty) return null;
  if (c.startsWith('E') || c.startsWith('B')) return c;
  if (_electronicSuffixes.contains(c)) return 'E$c';
  if (_paperSuffixes.contains(c)) return 'B$c';
  return c;
}
