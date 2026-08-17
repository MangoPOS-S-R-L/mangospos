/// Formato del comprobante fiscal (NCF / e-CF) que emite la DGII.
///
/// Serie + tipo + secuencia: una letra de serie (`B` para NCF, `E` para e-CF),
/// dos dígitos de tipo de comprobante y una secuencia de 8 a 10 dígitos.
/// Ej. `B0100000284` (11) · `E310000000001` (13).
///
/// El NCF es OPCIONAL en el registro de compra: un proveedor informal, un
/// colmado de barrio o una factura de consumidor final no otorgan crédito de
/// ITBIS y no tienen NCF que anotar. Exigirlo empujaría a inventar valores.
/// Pero cuando viene, tiene que ser válido: un NCF mal escrito no sirve para
/// nada y solo se descubre meses después.
class NcfFormat {
  const NcfFormat._();

  static final RegExp _pattern = RegExp(r'^[BE]\d{2}\d{8,10}$');

  /// Mayúsculas y sin espacios. El NCF impreso a veces trae separadores
  /// visuales; normalizar antes de validar evita rechazar un valor correcto
  /// por cómo lo copió quien registra.
  static String normalize(String raw) =>
      raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');

  static bool isValid(String raw) => _pattern.hasMatch(normalize(raw));

  /// `null` = puede guardarse. Vacío es válido (el NCF es opcional); con
  /// contenido, un valor que no cumple el patrón BLOQUEA el guardado con el
  /// motivo escrito — nunca se corrige en silencio.
  static String? validate(String raw) {
    final value = normalize(raw);
    if (value.isEmpty) return null;
    if (_pattern.hasMatch(value)) return null;
    return 'El NCF "$value" no tiene el formato de la DGII: serie B o E, dos '
        'dígitos de tipo y de 8 a 10 de secuencia. Ej. B0100000284.';
  }
}
