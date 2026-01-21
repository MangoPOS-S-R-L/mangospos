import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SalesTheme {
  // 🎨 Paleta de Colores
  static const Color primary = Color(0xFFF97316);
  static const Color primaryForeground = Colors.white;

  static const Color background = Color(0xFFFAF9F8);
  static const Color cardBackground = Colors.white;
  static const Color secondary = Color(0xFFF3F1EF);
  static const Color secondaryForeground = Color(
    0xFF1C1917,
  ); // Asumido para contraste en secondary

  static const Color foreground = Color(0xFF1C1917);
  static const Color mutedForeground = Color(0xFF78716C);

  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color destructive = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);

  static const Color border = Color(0xFFE5E2DE);

  // 🧱 Sombras
  static BoxShadow get shadowCard => BoxShadow(
    color: Colors.black.withOpacity(0.05),
    blurRadius: 12,
    offset: const Offset(0, 4),
  );

  static BoxShadow get shadowElevated => BoxShadow(
    color: Colors.black.withOpacity(0.15),
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
          fontWeight: FontWeight.w400,
          color: mutedForeground,
        ),
        labelLarge: GoogleFonts.plusJakartaSans(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      );
}
