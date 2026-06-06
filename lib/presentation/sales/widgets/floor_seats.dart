import 'package:flutter/material.dart';

import 'floor_map_geometry.dart';

/// Dibuja las sillas de un nodo del plano como `Positioned` dentro de un
/// `Stack` que mide `geo.node * scale`. Compartido por el mapa runtime y
/// el editor para que las sillas se vean igual en ambos.
///
/// [colorOf] recibe el índice de la silla y devuelve su color (p. ej.
/// ocupadas en el color del estado, libres en gris).
List<Widget> buildFloorSeats(
  FloorNodeGeometry geo,
  double scale,
  Color Function(int index) colorOf,
) {
  final widgets = <Widget>[];
  for (var i = 0; i < geo.seats.length; i++) {
    final r = geo.seats[i];
    widgets.add(
      Positioned(
        left: r.left * scale,
        top: r.top * scale,
        width: r.width * scale,
        height: r.height * scale,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorOf(i),
            borderRadius: BorderRadius.circular(kFloorSeatSize * scale * 0.35),
          ),
        ),
      ),
    );
  }
  return widgets;
}
