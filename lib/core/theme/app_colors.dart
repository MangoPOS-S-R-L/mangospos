import 'package:flutter/material.dart';

/// MangoPos Design System - Color Tokens (HSL Source of Truth)
/// All colors derived from HSL values for consistency
class AppColors {
  // ============================================================================
  // BACKGROUNDS
  // ============================================================================

  /// Background - hsl(30, 20%, 98%) - Crema muy suave
  static const Color background = Color(0xFFFAF9F7);

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
  static const Color primary = Color(0xFFFB7116);

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

  /// Texto "Toca para asignar" (foreground con 60% opacidad)
  static Color get foregroundMuted => foreground.withOpacity(0.6);

  /// Fondo del badge "Tu mesa" (success con 10% opacidad)
  static Color get successBackground => success.withOpacity(0.1);
}
