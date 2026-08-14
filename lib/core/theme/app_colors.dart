import 'package:flutter/material.dart';

/// MangoPos Design System - Color Tokens (HSL Source of Truth)
/// All colors derived from HSL values for consistency
class AppColors {
  // ============================================================================
  // BACKGROUNDS
  // ============================================================================

  /// Background - #FBFCFE - Blanco azulado.
  ///
  /// Fuente única del fondo de pantalla de toda la app. `SalesTheme.background`,
  /// `MangoTokens.background`, `MangoColors.appBackground` y el
  /// `scaffoldBackgroundColor` del tema global apuntan aquí: si cambia el
  /// estilo, se cambia en este punto y no en 100 Scaffolds.
  static const Color background = Color(0xFFFBFCFE);

  /// Card - hsl(0, 0%, 100%) - Blanco puro
  static const Color card = Color(0xFFFFFFFF);

  /// Muted - hsl(30, 10%, 92%) - Gris cálido suave
  static const Color muted = Color(0xFFF0EBE7);

  /// Accent - hsl(30, 20%, 94%) - Acento neutral
  static const Color accent = Color(0xFFF7F3F0);

  /// Secondary - hsl(30, 15%, 95%) - Neutral suave para chips
  static const Color secondary = Color(0xFFF5F1EE);

  // ============================================================================
  // TEXTOS
  // ============================================================================

  /// Foreground - hsl(20, 14%, 12%) - Marrón oscuro
  static const Color foreground = Color(0xFF231F1D);

  /// Muted Foreground - hsl(20, 10%, 45%) - Gris cálido
  static const Color mutedForeground = Color(0xFF7D726D);

  // ============================================================================
  // BORDES
  // ============================================================================

  /// Border - hsl(30, 15%, 88%) - Borde suave
  static const Color border = Color(0xFFE0DBD9);

  // ============================================================================
  // BRANDING
  // ============================================================================

  /// Primary - hsl(25, 95%, 53%) - Naranja Mango
  static const Color primary = Color(0xFFF97316);

  /// Primary Gradient End - hsl(35, 95%, 55%) - Ámbar brillante (spec exacto)
  static const Color primaryGradientEnd = Color(0xFFFBAA16);

  // ============================================================================
  // ESTADOS
  // ============================================================================

  /// Success - hsl(142, 71%, 45%) - Verde
  static const Color success = Color(0xFF22C55E);

  /// Warning - hsl(38, 92%, 50%) - Ámbar
  static const Color warning = Color(0xFFF59E0B);

  /// Info - hsl(217, 91%, 60%) - Azul
  static const Color info = Color(0xFF3B82F6);

  /// Destructive - hsl(0, 84%, 60%) - Rojo
  static const Color destructive = Color(0xFFEF4444);

  /// Reserved - #8B5CF6 - Violeta (mesa reservada)
  static const Color reserved = Color(0xFF8B5CF6);

  // ============================================================================
  // SUPERFICIES POR ESTADO (fondo tintado de las cards de mesa)
  // ============================================================================
  // Tintes muy claros del color de estado. Se declaran como literales (y no
  // como `success.withOpacity(...)` sobre el fondo) para que el valor sea
  // exacto al del diseño y no dependa de sobre qué fondo se pinte la card.

  /// Fondo de card en estado Disponible - #F4FCF7
  static const Color successSurface = Color(0xFFF4FCF7);

  /// Fondo de card en estado Ocupado - #FFFBF4
  static const Color warningSurface = Color(0xFFFFFBF4);

  /// Fondo de card en estado Por Cobrar - #F6FAFF
  static const Color infoSurface = Color(0xFFF6FAFF);

  /// Fondo de card en estado Reservado - #FAF7FF
  static const Color reservedSurface = Color(0xFFFAF7FF);

  // ============================================================================
  // OPACIDADES DE ESTADO (para fondos)
  // ============================================================================

  static Color get successBg => success.withOpacity(0.1);
  static Color get warningBg => warning.withOpacity(0.1);
  static Color get infoBg => info.withOpacity(0.1);
  static Color get primaryBg => primary.withOpacity(0.1);

  // ============================================================================
  // OPACIDADES DE ESTADO (para bordes)
  // ============================================================================

  static Color get successBorder => success.withOpacity(0.2);
  static Color get warningBorder => warning.withOpacity(0.2);
  static Color get infoBorder => info.withOpacity(0.2);
  static Color get primaryBorder => primary.withOpacity(0.2);

  // ============================================================================
  // TABLE CARD SPECIFIC COLORS (DISENO_CARDS_MESAS.txt)
  // ============================================================================

  /// Divisor interno de la card (border con 40% opacidad)
  static Color get borderDivider => border.withOpacity(0.4);

  /// Divisor de la card de mesa - rgba(230,235,242,.4). Gris azulado que
  /// hace juego con el fondo #FBFCFE, en vez del gris cálido de [border].
  static const Color cardDivider = Color(0x66E6EBF2);

  /// Texto "Toca para asignar" (foreground con 60% opacidad)
  static Color get foregroundMuted => foreground.withOpacity(0.6);

  /// Fondo del badge "Tu mesa" (success con 10% opacidad)
  static Color get successBackground => success.withOpacity(0.1);
}
