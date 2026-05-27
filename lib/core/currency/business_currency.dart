// Modelo de moneda por negocio — fuente única para que toda la app deje de
// asumir que la moneda es siempre RD$. El símbolo (RD$, $, €) se deriva del
// código ISO 4217 (DOP/USD/EUR) almacenado en `business_settings.currency_code`.
//
// Si en el futuro hay que agregar más monedas, esto es lo único que se toca
// (más el CHECK en la migración).

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

@immutable
class BusinessCurrency {
  /// Código ISO 4217. Match con `business_settings.currency_code`.
  final String code;

  /// Símbolo para mostrar en UI (`RD$`, `US$`, `€`). NO incluir espacios —
  /// `NumberFormat.currency` los maneja según locale.
  final String symbol;

  /// Cantidad de decimales que muestra el formatter. Default 2.
  final int decimalDigits;

  /// Locale para agrupar miles (1,234.56 vs 1.234,56). Default `en_US`
  /// porque la app usa separadores anglosajones tradicionalmente.
  final String locale;

  const BusinessCurrency({
    required this.code,
    required this.symbol,
    this.decimalDigits = 2,
    this.locale = 'en_US',
  });

  /// Default cuando no hay business settings (sesión recién iniciada,
  /// usuario sin negocio activo, query falla). Coincide con el legacy
  /// hardcoded `RD$` que vivía repartido en la app.
  static const fallbackDop = BusinessCurrency(
    code: 'DOP',
    symbol: r'RD$',
  );

  /// Construye desde un código ISO. Acepta lowercase/upper y trim.
  /// Códigos desconocidos caen al fallback DOP — preferimos UI funcional
  /// que crashear; la BD ya tiene CHECK constraint para inputs inválidos.
  factory BusinessCurrency.fromCode(String? raw) {
    final code = (raw ?? '').trim().toUpperCase();
    switch (code) {
      case 'DOP':
        return const BusinessCurrency(code: 'DOP', symbol: r'RD$');
      case 'USD':
        return const BusinessCurrency(code: 'USD', symbol: r'US$');
      case 'EUR':
        return const BusinessCurrency(code: 'EUR', symbol: '€');
      default:
        return fallbackDop;
    }
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
