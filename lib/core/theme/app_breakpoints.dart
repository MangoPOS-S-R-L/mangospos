import 'package:flutter/material.dart';

/// MangoPos Design System - Responsive Breakpoints
class AppBreakpoints {
  // ============================================================================
  // BREAKPOINT VALUES
  // ============================================================================

  /// Mobile breakpoint - 480dp.
  /// Por debajo de este ancho activamos el shell móvil (bottom nav + drawer).
  ///
  /// Era 600 (el "compact" de Material 3) y dejaba a la tablet de campo
  /// (1024×600 físicos = 600×1024 dp) justo en el borde: en vertical medía
  /// exactamente 600 dp, y `600 < 600` es falso, así que entraba por la rama
  /// tablet con el layout de tres paneles y el catálogo aplastado. La tablet
  /// de 7" hdpi (533 dp en vertical) sí cruzaba, y cambiaba de esqueleto al
  /// girar el equipo.
  ///
  /// Con 480 ninguna tablet del parque instalado entra por la rama móvil en
  /// ninguna orientación, así que girar ya no reconstruye la navegación.
  /// Cuántos paneles se dibujan es OTRA decisión, y se toma por el espacio
  /// que le queda al catálogo, no por el ancho total — ver
  /// [SalesSurfaceMetrics] en presentation/sales/layout/sales_surface.dart.
  static const double mobile = 480;

  /// Tablet breakpoint - 1024dp (lg - contentWideBreakpoint)
  static const double tablet = 1024;

  /// Desktop breakpoint - 1280dp (xl - twoColumnBreakpoint)
  static const double desktop = 1280;

  /// Ultrawide breakpoint - 1920dp
  static const double ultrawide = 1920;

  /// Max content width - 1440dp
  static const double maxContentWidth = 1440;

  // ==========================================================================
  // GEOMETRÍA DEL MÓDULO DE VENTAS  (DDT responsive · figura 1)
  //
  // Vive aquí para que ningún widget vuelva a declarar un ancho de riel, de
  // comanda o de mosaico por su cuenta: los tests de aceptación leen estas
  // mismas constantes que el layout.
  // ==========================================================================

  /// A partir de aquí el riel y la comanda usan su versión ancha.
  /// Es el único umbral que el DDT añade respecto al PRD.
  static const double fullChrome = 1200;

  /// Piso de ancho del catálogo para justificar tres paneles (PRD §5.2).
  static const double minCatalog = 400;

  // Geometría de regiones.
  static const double railCompact = 64;
  static const double railFull = 88;
  static const double cartCompact = 364;
  static const double cartFull = 420;

  // Mosaico (PRD §5.1).
  static const double minTile = 150;
  static const double gridGap = 11;

  /// Padding lateral del catálogo. Los dos valores NO son arbitrarios: hacen
  /// que el ancho de contenido sea 568 dp tanto en vertical (600 − 2×16) como
  /// en horizontal (596 − 2×14), y de ahí sale el mosaico de 182,0 dp en las
  /// dos orientaciones que pide el criterio de aceptación 1.
  static const double padTwo = 16;
  static const double padThree = 14;

  // Alturas de fila.
  static const double rowProduct = 104;
  static const double rowTable = 118;

  /// Versión pura de [ResponsiveHelper.isMobile]: se prueba sin `BuildContext`.
  static bool isMobile(double width) => width < mobile;
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
