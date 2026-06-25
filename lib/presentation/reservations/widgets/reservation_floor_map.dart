import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/dining_table.dart';
import '../../../data/models/reservation.dart';
import '../../sales/widgets/floor_map_geometry.dart';
import '../../sales/widgets/floor_seats.dart';

/// Estado visual de una mesa en el plano de RESERVAS (no es el de ventas).
enum _TileState { free, reserved, occupied, blocked }

extension _TileStateX on _TileState {
  Color get color {
    switch (this) {
      case _TileState.free:
        return AppColors.success;
      case _TileState.reserved:
        return AppColors.primary;
      case _TileState.occupied:
        return AppColors.warning;
      case _TileState.blocked:
        return AppColors.mutedForeground;
    }
  }

  String get label {
    switch (this) {
      case _TileState.free:
        return 'Libre';
      case _TileState.reserved:
        return 'Reservada';
      case _TileState.occupied:
        return 'Ocupada';
      case _TileState.blocked:
        return 'Bloqueada';
    }
  }
}

/// Plano del salón orientado a RESERVAS: dibuja cada mesa en su posición/forma
/// reales (reutiliza la geometría del plano de ventas) y la colorea según
/// tenga o no una reserva activa para el día seleccionado. Tocar una mesa
/// delega en [onTapTable] (el caller abre la hoja de la mesa).
///
/// Presentación pura: recibe las mesas de la zona y el mapa de reservas activas
/// por mesa ya calculados por el viewmodel.
class ReservationFloorMap extends StatefulWidget {
  final List<DiningTable> tables;

  /// `tableId` → reservas ACTIVAS del día (ordenadas por hora). Vacío/ausente
  /// = mesa sin reservas.
  final Map<String, List<Reservation>> reservationsByTableId;

  final void Function(DiningTable table) onTapTable;

  const ReservationFloorMap({
    super.key,
    required this.tables,
    required this.reservationsByTableId,
    required this.onTapTable,
  });

  @override
  State<ReservationFloorMap> createState() => _ReservationFloorMapState();
}

class _ReservationFloorMapState extends State<ReservationFloorMap> {
  final TransformationController _tc = TransformationController();
  Size _viewport = Size.zero;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  _TileState _stateFor(DiningTable t, List<Reservation> res) {
    if (t.state == TableState.blocked) return _TileState.blocked;
    final hasSeated = res.any((r) => r.status == ReservationStatus.seated);
    if (t.state == TableState.occupied || hasSeated) return _TileState.occupied;
    if (res.isNotEmpty) return _TileState.reserved;
    return _TileState.free;
  }

  void _zoom(double factor) {
    final current = _tc.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(1.0, 4.0);
    if (target == current) return;
    final k = target / current;
    final c = Offset(_viewport.width / 2, _viewport.height / 2);
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    m.multiply(_tc.value);
    _tc.value = m;
  }

  void _resetZoom() => _tc.value = Matrix4.identity();

