import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class MangoTokens {
  const MangoTokens._();

  // Colors
  static const background = Color(0xFFFBFAF9);
  static const foreground = Color(0xFF231D1A);
  static const card = Color(0xFFFFFFFF);
  static const primary = Color(0xFFF97415);
  static const primaryForeground = Color(0xFFFFFFFF);
  static const secondary = Color(0xFFF4F2F0);
  static const secondaryForeground = Color(0xFF493D37);
  static const muted = Color(0xFFEDEBE9);
  static const mutedForeground = Color(0xFF7E6F67);
  static const accent = Color(0xFFF3F0ED);
  static const border = Color(0xFFE5E0DC);
  static const success = Color(0xFF21C45D);
  static const info = Color(0xFF3C83F6);
  static const warning = Color(0xFFF59F0A);
  static const destructive = Color(0xFFEF4343);

  // Radius
  static const radius = 12.0;
  static const radiusMd = 10.0;
  static const radiusSm = 8.0;

  // Shadows
  static const shadowSoft = [
    BoxShadow(
      color: Color(0x14231D1A),
      blurRadius: 8,
      offset: Offset(0, 2),
      spreadRadius: -2,
    ),
    BoxShadow(
      color: Color(0x1F231D1A),
      blurRadius: 16,
      offset: Offset(0, 4),
      spreadRadius: -4,
    ),
  ];

  static const shadowCard = [
    BoxShadow(color: Color(0x0D231D1A), blurRadius: 3, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x14231D1A), blurRadius: 12, offset: Offset(0, 4)),
  ];

  static TextStyle h1({Color color = foreground}) =>
      GoogleFonts.plusJakartaSans(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: color,
      );

  static TextStyle subtitle({Color color = mutedForeground}) =>
      GoogleFonts.plusJakartaSans(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: color,
      );

  static TextStyle body({Color color = foreground}) =>
      GoogleFonts.plusJakartaSans(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: color,
      );

  static TextStyle label({Color color = mutedForeground}) =>
      GoogleFonts.plusJakartaSans(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: color,
      );

  static TextStyle kpiValue({Color color = foreground}) =>
      GoogleFonts.plusJakartaSans(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: color,
      );
}
