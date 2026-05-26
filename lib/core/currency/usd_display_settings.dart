// PRD 6 — Modelo de configuración de moneda secundaria USD.
//
// Representa los 6 campos en `business_settings` que controlan el
// display-only de USD. NO es para procesar pagos; solo para mostrar
// el equivalente al cliente en checkout y recibos.

import 'package:decimal/decimal.dart';

class UsdDisplaySettings {
  /// Toggle maestro. Si `false`, no se muestra nada relacionado a USD
  /// en ninguna parte del sistema. Default false (opt-in).
  final bool enabled;

  /// Símbolo a mostrar — default 'US$'. Editable hasta 5 chars.
  final String symbol;

  /// Tasa de cambio RD$ por 1 USD. NULL si nunca se configuró.
  /// El caller debe verificar que NO sea null y > 0 antes de calcular.
  final Decimal? rate;

  /// Última actualización de la tasa (auto-poblado por trigger en DB).
  /// Si está stale (>7 días) la UI muestra banner amarillo (PRD §6.1).
  final DateTime? rateUpdatedAt;

  /// `'before'` → US$89.26  / `'after'` → 89.26 US$. Default 'before'.
  final String symbolPosition;

  const UsdDisplaySettings({
    required this.enabled,
    required this.symbol,
    required this.rate,
    required this.rateUpdatedAt,
    required this.symbolPosition,
  });

  /// Default cuando no hay fila en `business_settings` o la query falla.
  /// PRD §6.1 dice que el feature es opt-in, así que disabled.
  const UsdDisplaySettings.disabled()
      : enabled = false,
        symbol = 'US\$',
        rate = null,
        rateUpdatedAt = null,
        symbolPosition = 'before';

  /// Parse desde la fila de `business_settings`.
  factory UsdDisplaySettings.fromMap(Map<String, dynamic> map) {
    Decimal? parseRate(dynamic raw) {
      if (raw == null) return null;
      if (raw is num) return Decimal.parse(raw.toString());
      final s = raw.toString();
      try {
        return Decimal.parse(s);
      } catch (_) {
        return null;
      }
    }

    DateTime? parseDate(dynamic raw) {
      if (raw == null) return null;
      if (raw is DateTime) return raw;
      return DateTime.tryParse(raw.toString());
    }

    return UsdDisplaySettings(
      enabled: map['usd_display_enabled'] == true,
      symbol: (map['usd_symbol'] as String?)?.trim().isNotEmpty == true
          ? (map['usd_symbol'] as String).trim()
          : 'US\$',
      rate: parseRate(map['usd_rate']),
      rateUpdatedAt: parseDate(map['usd_rate_updated_at']),
      symbolPosition:
          (map['usd_symbol_position'] as String?)?.trim() == 'after'
              ? 'after'
              : 'before',
    );
  }

  /// True si el feature está activo Y la tasa es válida para mostrar.
  /// Lo que el resto del código debería usar para decidir si render.
  bool get isUsable =>
      enabled && rate != null && rate! > Decimal.zero;

  /// True si la tasa no se actualiza hace más de 7 días (PRD §6.1).
  /// Se usa para mostrar banner amarillo en Settings.
  bool get isStale {
    final updated = rateUpdatedAt;
    if (updated == null) return enabled;
    return DateTime.now().difference(updated).inDays > 7;
  }

  UsdDisplaySettings copyWith({
    bool? enabled,
    String? symbol,
    Decimal? rate,
    DateTime? rateUpdatedAt,
    String? symbolPosition,
    bool clearRate = false,
  }) {
    return UsdDisplaySettings(
      enabled: enabled ?? this.enabled,
      symbol: symbol ?? this.symbol,
      rate: clearRate ? null : (rate ?? this.rate),
      rateUpdatedAt: rateUpdatedAt ?? this.rateUpdatedAt,
      symbolPosition: symbolPosition ?? this.symbolPosition,
    );
  }
}
