import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/dining_table.dart';
import '../../../data/models/table_status.dart';
import '../../../domain/models/ventas_table.dart' show VentasTable, TableStatusX;
import '../view/theme/table_status_style.dart';
import 'floor_map_geometry.dart';
import 'floor_seats.dart';

/// Floor map de una zona: dibuja cada mesa en su posición/forma reales,
/// con sus sillas alrededor (cantidad = capacidad) y una tarjeta con la
/// info de la mesa (código, estado, hora, mesero). El color sigue el
/// MISMO helper que el grid ([tableStatusColor]): verde disponible,
/// naranja ocupada, azul pre-cuenta.
///
/// Presentación pura: recibe la geometría ([tables]) y el estado en vivo
/// ([statusByTableId]) ya cargados por el viewmodel, y delega las
/// acciones (abrir mesa / unir mesas) a callbacks. Soporta zoom con
/// gestos (pinch/trackpad) y con los botones +/− de la esquina.
class ZoneFloorMap extends StatefulWidget {
  final List<DiningTable> tables;
  final Map<String, TableStatus> statusByTableId;
  final Set<String> openingTableIds;
  final bool enabled;

  final void Function(TableStatus ts)? onTapTable;
  final void Function(TableStatus ts)? onLongPressTable;

  /// Si se provee, muestra un botón de "expandir" (pantalla completa).
  final VoidCallback? onExpand;

  const ZoneFloorMap({
    super.key,
    required this.tables,
    required this.statusByTableId,
    this.openingTableIds = const {},
    this.enabled = true,
    this.onTapTable,
    this.onLongPressTable,
    this.onExpand,
  });

  @override
  State<ZoneFloorMap> createState() => _ZoneFloorMapState();
}

class _ZoneFloorMapState extends State<ZoneFloorMap> {
  final TransformationController _tc = TransformationController();
  Size _viewport = Size.zero;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  TableStatus _statusFor(DiningTable t) {
    return widget.statusByTableId[t.id] ??
        TableStatus(
          tableId: t.id,
          zoneId: t.zoneId,
          code: t.code,
          sessionId: null,
          ordersCount: 0,
          minutesOpen: null,
        );
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

  /// Tamaño del lienzo lógico. Por defecto el de diseño
  /// ([kFloorCanvasWidth] x [kFloorCanvasHeight]), pero CRECE para contener
  /// cualquier mesa cuyo nodo exceda ese lienzo — típicamente mesas sin
  /// posicionar que el auto-layout coloca en filas más allá de los 900px de
  /// alto. Así el plano nunca recorta mesas (antes quedaban fuera del
  /// `ClipRRect` y no se veían ni con zoom). En el caso común (todas las
  /// mesas posicionadas dentro del lienzo de diseño) devuelve el tamaño fijo
  /// y el render es idéntico al anterior.
  Size _canvasSize() {
    var maxX = kFloorCanvasWidth;
    var maxY = kFloorCanvasHeight;
    for (final entry in widget.tables.asMap().entries) {
      final node = floorNodeSize(entry.value);
      final pos = floorTablePosition(entry.value, entry.key);
      maxX = math.max(maxX, pos.dx + node.width);
      maxY = math.max(maxY, pos.dy + node.height);
    }
    const pad = 56.0; // aire para sombras/rotación en el borde
    return Size(
      maxX > kFloorCanvasWidth ? maxX + pad : kFloorCanvasWidth,
      maxY > kFloorCanvasHeight ? maxY + pad : kFloorCanvasHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tables.isEmpty) {
      return const Center(child: Text('No hay mesas en esta zona'));
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
            if (widget.onExpand != null)
              Positioned(
                right: 16,
                top: 16,
                child: Material(
                  elevation: 2,
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.white,
                  child: IconButton(
                    tooltip: 'Expandir',
                    onPressed: widget.onExpand,
                    icon: const Icon(
                      Icons.fullscreen,
                      color: AppColors.foreground,
                    ),
                  ),
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
    final ts = _statusFor(t);
    final vt = ventasTableFromStatus(ts);
    final palette = tableStatusPalette(vt.status);
    final color = palette.accent;
    final isOpening = widget.openingTableIds.contains(t.id);

    // Sillas "ocupadas" = comensales reales; el resto en gris. En mesas
    // libres todas quedan grises.
    final filled = vt.hasActiveSession
        ? (vt.guests ?? 0).clamp(0, t.capacity)
        : 0;

    return Positioned(
      left: pos.dx * scale,
      top: pos.dy * scale,
      width: geo.node.width * scale,
      height: geo.node.height * scale,
      child: Transform.rotate(
        angle: t.rotation * math.pi / 180,
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: (isOpening || !widget.enabled || widget.onTapTable == null)
                ? null
                : () => widget.onTapTable!(ts),
            onLongPress: (isOpening ||
                    !widget.enabled ||
                    widget.onLongPressTable == null ||
                    ts.sessionId == null)
                ? null
                : () => widget.onLongPressTable!(ts),
            child: Opacity(
              opacity: widget.enabled ? 1 : 0.6,
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
                      vt: vt,
                      palette: palette,
                      isOpening: isOpening,
                      isCircle: t.shape == TableShape.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Controles flotantes de zoom (+ / − / ajustar) sobre el plano.
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

/// La "mesa" propiamente: tarjeta tintada según el estado, con barra de
/// color a la izquierda y la info (código, estado, hora, mesero/cliente).
/// En mesas redondas se dibuja como círculo con la info centrada.
class _TableCard extends StatelessWidget {
  final DiningTable table;
  final VentasTable vt;
  final TableStatusPalette palette;
  final bool isOpening;
  final bool isCircle;

  const _TableCard({
    required this.table,
    required this.vt,
    required this.palette,
    required this.isOpening,
    required this.isCircle,
  });

  Color get color => palette.accent;

  String _money(BusinessCurrency currency, double v) =>
      '${currency.symbol} ${NumberFormat('#,##0', 'en_US').format(v)}';

  @override
  Widget build(BuildContext context) {
    final hasSession = vt.hasActiveSession;
    final waiter = vt.waiterName?.trim();
    final customer = vt.customerName?.trim();
    final time = vt.time;
    final total = vt.total;
    final statusLabel = vt.status.label;

    final decoration = BoxDecoration(
      // Fondo y borde tintados con el color del estado (misma paleta que
      // las cards del grid). El círculo carga el acento en su borde de 3px
      // porque no tiene barra lateral donde mostrarlo.
      color: palette.surface,
      shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: isCircle ? null : BorderRadius.circular(14),
      border: isCircle
          ? Border.all(color: color, width: 3)
          : Border.all(color: palette.border),
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
            if (isOpening)
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else ...[
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
                statusLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color, // el estado se lee en su propio color
                ),
              ),
              if (time != null)
                Text(
                  time,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
              if (hasSession && (customer?.isNotEmpty == true)) ...[
                const SizedBox(height: 4),
                Text(
                  customer!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
              ],
              if (hasSession) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.person_outline,
                      size: 13,
                      color: AppColors.mutedForeground,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      (waiter?.isNotEmpty == true) ? waiter! : 'Sin mesero',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
                if (total != null)
                  Consumer(
                    builder: (context, ref, _) {
                      final currency = currentBusinessCurrencyOrFallback(ref);
                      return Text(
                        _money(currency, total),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.foreground,
                        ),
                      );
                    },
                  ),
              ],
            ],
          ],
        ),
      ),
    );

    // Mesa rectangular: barra de color a la izquierda (como las cards).
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
