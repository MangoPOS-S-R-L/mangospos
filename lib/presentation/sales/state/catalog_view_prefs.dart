import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Cómo se dibuja el catálogo de productos del módulo de ventas.
///
/// El mosaico es cómodo para cartas cortas de restaurante, donde el cajero
/// reconoce el plato por posición. La lista gana cuando el catálogo es largo
/// (licorería, minimarket): entra el triple de productos por pantalla, el
/// nombre completo no se trunca y el stock queda legible en una columna
/// propia en vez de una pastilla de 20 dp.
enum CatalogViewMode { grid, list }

/// Modo de visualización del catálogo. Vive en memoria, no en preferencias:
/// es una decisión de momento (buscar algo puntual en la lista y volver al
/// mosaico), no una configuración del negocio.
final catalogViewModeProvider =
    NotifierProvider<CatalogViewModeNotifier, CatalogViewMode>(
      CatalogViewModeNotifier.new,
    );

class CatalogViewModeNotifier extends Notifier<CatalogViewMode> {
  @override
  CatalogViewMode build() => CatalogViewMode.grid;

  void toggle() => state = state == CatalogViewMode.grid
      ? CatalogViewMode.list
      : CatalogViewMode.grid;

  void set(CatalogViewMode mode) => state = mode;
}

/// Multiplicador de cantidad para el PRÓXIMO producto que se toque.
///
/// Sustituye la secuencia "tocar producto → abrir la línea → subir cantidad"
/// por "tocar 6X → tocar producto". En una barra con cola es la diferencia
/// entre un toque y varios.
///
/// **Se consume y vuelve a 1 después de cada producto agregado.** Es a
/// propósito: un multiplicador pegajoso que sobreviva al ítem siguiente cobra
/// de más sin que nadie lo note, y aquí un error de cantidad es dinero mal
/// cobrado. Si el negocio pide que se quede fijo, es cambiar [consume] por un
/// no-op y agregar un indicador permanente en la barra.
final quantityMultiplierProvider =
    NotifierProvider<QuantityMultiplier, int>(QuantityMultiplier.new);

class QuantityMultiplier extends Notifier<int> {
  /// Tope defensivo: un dedo torpe en el selector no debe poder cargar 999
  /// unidades de un plato.
  static const int max = 99;

  @override
  int build() => 1;

  void set(int value) {
    state = value.clamp(1, max);
  }

  void reset() => state = 1;

  /// Devuelve el multiplicador vigente y lo baja a 1. Llamar UNA vez por
  /// producto agregado, justo antes de construir la línea.
  int consume() {
    final current = state;
    if (current != 1) state = 1;
    return current;
  }

  bool get isActive => state != 1;
}
