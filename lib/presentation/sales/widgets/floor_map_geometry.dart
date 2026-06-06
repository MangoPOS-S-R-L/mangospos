import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../data/models/dining_table.dart';

/// Geometría compartida del floor map. El mapa runtime (ventas) y el
/// editor (ajustes) usan EXACTAMENTE las mismas reglas para que "lo que
/// diseñas es lo que ves".
///
/// Sistema de coordenadas: un canvas lógico fijo de
/// [kFloorCanvasWidth] x [kFloorCanvasHeight] unidades. `pos_x`/`pos_y`
/// (de `dining_tables`) son la esquina superior-izquierda del NODO (mesa
/// + sillas) en esas unidades. El tamaño de la mesa se deriva de su
/// CAPACIDAD (más comensales → mesa más grande/larga), escalado por los
/// multiplicadores `width`/`height` para ajuste fino. El render escala el
/// canvas al tamaño disponible con un factor `scale`.

/// Ancho del canvas lógico (unidades = px a escala 1.0).
const double kFloorCanvasWidth = 1400;

/// Alto del canvas lógico.
const double kFloorCanvasHeight = 900;

/// Espacio que ocupa una silla a lo largo de un lado de la mesa.
const double kFloorSeatPitch = 46;

/// Tamaño (lado) de una silla dibujada.
const double kFloorSeatSize = 30;

/// Separación entre la silla y el borde de la mesa.
const double kFloorSeatGap = 10;

/// Tamaño mínimo de la mesa (sin sillas).
const double kFloorTableMinW = 150;
const double kFloorTableMinH = 120;

/// Máximo de sillas por lado largo antes de desbordar a los lados.
const int kFloorMaxSeatsPerSide = 5;

/// Paso de la cuadrícula de "snap" del editor.
const double kFloorGridSnap = 20;

/// Distribución de sillas en los 4 lados de una mesa rectangular.
class FloorSeatLayout {
  final int top;
  final int bottom;
  final int left;
  final int right;
  const FloorSeatLayout(this.top, this.bottom, this.left, this.right);

  int get total => top + bottom + left + right;
}

/// Reparte [capacity] sillas: primero llena lados superior/inferior (lado
/// largo), y cuando se exceden los [kFloorMaxSeatsPerSide] por lado,
/// desborda a izquierda/derecha. Modela mesas tipo banquete (Q1 larga).
FloorSeatLayout floorSeatLayout(int capacity) {
  final cap = capacity.clamp(0, 40);
  if (cap <= 0) return const FloorSeatLayout(0, 0, 0, 0);

  if (cap <= kFloorMaxSeatsPerSide * 2) {
    final top = (cap / 2).ceil();
    return FloorSeatLayout(top, cap - top, 0, 0);
  }
  var remaining = cap - kFloorMaxSeatsPerSide * 2;
  final right = (remaining / 2).ceil();
  final left = remaining - right;
  return FloorSeatLayout(
    kFloorMaxSeatsPerSide,
    kFloorMaxSeatsPerSide,
    left,
    right,
  );
}

/// Tamaño de la MESA (sin sillas), derivado de la capacidad y escalado
/// por los multiplicadores `width`/`height`.
Size floorTableSize(DiningTable t) {
  final wMul = t.width <= 0 ? 1.0 : t.width;
  final hMul = t.height <= 0 ? 1.0 : t.height;

  if (t.shape == TableShape.circle) {
    final cap = t.capacity.clamp(1, 24);
    final d = (kFloorTableMinW + (cap - 2).clamp(0, 24) * 13.0)
        .clamp(kFloorTableMinW, 420.0);
    return Size(d * wMul, d * wMul);
  }

  final layout = floorSeatLayout(t.capacity);
  final perLong = math.max(layout.top, layout.bottom);
  final perSide = math.max(layout.left, layout.right);
  final w = math.max(kFloorTableMinW, perLong * kFloorSeatPitch) * wMul;
  final h = math.max(
        kFloorTableMinH,
        kFloorTableMinH + perSide * kFloorSeatPitch,
      ) *
      hMul;
  return Size(w, h);
}

/// Margen que reservan las sillas alrededor de la mesa.
double get _seatMargin => kFloorSeatGap + kFloorSeatSize;

