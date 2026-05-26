// PRD 6 — Módulo USD Display-Only.
//
// Función pura para convertir un total DOP a su equivalente USD usando
// una tasa configurada manualmente desde Settings. Display-only: NO
// se usa para procesar pagos, NO afecta cuadre de caja, NO modifica
// reportes. Solo para mostrar al cliente "¿cuánto es eso en dólares?"
//
// Diseño: función pura sin side effects, testeable en aislamiento.
// El llamador es responsable de leer la tasa desde `business_settings`
// y de aplicar el flag `usd_display_enabled` antes de invocar.

import 'package:decimal/decimal.dart';

/// Calcula el equivalente USD de un total en DOP dado una tasa de
/// cambio (RD$ por 1 USD).
///
/// Retorna `null` (no `0`) cuando la conversión no es válida:
/// - `usdRate` es null
/// - `usdRate` ≤ 0
///
/// El caller debe renderizar la línea de USD solo si el resultado
/// NO es null. PRD §6.2 / §6.3 / §6.5.
///
/// Redondeo: aritmético estándar (HALF_UP) a 2 decimales. El paquete
/// `decimal` por defecto trunca, así que usamos `round(scale: 2)`
/// que aplica HALF_EVEN. Para HALF_UP usamos el método manual de
/// sumar 0.005 antes de truncar (ver `_roundHalfUp`).
///
/// Ejemplo:
/// ```dart
/// final usd = calculateUsdEquivalent(
///   dopTotal: Decimal.parse('5400.00'),
///   usdRate: Decimal.parse('60.50'),
/// );
/// // → Decimal.parse('89.26')
/// ```
Decimal? calculateUsdEquivalent({
  required Decimal dopTotal,
  required Decimal? usdRate,
}) {
  if (usdRate == null || usdRate <= Decimal.zero) return null;

  // Decimal.operator/ retorna Rational. Lo convertimos a Decimal
  // pidiendo precisión en caso de division periódica (ej: 1/3 = 0.333...).
  final raw =
      (dopTotal / usdRate).toDecimal(scaleOnInfinitePrecision: 10);

  return _roundHalfUp(raw, scale: 2);
}

/// Redondeo HALF_UP a `scale` decimales — versión manual porque el
/// paquete `decimal` solo expone HALF_EVEN (banker's rounding) en su
/// `round(scale)`. PRD §6.5 pide explícitamente HALF_UP.
///
/// Algoritmo: desplazamos el valor 10^scale, sumamos ±0.5 y truncamos
/// hacia cero (BigInt drops decimales). Después dividimos de vuelta.
Decimal _roundHalfUp(Decimal value, {required int scale}) {
  final shift = Decimal.fromBigInt(BigInt.from(10).pow(scale));
  final shifted = value * shift;
  final half = value >= Decimal.zero
      ? Decimal.parse('0.5')
      : Decimal.parse('-0.5');
  // BigInt truncation = floor para positivos, ceil para negativos —
  // combinado con la suma de ±0.5 da HALF_UP simétrico.
  final truncated = (shifted + half).toBigInt();
  return (Decimal.fromBigInt(truncated) / shift)
      .toDecimal(scaleOnInfinitePrecision: scale);
}
