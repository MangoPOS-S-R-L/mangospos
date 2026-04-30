import 'package:flutter/widgets.dart';

import 'breakpoints.dart';

/// PRD 6 — Tokens de spacing y tipografía.
///
/// REGLAS:
/// - Mínimo absoluto **14 pt body**, no bajar a 12 ni en compact.
/// - Todo `Text` debe respetar `MediaQuery.textScalerOf(context)`.
///   Prohibido hardcodear `textScaleFactor: 1.0` para "estabilizar".
/// - Widgets con altura fija deben usar `IntrinsicHeight` o `minHeight`
///   en vez de `height: X` literal — para tolerar `textScaler` 1.3×.

class Insets {
  const Insets._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Padding compactado para breakpoint compact. Aplica factor 0.85 al
  /// inset y redondea para evitar half-pixels.
  ///
  /// ```dart
  /// padding: EdgeInsets.all(Insets.adaptive(context, Insets.md))
  /// ```
  static double adaptive(BuildContext c, double base) {
    return Breakpoints.isCompact(c) ? (base * 0.85).roundToDouble() : base;
  }

  static EdgeInsets allAdaptive(BuildContext c, double base) =>
      EdgeInsets.all(adaptive(c, base));

  static EdgeInsets symmetricAdaptive(
    BuildContext c, {
    double horizontal = 0,
    double vertical = 0,
  }) =>
      EdgeInsets.symmetric(
        horizontal: adaptive(c, horizontal),
        vertical: adaptive(c, vertical),
      );
}

class FontSizes {
  const FontSizes._();

  /// Mínimo absoluto. NO usar caption en flujos transaccionales (cobro,
  /// orden) — usar al menos `body`.
  static const double caption = 12;

  /// Body texto general. **Mínimo en pantallas críticas**.
  static const double body = 14;

  /// Subtítulos, labels destacados, valores en cards.
  static const double subtitle = 16;

  /// Botones primarios, headers de sección.
  static const double button = 16;

  /// Títulos de pantalla, headers de modal.
  static const double title = 20;

  /// Display: KPIs, totales destacados, número grande del cobro.
  static const double display = 28;

  /// Display XL: total final del modal de cobro, cierre de caja.
  static const double displayXl = 36;
}

/// Touch targets: PRD 6 § 4.5. Mínimo 44×44 px lógicos en cualquier elemento
/// tappable. Cuando el ícono visual es chico, el área activa se extiende vía
/// padding o `Container` envolvente.
class TouchTargets {
  const TouchTargets._();

  /// Mínimo absoluto (Material guidelines + Apple HIG).
  static const double minSize = 44;

  /// Tamaño "cómodo" para POS táctil donde el cajero opera rápido.
  static const double comfortable = 48;

  /// Tamaño para acciones primarias (Confirmar pago, Enviar a cocina).
  static const double primary = 56;
}
