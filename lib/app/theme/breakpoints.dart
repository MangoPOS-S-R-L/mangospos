import 'package:flutter/widgets.dart';

/// PRD 6 — Sistema de breakpoints responsive.
///
/// REGLA ABSOLUTA: usar siempre `MediaQuery.sizeOf(context)`. Está prohibido
/// `MediaQuery.physicalSize`, `window.physicalSize` o `view.physicalSize`
/// para decisiones de layout — anulan el DPI scaling de Windows.
///
/// Cascadeo natural con Windows display scaling (100/125/150 %):
/// el SO multiplica el factor antes de entregar el viewport, por lo que
/// `sizeOf().width` ya devuelve píxeles lógicos.
///
/// | Monitor físico | Win scaling | Logical | Breakpoint |
/// |---|---|---|---|
/// | 1366 × 768  | 100 % | 1366 | Regular |
/// | 1366 × 768  | 125 % | 1093 | Compact |
/// | 1920 × 1080 | 100 % | 1920 | Wide    |
/// | 1920 × 1080 | 125 % | 1536 | Regular |
/// | 1920 × 1080 | 150 % | 1280 | Compact |
/// | 2560 × 1440 | 100 % | 2560 | Wide    |
class Breakpoints {
  const Breakpoints._();

  /// Threshold compact → regular. Hardware POS típico (1366×768@100 %)
  /// cae justo en regular; cualquier scaling >100 % lo baja a compact.
  static const double compact = 1366;

  /// Threshold regular → wide. 1920×1080@100 % es wide; cualquier scaling
  /// lo baja a regular o compact.
  static const double regular = 1920;

  static double widthOf(BuildContext c) => MediaQuery.sizeOf(c).width;

  static bool isCompact(BuildContext c) => widthOf(c) < compact;

  static bool isRegular(BuildContext c) {
    final w = widthOf(c);
    return w >= compact && w < regular;
  }

  static bool isWide(BuildContext c) => widthOf(c) >= regular;

  /// Retorna el bucket actual como enum. Útil para `switch` en builders.
  static Breakpoint of(BuildContext c) {
    final w = widthOf(c);
    if (w < compact) return Breakpoint.compact;
    if (w < regular) return Breakpoint.regular;
    return Breakpoint.wide;
  }

  /// Selector tipado: retorna el valor que corresponde al breakpoint actual.
  /// Permite escribir layout conditional sin if/else encadenados.
  ///
  /// ```dart
  /// final cols = Breakpoints.select(context, compact: 3, regular: 4, wide: 5);
  /// ```
  static T select<T>(
    BuildContext c, {
    required T compact,
    required T regular,
    required T wide,
  }) {
    switch (of(c)) {
      case Breakpoint.compact:
        return compact;
      case Breakpoint.regular:
        return regular;
      case Breakpoint.wide:
        return wide;
    }
  }
}

enum Breakpoint { compact, regular, wide }
