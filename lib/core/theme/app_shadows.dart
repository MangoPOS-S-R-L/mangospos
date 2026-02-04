import 'package:flutter/material.dart';
import 'app_colors.dart';

/// MangoPos Design System - Shadow Definitions
class AppShadows {
  // ============================================================================
  // CARD SHADOWS
  // ============================================================================

  /// Card Elevada - Usada en la mayoría de cards
  static const List<BoxShadow> cardElevated = [
    BoxShadow(
      color: Color(0x0D000000), // rgba(0, 0, 0, 0.05)
      offset: Offset(0, 1),
      blurRadius: 3,
    ),
    BoxShadow(
      color: Color(0x14000000), // rgba(0, 0, 0, 0.08)
      offset: Offset(0, 4),
      blurRadius: 12,
    ),
  ];

  /// Card Interactiva - Hover state
  static const List<BoxShadow> cardInteractive = [
    BoxShadow(
      color: Color(0x12000000), // rgba(0, 0, 0, 0.07)
      offset: Offset(0, 4),
      blurRadius: 6,
    ),
    BoxShadow(
      color: Color(0x1A000000), // rgba(0, 0, 0, 0.1)
      offset: Offset(0, 8),
      blurRadius: 16,
    ),
  ];

  // ============================================================================
  // UTILITY SHADOWS
  // ============================================================================

  /// Sombra Suave - Para tooltips y dropdowns
  static const List<BoxShadow> soft = [
    BoxShadow(
      color: Color(0x14000000), // rgba(0, 0, 0, 0.08)
      offset: Offset(0, 2),
      blurRadius: 8,
      spreadRadius: -2,
    ),
  ];

  // ============================================================================
  // MANGO SHADOWS - Para botones primarios
  // ============================================================================

  static List<BoxShadow> get mango => [
    BoxShadow(
      color: AppColors.primary.withOpacity(0.3),
      offset: const Offset(0, 4),
      blurRadius: 8,
    ),
  ];

  static List<BoxShadow> get mangoHover => [
    BoxShadow(
      color: AppColors.primary.withOpacity(0.4),
      offset: const Offset(0, 6),
      blurRadius: 12,
    ),
  ];
}
