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
