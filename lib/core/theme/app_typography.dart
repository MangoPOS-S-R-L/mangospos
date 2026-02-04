import 'package:flutter/material.dart';

/// MangoPos Design System - Typography System
class AppTypography {
  // ============================================================================
  // FONT FAMILY
  // ============================================================================

  static const String fontFamily = 'Plus Jakarta Sans';

  // ============================================================================
  // TEXT STYLES
  // ============================================================================

  /// Extra Small - 12sp (text-xs)
  static const TextStyle xs = TextStyle(fontSize: 12, fontFamily: fontFamily);

  /// Small - 14sp (text-sm)
  static const TextStyle sm = TextStyle(fontSize: 14, fontFamily: fontFamily);

  /// Base - 16sp (text-base)
  static const TextStyle base = TextStyle(fontSize: 16, fontFamily: fontFamily);

  /// Large - 18sp (text-lg)
  static const TextStyle lg = TextStyle(fontSize: 18, fontFamily: fontFamily);

  /// Extra Large - 20sp (text-xl)
  static const TextStyle xl = TextStyle(fontSize: 20, fontFamily: fontFamily);

  /// 2XL - 24sp (text-2xl)
  static const TextStyle xl2 = TextStyle(fontSize: 24, fontFamily: fontFamily);

  /// 3XL - 30sp (text-3xl)
  static const TextStyle xl3 = TextStyle(fontSize: 30, fontFamily: fontFamily);

  // ============================================================================
  // FONT WEIGHTS
  // ============================================================================

  static const FontWeight normal = FontWeight.w400;
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight semibold = FontWeight.w600;
  static const FontWeight bold = FontWeight.w700;
  static const FontWeight extrabold = FontWeight.w800;
}