  Size _canvasSize() {
    var maxX = kFloorCanvasWidth;
    var maxY = kFloorCanvasHeight;
    for (final entry in widget.tables.asMap().entries) {
      final node = floorNodeSize(entry.value);
      final pos = floorTablePosition(entry.value, entry.key);
      maxX = math.max(maxX, pos.dx + node.width);
      maxY = math.max(maxY, pos.dy + node.height);
    }
    const pad = 56.0;
    return Size(
      maxX > kFloorCanvasWidth ? maxX + pad : kFloorCanvasWidth,
      maxY > kFloorCanvasHeight ? maxY + pad : kFloorCanvasHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tables.isEmpty) {
      return const Center(
        child: Text(
          'Esta zona no tiene mesas.',
          style: TextStyle(color: AppColors.mutedForeground),
        ),
      );
    }

    final canvas = _canvasSize();

    return LayoutBuilder(
      builder: (context, outer) {
        _viewport = Size(outer.maxWidth, outer.maxHeight);
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _tc,
                minScale: 0.5,
                maxScale: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: canvas.width / canvas.height,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final scale = constraints.maxWidth / canvas.width;
                          return Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F3F9),
                              borderRadius: BorderRadius.circular(16),
                              border:
                                  Border.all(color: const Color(0xFFE5E7EB)),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Stack(
                                children: [
                                  for (final entry
                                      in widget.tables.asMap().entries)
                                    _buildNode(entry.value, entry.key, scale),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: _ZoomControls(
                onZoomIn: () => _zoom(1.25),
                onZoomOut: () => _zoom(0.8),
                onReset: _resetZoom,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildNode(DiningTable t, int index, double scale) {
    final geo = floorNodeGeometry(t);
    final pos = floorTablePosition(t, index);
    final res = widget.reservationsByTableId[t.id] ?? const <Reservation>[];
    final tileState = _stateFor(t, res);
    final color = tileState.color;

    // Sillas "ocupadas" = comensales de la próxima reserva; resto en gris.
    final filled = res.isNotEmpty
        ? res.first.partySize.clamp(0, t.capacity)
        : 0;

    return Positioned(
      left: pos.dx * scale,
      top: pos.dy * scale,
      width: geo.node.width * scale,
      height: geo.node.height * scale,
      child: Transform.rotate(
        angle: t.rotation * math.pi / 180,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => widget.onTapTable(t),
            child: Stack(
              children: [
                ...buildFloorSeats(
                  geo,
                  scale,
                  (i) => i < filled ? color : const Color(0xFFD1D5DB),
                ),
                Positioned(
                  left: geo.table.left * scale,
                  top: geo.table.top * scale,
                  width: geo.table.width * scale,
                  height: geo.table.height * scale,
                  child: _TableCard(
                    table: t,
                    tileState: tileState,
                    color: color,
                    reservations: res,
                    isCircle: t.shape == TableShape.circle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  const _ZoomControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Acercar',
            onPressed: onZoomIn,
            icon: const Icon(Icons.add, color: AppColors.foreground),
          ),
          const Divider(height: 1),
          IconButton(
            tooltip: 'Alejar',
            onPressed: onZoomOut,
            icon: const Icon(Icons.remove, color: AppColors.foreground),
          ),
          const Divider(height: 1),
          IconButton(
            tooltip: 'Ajustar',
            onPressed: onReset,
            icon: const Icon(
              Icons.fit_screen_outlined,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

/// La "mesa": tarjeta blanca con barra de color (o círculo con borde) y la
/// info de reserva (código, estado, hora + cliente de la próxima reserva, +N).
class _TableCard extends StatelessWidget {
  final DiningTable table;
  final _TileState tileState;
  final Color color;
  final List<Reservation> reservations;
  final bool isCircle;

  const _TableCard({
    required this.table,
    required this.tileState,
    required this.color,
    required this.reservations,
    required this.isCircle,
  });

  static String _time12(DateTime local) {
    final h = local.hour;
    final m = local.minute.toString().padLeft(2, '0');
    final ampm = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:$m $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final next = reservations.isNotEmpty ? reservations.first : null;
    final extra = reservations.length > 1 ? reservations.length - 1 : 0;

    final decoration = BoxDecoration(
      color: AppColors.card,
      shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: isCircle ? null : BorderRadius.circular(14),
      border: isCircle ? Border.all(color: color, width: 3) : null,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );

    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: isCircle ? Alignment.center : Alignment.centerLeft,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment:
              isCircle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              table.code,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: isCircle ? TextAlign.center : TextAlign.start,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              tileState.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            if (next != null) ...[
              const SizedBox(height: 4),
              Text(
                _time12(next.reservedForLocal),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
              if (next.customerName.trim().isNotEmpty)
                Text(
                  next.customerName.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.groups_outlined,
                    size: 13,
                    color: AppColors.mutedForeground,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${next.partySize}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  if (extra > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      '+$extra más',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                ],
              ),
            ] else ...[
              const SizedBox(height: 2),
              Text(
                '${table.capacity}p',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (!isCircle) {
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: decoration,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 7, color: color),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Container(decoration: decoration, child: Center(child: content));
  }
}
