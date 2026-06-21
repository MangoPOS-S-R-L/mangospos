// Modelo de moneda por negocio — fuente única para que toda la app deje de
// asumir que la moneda es siempre RD$. El símbolo (RD$, $, €, …) y la cantidad
// de decimales se derivan del código ISO 4217 almacenado en
// `business_settings.currency_code`.
//
// Para soportar el negocio globalmente cada moneda vive en [catalog]. Agregar
// una moneda nueva = agregar una entrada al mapa (y al CHECK de la migración).
// El resto de la app no se toca: consume [BusinessCurrency] vía el provider.

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

@immutable
class BusinessCurrency {
  /// Código ISO 4217. Match con `business_settings.currency_code`.
  final String code;

  /// Símbolo para mostrar en UI (`RD$`, `US$`, `€`, …). NO incluir espacios —
  /// `NumberFormat.currency` los maneja según locale.
  final String symbol;

  /// Nombre legible para el selector de moneda en Ajustes.
  final String name;

  /// Cantidad de decimales que muestra el formatter. La mayoría usa 2; algunas
  /// monedas no circulan con fracción (JPY, CLP, PYG, HUF, ISK → 0) y otras
  /// usan 3 (KWD, BHD, TND). Default 2.
  final int decimalDigits;

  /// Locale para agrupar miles y ubicar el símbolo (1,234.56 vs 1.234,56 €).
  /// Las monedas europeas usan su convención local; América anglosajona usa
  /// `en_US`. Default `en_US`.
  final String locale;

  const BusinessCurrency({
    required this.code,
    required this.symbol,
    this.name = '',
    this.decimalDigits = 2,
    this.locale = 'en_US',
  });

  /// Default cuando no hay business settings (sesión recién iniciada,
  /// usuario sin negocio activo, query falla). Coincide con el legacy
  /// hardcoded `RD$` que vivía repartido en la app.
  static const fallbackDop = BusinessCurrency(
    code: 'DOP',
    symbol: r'RD$',
    name: 'Peso dominicano',
  );

