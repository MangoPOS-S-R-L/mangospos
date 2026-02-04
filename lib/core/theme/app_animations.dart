import 'package:flutter/material.dart';

/// MangoPos Design System - Animation Definitions
class AppAnimations {
  // ============================================================================
  // DURATIONS
  // ============================================================================

  /// Fast animation - 150ms
  static const Duration fast = Duration(milliseconds: 150);

  /// Normal animation - 200ms
  static const Duration normal = Duration(milliseconds: 200);

  /// Slow animation - 300ms
  static const Duration slow = Duration(milliseconds: 300);

  // ============================================================================
  // CURVES
  // ============================================================================

  /// Ease out curve
  static const Curve easeOut = Curves.easeOut;

  /// Ease in out curve
  static const Curve easeInOut = Curves.easeInOut;

  // ============================================================================
  // HOVER EFFECTS (para web/desktop)
  // ============================================================================

  /// Hover lift offset - -2dp
  static const double hoverLiftOffset = -2.0;

  /// Hover scale factor - 1.05
  static const double hoverScale = 1.05;

  /// Hover opacity - 0.8
  static const double hoverOpacity = 0.8;
}
