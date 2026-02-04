import 'package:flutter/material.dart';
import 'app_colors.dart';

/// MangoPos Design System - Gradient Definitions
class AppGradients {
  // ============================================================================
  // MANGO GRADIENT - Usado en botones primarios
  // ============================================================================

  static const LinearGradient mango = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.primary, AppColors.primaryGradientEnd],
  );

  // ============================================================================
  // CHART FILL GRADIENT - Para área bajo la curva
  // ============================================================================

  static LinearGradient get chartFill => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      AppColors.primary.withOpacity(0.15),
      AppColors.primary.withOpacity(0.01),
    ],
  );
}