  /// Catálogo de monedas soportadas (principales de América y Europa más las
  /// reservas globales). Clave = código ISO 4217. El orden de inserción se
  /// preserva y define el orden del selector (América primero, luego Europa).
  ///
  /// Para DOP/USD/EUR los símbolos se mantienen idénticos al comportamiento
  /// histórico (`RD$`, `US$`, `€`) para no alterar negocios existentes.
  static const Map<String, BusinessCurrency> catalog = {
    // ---- América ----
    'DOP': fallbackDop,
    'USD': BusinessCurrency(
        code: 'USD', symbol: r'US$', name: 'Dólar estadounidense'),
    'CAD': BusinessCurrency(
        code: 'CAD', symbol: r'CA$', name: 'Dólar canadiense', locale: 'en_CA'),
    'MXN': BusinessCurrency(
        code: 'MXN', symbol: r'MX$', name: 'Peso mexicano', locale: 'es_MX'),
    'BRL': BusinessCurrency(
        code: 'BRL', symbol: r'R$', name: 'Real brasileño', locale: 'pt_BR'),
    'ARS': BusinessCurrency(
        code: 'ARS', symbol: r'AR$', name: 'Peso argentino', locale: 'es_AR'),
    'CLP': BusinessCurrency(
        code: 'CLP',
        symbol: r'CLP$',
        name: 'Peso chileno',
        decimalDigits: 0,
        locale: 'es_CL'),
    'COP': BusinessCurrency(
        code: 'COP',
        symbol: r'CO$',
        name: 'Peso colombiano',
        decimalDigits: 0,
        locale: 'es_CO'),
    'PEN': BusinessCurrency(
        code: 'PEN', symbol: 'S/', name: 'Sol peruano', locale: 'es_PE'),
    'UYU': BusinessCurrency(
        code: 'UYU', symbol: r'$U', name: 'Peso uruguayo', locale: 'es_UY'),
    'BOB': BusinessCurrency(
        code: 'BOB', symbol: 'Bs', name: 'Boliviano', locale: 'es_BO'),
    'PYG': BusinessCurrency(
        code: 'PYG',
        symbol: '₲',
        name: 'Guaraní',
        decimalDigits: 0,
        locale: 'es_PY'),
    'GTQ': BusinessCurrency(
        code: 'GTQ', symbol: 'Q', name: 'Quetzal', locale: 'es_GT'),
    'HNL': BusinessCurrency(
        code: 'HNL', symbol: 'L', name: 'Lempira', locale: 'es_HN'),
    'NIO': BusinessCurrency(
        code: 'NIO', symbol: r'C$', name: 'Córdoba', locale: 'es_NI'),
    'CRC': BusinessCurrency(
        code: 'CRC',
        symbol: '₡',
        name: 'Colón costarricense',
        locale: 'es_CR'),
    'PAB': BusinessCurrency(
        code: 'PAB', symbol: 'B/.', name: 'Balboa panameño', locale: 'es_PA'),
    'VES': BusinessCurrency(
        code: 'VES',
        symbol: r'Bs.S',
        name: 'Bolívar venezolano',
        locale: 'es_VE'),
    // ---- Europa ----
    'EUR': BusinessCurrency(
        code: 'EUR', symbol: '€', name: 'Euro', locale: 'es_ES'),
    'GBP': BusinessCurrency(
        code: 'GBP', symbol: '£', name: 'Libra esterlina', locale: 'en_GB'),
    'CHF': BusinessCurrency(
        code: 'CHF', symbol: 'CHF', name: 'Franco suizo', locale: 'de_CH'),
    'SEK': BusinessCurrency(
        code: 'SEK', symbol: 'kr', name: 'Corona sueca', locale: 'sv_SE'),
    'NOK': BusinessCurrency(
        code: 'NOK', symbol: 'kr', name: 'Corona noruega', locale: 'nb_NO'),
    'DKK': BusinessCurrency(
        code: 'DKK', symbol: 'kr', name: 'Corona danesa', locale: 'da_DK'),
    'PLN': BusinessCurrency(
        code: 'PLN', symbol: 'zł', name: 'Złoty polaco', locale: 'pl_PL'),
    'CZK': BusinessCurrency(
        code: 'CZK', symbol: 'Kč', name: 'Corona checa', locale: 'cs_CZ'),
    'HUF': BusinessCurrency(
        code: 'HUF',
        symbol: 'Ft',
        name: 'Forinto húngaro',
        decimalDigits: 0,
        locale: 'hu_HU'),
    'RON': BusinessCurrency(
        code: 'RON', symbol: 'lei', name: 'Leu rumano', locale: 'ro_RO'),
    'BGN': BusinessCurrency(
        code: 'BGN', symbol: 'лв', name: 'Lev búlgaro', locale: 'bg_BG'),
    'ISK': BusinessCurrency(
        code: 'ISK',
        symbol: 'kr',
        name: 'Corona islandesa',
        decimalDigits: 0,
        locale: 'is_IS'),
    'TRY': BusinessCurrency(
        code: 'TRY', symbol: '₺', name: 'Lira turca', locale: 'tr_TR'),
    'UAH': BusinessCurrency(
        code: 'UAH', symbol: '₴', name: 'Grivna ucraniana', locale: 'uk_UA'),
    'RSD': BusinessCurrency(
        code: 'RSD', symbol: 'din.', name: 'Dinar serbio', locale: 'sr_RS'),
  };

  /// Lista ordenada de monedas soportadas para poblar el selector.
  static List<BusinessCurrency> get all => catalog.values.toList(growable: false);

  /// Códigos ISO 4217 soportados (para validación / CHECK de la migración).
  static List<String> get supportedCodes => catalog.keys.toList(growable: false);

  /// Construye desde un código ISO. Acepta lowercase/upper y trim.
  /// Códigos desconocidos caen al fallback DOP — preferimos UI funcional
  /// a crashear; la BD ya tiene CHECK constraint para inputs inválidos.
  factory BusinessCurrency.fromCode(String? raw) {
    final code = (raw ?? '').trim().toUpperCase();
    return catalog[code] ?? fallbackDop;
  }

  /// Formatter listo para `currency.format(monto)`.
  NumberFormat get formatter => NumberFormat.currency(
        symbol: symbol,
        decimalDigits: decimalDigits,
        locale: locale,
      );

  /// Helper para los lugares legacy que usan `'RD\$${monto.toStringAsFixed(2)}'`
  /// concatenando manualmente. Reemplazar progresivamente por [formatter].
  String formatAmount(num amount) => formatter.format(amount);

  @override
  bool operator ==(Object other) =>
      other is BusinessCurrency && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'BusinessCurrency($code, $symbol)';
}
