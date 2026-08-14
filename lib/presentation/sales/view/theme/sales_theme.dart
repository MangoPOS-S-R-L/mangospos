import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/theme/app_colors.dart';

class SalesTheme {
  // 🎨 Paleta de Colores (segun especificaciones)
  static const Color primary = Color(0xFFF97316);
  static const Color primaryForeground = Colors.white;

  /// Fondo de pantalla: blanco azulado #FBFCFE (ver [AppColors.background]).
  static const Color background = AppColors.background;
  static const Color cardBackground = Color(0xFFFFFFFF);
  static const Color secondary = Color(0xFFF3F1EF);
  static const Color secondaryForeground = Color(0xFF231F1D);

  static const Color foreground = Color(0xFF231F1D);
  static const Color mutedForeground = Color(0xFF7D726D);

  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color info = Color(0xFF3B82F6);
  static const Color destructive = Color(0xFFEF4444);

  static const Color border = Color(0xFFE0DBD9);

  // 📏 Dimensiones clave
  static const double tableCardHeight = 140.0;
  static const double tableCardMinWidth = 240.0;
  static const double statusBorderWidth = 6.0;
  static const double cardBorderRadius = 12.0;
  static const double gridGap = 24.0;

  /// Separación del mosaico de mesas (diseño: gap 16 entre cards de 140).
  static const double tableGridGap = 16.0;
  static const EdgeInsets cardPadding = EdgeInsets.all(16.0);

  // 🧱 Sombras (sm / md)
  static BoxShadow get shadowSm => BoxShadow(
    color: Colors.black.withValues(alpha: 0.05),
    blurRadius: 3,
    offset: const Offset(0, 1),
  );

  static BoxShadow get shadowMd => BoxShadow(
    color: Colors.black.withValues(alpha: 0.08),
    blurRadius: 12,
    offset: const Offset(0, 4),
  );

  // Compatibilidad con usos existentes
  static BoxShadow get shadowCard => shadowSm;
  static BoxShadow get shadowElevated => BoxShadow(
    color: Colors.black.withValues(alpha: 0.15),
    blurRadius: 24,
    offset: const Offset(0, 8),
  );

  // 🔤 TextStyles
  static TextTheme get textTheme =>
      GoogleFonts.plusJakartaSansTextTheme().copyWith(
        displayLarge: GoogleFonts.plusJakartaSans(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: foreground,
        ),
        displayMedium: GoogleFonts.plusJakartaSans(
          fontSize: 28,
          fontWeight: FontWeight.w800,
          color: foreground,
        ),
        displaySmall: GoogleFonts.plusJakartaSans(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
        headlineMedium: GoogleFonts.plusJakartaSans(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
        titleLarge: GoogleFonts.plusJakartaSans(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
        titleMedium: GoogleFonts.plusJakartaSans(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
        bodyLarge: GoogleFonts.plusJakartaSans(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: foreground,
        ),
        bodyMedium: GoogleFonts.plusJakartaSans(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: foreground,
        ),
        bodySmall: GoogleFonts.plusJakartaSans(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: mutedForeground,
        ),
        labelLarge: GoogleFonts.plusJakartaSans(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
        labelSmall: GoogleFonts.plusJakartaSans(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: foreground,
        ),
      );

  // Utilidades
  static Color statusColor({required bool isOccupied, required bool isPaying}) {
    if (isPaying) return info;
    return isOccupied ? warning : success;
  }

  static String statusLabel({required bool isOccupied, required bool isPaying}) {
    if (isPaying) return 'Pagando';
    return isOccupied ? 'Ocupado' : 'Disponible';
  }
}