/// Geometría completa de un nodo del plano: el rectángulo de la mesa y
/// las posiciones de cada silla, todo en coordenadas LÓGICAS locales al
/// nodo (sin escalar). Los renderizadores multiplican por `scale`.
class FloorNodeGeometry {
  final Size node;
  final Rect table;
  final List<Rect> seats;
  const FloorNodeGeometry({
    required this.node,
    required this.table,
    required this.seats,
  });
}

FloorNodeGeometry floorNodeGeometry(DiningTable t) {
  final tableSize = floorTableSize(t);
  final m = _seatMargin;
  final node = Size(tableSize.width + 2 * m, tableSize.height + 2 * m);
  final table = Rect.fromLTWH(m, m, tableSize.width, tableSize.height);
  final seats = <Rect>[];

  Rect seatAt(double cx, double cy) => Rect.fromCenter(
        center: Offset(cx, cy),
        width: kFloorSeatSize,
        height: kFloorSeatSize,
      );

  if (t.shape == TableShape.circle) {
    final cap = t.capacity.clamp(1, 24);
    final center = Offset(node.width / 2, node.height / 2);
    final radius = tableSize.width / 2 + kFloorSeatGap + kFloorSeatSize / 2;
    for (var i = 0; i < cap; i++) {
      final ang = -math.pi / 2 + 2 * math.pi * i / cap;
      seats.add(
        seatAt(
          center.dx + radius * math.cos(ang),
          center.dy + radius * math.sin(ang),
        ),
      );
    }
    return FloorNodeGeometry(node: node, table: table, seats: seats);
  }

  final layout = floorSeatLayout(t.capacity);
  final seatTopY = kFloorSeatSize / 2;
  final seatBottomY = node.height - kFloorSeatSize / 2;
  final seatLeftX = kFloorSeatSize / 2;
  final seatRightX = node.width - kFloorSeatSize / 2;

  void spread(int count, void Function(double frac) place) {
    for (var i = 0; i < count; i++) {
      place((i + 1) / (count + 1));
    }
  }

  spread(layout.top, (f) => seats.add(seatAt(m + table.width * f, seatTopY)));
  spread(layout.bottom,
      (f) => seats.add(seatAt(m + table.width * f, seatBottomY)));
  spread(layout.left,
      (f) => seats.add(seatAt(seatLeftX, m + table.height * f)));
  spread(layout.right,
      (f) => seats.add(seatAt(seatRightX, m + table.height * f)));

  return FloorNodeGeometry(node: node, table: table, seats: seats);
}

/// Tamaño total del nodo (mesa + sillas).
Size floorNodeSize(DiningTable t) => floorNodeGeometry(t).node;

/// True si la mesa nunca fue posicionada (legacy: pos_x=0, pos_y=0).
bool floorTableIsUnplaced(DiningTable t) => t.posX == 0 && t.posY == 0;

/// Posición (esquina superior-izquierda) del nodo en el canvas. Las mesas
/// sin posición (`pos_x=0, pos_y=0`) caen en una cuadrícula de fallback
/// por su `index` para no apilarse todas en la esquina.
Offset floorTablePosition(DiningTable t, int index) {
  if (!floorTableIsUnplaced(t)) {
    return Offset(t.posX, t.posY);
  }
  return floorAutoLayoutPosition(index);
}

/// Posición de cuadrícula automática para la mesa número [index].
Offset floorAutoLayoutPosition(int index) {
  const margin = 56.0;
  const step = 320.0; // separación generosa para mesa + sillas
  final usableWidth = kFloorCanvasWidth - margin * 2;
  final perRow = (usableWidth / step).floor().clamp(1, 100);
  final row = index ~/ perRow;
  final col = index % perRow;
  return Offset(margin + col * step, margin + row * step);
}

/// Redondea un valor al paso de cuadrícula del editor (snap-to-grid).
double floorSnap(double v) => (v / kFloorGridSnap).round() * kFloorGridSnap;

/// Limita una posición para que el nodo (de tamaño [size]) quede dentro
/// del canvas.
Offset floorClampPosition(Offset pos, Size size) {
  final maxX = (kFloorCanvasWidth - size.width).clamp(0.0, kFloorCanvasWidth);
  final maxY = (kFloorCanvasHeight - size.height).clamp(0.0, kFloorCanvasHeight);
  return Offset(pos.dx.clamp(0.0, maxX), pos.dy.clamp(0.0, maxY));
}
