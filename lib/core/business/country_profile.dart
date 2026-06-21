// Perfil de país — primer ladrillo de la globalización "por país" (ver
// docs/PRD_GLOBALIZACION_POR_PAIS.md). Hoy solo mapea país → moneda base, que
// es lo que el negocio configura al registrarse o en Ajustes → Monedas. Más
// adelante este mismo perfil cargará locale/idioma, presets de impuestos y el
// sistema fiscal por país.
//
// La moneda base se DERIVA del país elegido (default República Dominicana →
// DOP). `currencyCode` siempre referencia un código de `BusinessCurrency.catalog`.

import 'package:flutter/foundation.dart';

import '../currency/business_currency.dart';

@immutable
class CountryProfile {
  /// Código ISO 3166-1 alpha-2 (DO, US, MX, ES, …). Match con
  /// `business_settings.country_code`.
  final String code;

  /// Nombre legible (español) para el selector.
  final String name;

  /// Moneda base del país (ISO 4217 — debe existir en BusinessCurrency.catalog).
  final String currencyCode;

  const CountryProfile({
    required this.code,
    required this.name,
    required this.currencyCode,
  });

  /// Default cuando no hay país configurado. Preserva el comportamiento
  /// histórico (República Dominicana / DOP).
  static const fallbackDo =
      CountryProfile(code: 'DO', name: 'República Dominicana', currencyCode: 'DOP');

  /// Catálogo de países soportados. Clave = ISO 3166-1 alpha-2. El orden de
  /// inserción define el orden del selector (América primero, luego Europa).
  /// Mantener sincronizado con el CHECK de la migración de `country_code`.
  static const Map<String, CountryProfile> catalog = {
    // ---- América ----
    'DO': fallbackDo,
    'US': CountryProfile(code: 'US', name: 'Estados Unidos', currencyCode: 'USD'),
    'CA': CountryProfile(code: 'CA', name: 'Canadá', currencyCode: 'CAD'),
    'MX': CountryProfile(code: 'MX', name: 'México', currencyCode: 'MXN'),
    'GT': CountryProfile(code: 'GT', name: 'Guatemala', currencyCode: 'GTQ'),
    'HN': CountryProfile(code: 'HN', name: 'Honduras', currencyCode: 'HNL'),
    'NI': CountryProfile(code: 'NI', name: 'Nicaragua', currencyCode: 'NIO'),
    'CR': CountryProfile(code: 'CR', name: 'Costa Rica', currencyCode: 'CRC'),
    // Panamá transacciona en USD (el balboa circula a la par solo en monedas).
    'PA': CountryProfile(code: 'PA', name: 'Panamá', currencyCode: 'USD'),
    'CO': CountryProfile(code: 'CO', name: 'Colombia', currencyCode: 'COP'),
    'VE': CountryProfile(code: 'VE', name: 'Venezuela', currencyCode: 'VES'),
    'PE': CountryProfile(code: 'PE', name: 'Perú', currencyCode: 'PEN'),
    'BR': CountryProfile(code: 'BR', name: 'Brasil', currencyCode: 'BRL'),
    'BO': CountryProfile(code: 'BO', name: 'Bolivia', currencyCode: 'BOB'),
    'CL': CountryProfile(code: 'CL', name: 'Chile', currencyCode: 'CLP'),
    'AR': CountryProfile(code: 'AR', name: 'Argentina', currencyCode: 'ARS'),
    'UY': CountryProfile(code: 'UY', name: 'Uruguay', currencyCode: 'UYU'),
    'PY': CountryProfile(code: 'PY', name: 'Paraguay', currencyCode: 'PYG'),
    // ---- Europa ----
    'ES': CountryProfile(code: 'ES', name: 'España', currencyCode: 'EUR'),
    'DE': CountryProfile(code: 'DE', name: 'Alemania', currencyCode: 'EUR'),
    'FR': CountryProfile(code: 'FR', name: 'Francia', currencyCode: 'EUR'),
    'IT': CountryProfile(code: 'IT', name: 'Italia', currencyCode: 'EUR'),
    'PT': CountryProfile(code: 'PT', name: 'Portugal', currencyCode: 'EUR'),
    'GB': CountryProfile(code: 'GB', name: 'Reino Unido', currencyCode: 'GBP'),
    'CH': CountryProfile(code: 'CH', name: 'Suiza', currencyCode: 'CHF'),
    'SE': CountryProfile(code: 'SE', name: 'Suecia', currencyCode: 'SEK'),
    'PL': CountryProfile(code: 'PL', name: 'Polonia', currencyCode: 'PLN'),
  };

  /// Lista ordenada para poblar selectores.
  static List<CountryProfile> get all => catalog.values.toList(growable: false);

  /// Códigos ISO 3166 soportados (para validación / CHECK de la migración).
  static List<String> get supportedCodes =>
      catalog.keys.toList(growable: false);

  /// Construye desde un código ISO 3166. Desconocido → fallback DO.
  factory CountryProfile.fromCode(String? raw) {
    final code = (raw ?? '').trim().toUpperCase();
    return catalog[code] ?? fallbackDo;
  }

  /// Busca por nombre legible (para el flujo legacy del registro, que guardaba
  /// el país como texto). Sin match → fallback DO.
  static CountryProfile fromName(String? raw) {
    final name = (raw ?? '').trim().toLowerCase();
    for (final c in catalog.values) {
      if (c.name.toLowerCase() == name) return c;
    }
    return fallbackDo;
  }

  /// Mapeo inverso moneda→país (primer país del catálogo con esa moneda).
  /// Lossy cuando varios países comparten moneda (ej. EUR → España); se usa
  /// solo para derivar un país de display cuando únicamente persistimos
  /// `currency_code` (modo legacy sin columna `country_code`). Sin match → DO.
  static CountryProfile fromCurrencyCode(String? raw) {
    final code = (raw ?? '').trim().toUpperCase();
    for (final c in catalog.values) {
      if (c.currencyCode == code) return c;
    }
    return fallbackDo;
  }

  /// La moneda base derivada de este país.
  BusinessCurrency get currency => BusinessCurrency.fromCode(currencyCode);

  @override
  bool operator ==(Object other) =>
      other is CountryProfile && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'CountryProfile($code → $currencyCode)';
}
