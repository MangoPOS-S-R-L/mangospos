import 'package:flutter/material.dart';

/// MangoPos Design System - Responsive Breakpoints
class AppBreakpoints {
  // ============================================================================
  // BREAKPOINT VALUES
  // ============================================================================

  /// Mobile breakpoint - 600dp (Material 3 "compact").
  /// Por debajo de este ancho activamos el shell móvil (bottom nav + drawer).
  static const double mobile = 600;

  /// Tablet breakpoint - 1024dp (lg - contentWideBreakpoint)
  static const double tablet = 1024;

  /// Desktop breakpoint - 1280dp (xl - twoColumnBreakpoint)
  static const double desktop = 1280;

  /// Ultrawide breakpoint - 1920dp
  static const double ultrawide = 1920;

  /// Max content width - 1440dp
  static const double maxContentWidth = 1440;
}

/// Device type enum for responsive layouts.
///
/// Estos valores se derivan del ANCHO actual de la pantalla (incluyendo
/// rotación), no del tamaño físico del dispositivo. Para clasificar el
/// hardware en sí (phone vs tablet 8" vs tablet 10"+) usa
/// [DeviceClass] / [ResponsiveHelper.getDeviceClass], que usa
/// `shortestSide` y no cambia al rotar.
enum DeviceType { mobile, tablet, desktop, ultrawide }

/// Clase física del dispositivo basada en `MediaQuery.shortestSide`
/// (Material Design standard). A diferencia de [DeviceType], esta
/// clasificación no cambia con la rotación — un iPad Mini sigue
/// siendo [smallTablet] en portrait y landscape.
///
///   - [phone]: shortestSide < 600 (todos los teléfonos).
///   - [smallTablet]: 600 ≤ shortestSide < 840 (iPad mini, tablets 7-8").
///   - [largeTablet]: shortestSide ≥ 840 (iPad Air/Pro, tablets 10"+).
enum DeviceClass { phone, smallTablet, largeTablet }

/// Helper class for responsive utilities
class ResponsiveHelper {
  /// Get device type based on screen width
  static DeviceType getDeviceType(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    if (width >= AppBreakpoints.ultrawide) return DeviceType.ultrawide;
    if (width >= AppBreakpoints.desktop) return DeviceType.desktop;
    if (width >= AppBreakpoints.tablet) return DeviceType.tablet;
    return DeviceType.mobile;
  }

  /// Check if screen is mobile
  static bool isMobile(BuildContext context) {
    return MediaQuery.of(context).size.width < AppBreakpoints.mobile;
  }

  /// Check if screen is tablet
  static bool isTablet(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= AppBreakpoints.mobile && width < AppBreakpoints.tablet;
  }

  /// Check if screen is desktop
  static bool isDesktop(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= AppBreakpoints.tablet && width < AppBreakpoints.desktop;
  }

  /// Monitor cuadrado / pantalla compacta (1024×768 típico). Aplica
  /// padding y tamaños más ajustados que en desktop grande pero sin
  /// caer en mobile (que cambia el shell entero a bottom-nav).
  ///
  /// Cubre el rango 1024-1279px: monitores 4:3 viejos, tablets en
  /// landscape pequeñas, ventanas reducidas en pantallas grandes.
  static bool isCompactDesktop(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= AppBreakpoints.tablet && width < AppBreakpoints.desktop;
  }

  /// Check if screen is desktop XL or larger
  static bool isDesktopXL(BuildContext context) {
    return MediaQuery.of(context).size.width >= AppBreakpoints.desktop;
  }

  /// Check if screen is ultrawide
  static bool isUltrawide(BuildContext context) {
    return MediaQuery.of(context).size.width >= AppBreakpoints.ultrawide;
  }

  /// Get number of columns for quick actions grid
  static int getQuickActionsColumns(BuildContext context) {
    return isDesktop(context) || isDesktopXL(context) ? 4 : 2;
  }

  /// Check if should use wide layout (horizontal)
  static bool useWideLayout(BuildContext context) {
    return MediaQuery.of(context).size.width >= AppBreakpoints.tablet;
  }

  /// Indica si el shell debe usar el layout móvil compacto
  /// (bottom nav + drawer) en lugar del topbar horizontal.
  static bool useCompactShell(BuildContext context) {
    return MediaQuery.of(context).size.width < AppBreakpoints.mobile;
  }

  // ============================================================================
  // CLASIFICACIÓN POR DISPOSITIVO FÍSICO (shortestSide)
  // ============================================================================
  //
  // Estos helpers identifican el TIPO DE DEVICE en sí — un iPad Mini sigue
  // siendo `smallTablet` ya esté en portrait o landscape, porque
  // `shortestSide` toma la dimensión menor y eso es invariante a la
  // rotación. Útiles para tomar decisiones de UX (densidad, tamaño de hit
  // targets, layout adaptativo) sin depender de cómo está girado.
  //
  // Breakpoints según Material Design 3:
  //   < 600   phone (cualquier teléfono)
  //   < 840   small tablet (7-8" — iPad mini, Galaxy Tab A8, etc.)
  //   ≥ 840   large tablet (10"+ — iPad Air, iPad Pro 11/12, etc.)

  /// Clasifica el device por `shortestSide`. No cambia con rotación.
  static DeviceClass getDeviceClass(BuildContext context) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    if (shortest < AppBreakpoints.mobile) return DeviceClass.phone;
    if (shortest < 840) return DeviceClass.smallTablet;
    return DeviceClass.largeTablet;
  }

  /// `true` si el dispositivo es un teléfono (cualquier orientación).
  static bool isPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide < AppBreakpoints.mobile;

  /// `true` si es una tablet de 7-8" (cualquier orientación).
  static bool isSmallTablet(BuildContext context) {
    final s = MediaQuery.sizeOf(context).shortestSide;
    return s >= AppBreakpoints.mobile && s < 840;
  }

  /// `true` si es una tablet de 10"+ (cualquier orientación).
  static bool isLargeTablet(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide >= 840;
}
