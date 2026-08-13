import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import '../theme/app_breakpoints.dart';

/// Grid de ancho **mínimo**: el tamaño del elemento táctil es fijo y lo que
/// varía es cuántos caben.
///
/// Flutter no trae el equivalente de `repeat(auto-fill, minmax(X, 1fr))`. Su
/// `SliverGridDelegateWithMaxCrossAxisExtent` razona por extensión **máxima**,
/// que es exactamente lo que produce mosaicos por debajo del mínimo: con 240 y
/// 499 dp de ancho da 2 columnas de 244 dp, no 3 de 159. En la pantalla de
/// mesa, con los 192 dp que le quedaban al catálogo, daba UNA columna de 192 —
/// de ahí salían las categorías dibujadas como bloques, una por fila.
///
/// Aquí el conteo se calcula con división entera hacia abajo y el sobrante se
/// reparte entre las columnas: ningún mosaico baja nunca de su mínimo.
///
/// [columnsFor] y [tileFor] son públicos a propósito — los tests de aceptación
/// los usan directamente, sin montar un árbol de widgets.
class SliverGridDelegateWithMinCrossAxisExtent extends SliverGridDelegate {
  const SliverGridDelegateWithMinCrossAxisExtent({
    required this.minCrossAxisExtent,
    required this.mainAxisExtent,
    this.crossAxisSpacing = AppBreakpoints.gridGap,
    this.mainAxisSpacing = AppBreakpoints.gridGap,
  }) : assert(minCrossAxisExtent > 0);

  final double minCrossAxisExtent;
  final double mainAxisExtent;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  /// Cuántas columnas de al menos [minCrossAxisExtent] caben en [width].
  ///
  /// `n` mosaicos ocupan `n·min + (n−1)·spacing`, de donde
  /// `n = piso((width + spacing) / (min + spacing))`.
  int columnsFor(double width) {
    if (!width.isFinite || width <= 0) return 1;
    final unit = minCrossAxisExtent + crossAxisSpacing;
    return math.max(1, ((width + crossAxisSpacing) / unit).floor());
  }

  /// Ancho real del mosaico: el sobrante se reparte, nunca se recorta.
  double tileFor(double width) {
    final n = columnsFor(width);
    return (width - crossAxisSpacing * (n - 1)) / n;
  }

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final w = constraints.crossAxisExtent;
    final n = columnsFor(w);
    final tile = tileFor(w);
    return SliverGridRegularTileLayout(
      crossAxisCount: n,
      mainAxisStride: mainAxisExtent + mainAxisSpacing,
      crossAxisStride: tile + crossAxisSpacing,
      childMainAxisExtent: mainAxisExtent,
      childCrossAxisExtent: tile,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(SliverGridDelegateWithMinCrossAxisExtent old) =>
      old.minCrossAxisExtent != minCrossAxisExtent ||
      old.mainAxisExtent != mainAxisExtent ||
      old.crossAxisSpacing != crossAxisSpacing ||
      old.mainAxisSpacing != mainAxisSpacing;
}
