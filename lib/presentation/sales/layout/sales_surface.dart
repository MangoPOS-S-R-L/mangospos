import 'package:flutter/widgets.dart';

import '../../../core/theme/app_breakpoints.dart';

/// Cuántas superficies simultáneas dibuja el módulo de ventas.
enum SalesSurfaceMode { twoSurface, threePanel }

/// Geometría resuelta del módulo de ventas para un ancho dado.
///
/// La decisión se toma sobre el ancho **restante** del catálogo, no sobre el
/// ancho total de la pantalla. Es justamente lo que fallaba: 600 dp pasaba el
/// umbral de tablet y dejaba 192 dp de catálogo.
///
/// [resolve] es una función pura del ancho: se prueba sin `WidgetTester`.
@immutable
class SalesSurfaceMetrics {
  const SalesSurfaceMetrics._({
    required this.mode,
    required this.railWidth,
    required this.cartWidth,
    required this.catalogWidth,
  });

  final SalesSurfaceMode mode;

  /// 0 en dos superficies: el riel se colapsa en «Más opciones».
  final double railWidth;

  /// 0 en dos superficies: la comanda pasa a hoja inferior.
  final double cartWidth;

  final double catalogWidth;

  bool get isThreePanel => mode == SalesSurfaceMode.threePanel;

  /// Padding lateral del contenido del catálogo. Los dos valores están
  /// elegidos para que el ancho útil coincida en las dos orientaciones del
  /// equipo de referencia (568 dp), que es el criterio de aceptación 1.
  double get catalogPadding =>
      isThreePanel ? AppBreakpoints.padThree : AppBreakpoints.padTwo;

  /// Ancho realmente disponible para los mosaicos.
  double get catalogContentWidth => catalogWidth - 2 * catalogPadding;

  factory SalesSurfaceMetrics.resolve(double width) {
    final wide = width >= AppBreakpoints.fullChrome;
    final rail = wide ? AppBreakpoints.railFull : AppBreakpoints.railCompact;
    final cart = wide ? AppBreakpoints.cartFull : AppBreakpoints.cartCompact;
    final catalog = width - rail - cart;

    if (catalog >= AppBreakpoints.minCatalog) {
      return SalesSurfaceMetrics._(
        mode: SalesSurfaceMode.threePanel,
        railWidth: rail,
        cartWidth: cart,
        catalogWidth: catalog,
      );
    }

    // La comanda pasa a hoja inferior y el riel a «Más opciones».
    return SalesSurfaceMetrics._(
      mode: SalesSurfaceMode.twoSurface,
      railWidth: 0,
      cartWidth: 0,
      catalogWidth: width,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SalesSurfaceMetrics &&
      other.mode == mode &&
      other.railWidth == railWidth &&
      other.cartWidth == cartWidth &&
      other.catalogWidth == catalogWidth;

  @override
  int get hashCode => Object.hash(mode, railWidth, cartWidth, catalogWidth);
}

/// Expone la geometría resuelta a todo el subárbol.
///
/// Un solo punto de verdad: evita que dos regiones lleguen a conclusiones
/// distintas sobre el mismo ancho, que es lo que pasaba cuando cada vista
/// tenía su propio `LayoutBuilder` con su propio umbral.
class SalesSurfaceScope extends InheritedWidget {
  const SalesSurfaceScope({
    super.key,
    required this.metrics,
    required super.child,
  });

  final SalesSurfaceMetrics metrics;

  static SalesSurfaceMetrics of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<SalesSurfaceScope>();
    assert(scope != null, 'No hay SalesSurfaceScope sobre este widget.');
    return scope!.metrics;
  }

  /// Igual que [of] pero sin reventar donde el scope no está montado todavía
  /// (venta rápida y manual siguen sin él).
  static SalesSurfaceMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SalesSurfaceScope>()?.metrics;

  @override
  bool updateShouldNotify(SalesSurfaceScope old) => old.metrics != metrics;
}
