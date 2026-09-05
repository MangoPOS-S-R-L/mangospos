import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/models/dining_table.dart';
import 'package:mangopos/presentation/sales/widgets/floor_map_geometry.dart';
import 'package:mangopos/presentation/sales/widgets/floor_seats.dart';
import '../viewmodel/zones_tables_viewmodel.dart';
import '../../../../../../core/theme/app_colors.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

/// Editor visual del plano (floor map) de una zona. Vive en Ajustes →
/// Zonas y mesas y permite arrastrar las mesas a su posición física y
/// editar su forma, asientos, tamaño y rotación. Comparte EXACTAMENTE el
/// sistema de coordenadas del mapa runtime ([floor_map_geometry.dart])
/// para que "lo que diseñas es lo que ves" en ventas.
///
/// Las posiciones nuevas se guardan en memoria mientras editas y se
/// persisten al tocar "Guardar diseño" (bulk update en `dining_tables`).
class ZoneFloorEditorView extends ConsumerStatefulWidget {
  final String zoneId;
  final String zoneName;

  const ZoneFloorEditorView({
    super.key,
    required this.zoneId,
    required this.zoneName,
  });

  @override
  ConsumerState<ZoneFloorEditorView> createState() =>
      _ZoneFloorEditorViewState();
}

class _ZoneFloorEditorViewState extends ConsumerState<ZoneFloorEditorView> {
  /// Copia de trabajo: mesas con sus ediciones locales no persistidas.
  late List<DiningTable> _working;
  bool _dirty = false;
  bool _snap = true;
  bool _saving = false;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    final tables =
        ref.read(zonesTablesVmProvider).tablesByZone[widget.zoneId] ??
            const <DiningTable>[];
    // Las mesas sin posición (legacy pos 0,0) reciben una posición de
    // cuadrícula para que no se apilen; se persiste al guardar.
    _working = [
      for (final entry in tables.asMap().entries)
        _placedCopy(entry.value, entry.key),
    ];
  }

  DiningTable _placedCopy(DiningTable t, int index) {
    if (!floorTableIsUnplaced(t)) return t;
    final pos = floorAutoLayoutPosition(index);
    return t.copyWith(posX: pos.dx, posY: pos.dy);
  }

  void _updateTable(DiningTable updated) {
    setState(() {
      final idx = _working.indexWhere((t) => t.id == updated.id);
      if (idx >= 0) _working[idx] = updated;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref
          .read(zonesTablesVmProvider.notifier)
          .saveLayout(widget.zoneId, _working);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _saving = false;
      });
      AppToast.success(context, 'Diseño guardado');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showAppSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('¿Descartar cambios?'),
        content: const Text('Tienes cambios sin guardar en el plano.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Seguir editando'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) {
          navigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          title: Text(
            'Plano · ${widget.zoneName}',
            style: const TextStyle(
              color: Colors.black87,
              fontWeight: FontWeight.bold,
            ),
          ),
          iconTheme: const IconThemeData(color: Colors.black87),
          actions: [
            Row(
              children: [
                const Text(
                  'Ajustar a cuadrícula',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
                Switch.adaptive(
                  value: _snap,
                  onChanged: (v) => setState(() => _snap = v),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: ElevatedButton.icon(
                onPressed: (_dirty && !_saving) ? _save : null,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: const Text('Guardar diseño'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: MangoColors.primaryOrange,
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
              ),
            ),
          ],
        ),
        body: _working.isEmpty
            ? const Center(
                child: Text(
                  'Esta zona no tiene mesas.\nAgrega mesas desde la lista primero.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: kFloorCanvasWidth / kFloorCanvasHeight,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final scale = constraints.maxWidth / kFloorCanvasWidth;
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _GridPainter(scale: scale),
                                  ),
                                ),
                                for (final entry in _working.asMap().entries)
                                  _buildEditorNode(entry.value, scale),
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
    );
  }

  Widget _buildEditorNode(DiningTable t, double scale) {
    final geo = floorNodeGeometry(t);
    final pos = Offset(t.posX, t.posY);
    final selected = t.id == _selectedId;
    final isCircle = t.shape == TableShape.circle;

    return Positioned(
      left: pos.dx * scale,
      top: pos.dy * scale,
      width: geo.node.width * scale,
      height: geo.node.height * scale,
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedId = t.id);
          _openTableSheet(t);
        },
        onPanStart: (_) => setState(() => _selectedId = t.id),
        onPanUpdate: (details) {
          final next = floorClampPosition(
            Offset(
              t.posX + details.delta.dx / scale,
              t.posY + details.delta.dy / scale,
            ),
            geo.node,
          );
          _updateTable(t.copyWith(posX: next.dx, posY: next.dy));
        },
        onPanEnd: (_) {
          if (!_snap) return;
          _updateTable(
            t.copyWith(posX: floorSnap(t.posX), posY: floorSnap(t.posY)),
          );
        },
        child: Transform.rotate(
          angle: t.rotation * math.pi / 180,
          child: Stack(
            children: [
              ...buildFloorSeats(
                geo,
                scale,
                (_) => selected
                    ? MangoColors.primaryOrange.withValues(alpha: 0.5)
                    : const Color(0xFFCBD5E1),
              ),
              Positioned(
                left: geo.table.left * scale,
                top: geo.table.top * scale,
                width: geo.table.width * scale,
                height: geo.table.height * scale,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: isCircle ? null : BorderRadius.circular(10),
                    border: Border.all(
                      color: selected
                          ? MangoColors.primaryOrange
                          : const Color(0xFFD1D5DB),
                      width: selected ? 3 : 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        t.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                      Text(
                        '${t.capacity} asientos',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Handle para redimensionar: jala la esquina inferior
              // derecha para cambiar ancho/largo independientes.
              if (selected)
                Positioned(
                  left: geo.table.right * scale - 12,
                  top: geo.table.bottom * scale - 12,
                  width: 24,
                  height: 24,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: GestureDetector(
                      onPanUpdate: (d) =>
                          _resizeFromHandle(t, d.delta, scale),
                      child: Container(
                        decoration: BoxDecoration(
                          color: MangoColors.primaryOrange,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Icon(
                          Icons.open_in_full,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Convierte el arrastre del handle en nuevos multiplicadores de tamaño
  /// (ancho/largo), acotados a 50%–300%. En mesas redondas mantiene el
  /// diámetro (ancho = largo).
  void _resizeFromHandle(DiningTable t, Offset delta, double scale) {
    final base = floorTableSize(t.copyWith(width: 1, height: 1));
    final cur = floorTableSize(t);
    final newW = ((cur.width + delta.dx / scale) / base.width).clamp(0.5, 3.0);
    final newH =
        ((cur.height + delta.dy / scale) / base.height).clamp(0.5, 3.0);
    final w = double.parse(newW.toStringAsFixed(2));
    final h = double.parse(newH.toStringAsFixed(2));
    if (t.shape == TableShape.circle) {
      _updateTable(t.copyWith(width: w, height: w));
    } else {
      _updateTable(t.copyWith(width: w, height: h));
    }
  }

  void _openTableSheet(DiningTable table) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _TableLayoutSheet(
        table: table,
        onChanged: _updateTable,
      ),
    );
  }
}

/// Bottom sheet para editar la forma, asientos, tamaño y rotación de una
/// mesa. Emite cambios en vivo vía [onChanged] (el editor los aplica a su
/// copia de trabajo).
class _TableLayoutSheet extends StatefulWidget {
  final DiningTable table;
  final void Function(DiningTable) onChanged;

  const _TableLayoutSheet({required this.table, required this.onChanged});

  @override
  State<_TableLayoutSheet> createState() => _TableLayoutSheetState();
}

class _TableLayoutSheetState extends State<_TableLayoutSheet> {
  late DiningTable _t;

  @override
  void initState() {
    super.initState();
    _t = widget.table;
  }

  void _emit(DiningTable next) {
    setState(() => _t = next);
    widget.onChanged(next);
  }

  /// Ajusta el ANCHO en pasos de 10% (50%–300%). En redondas mueve el
  /// diámetro (ancho = largo).
  void _resizeWidth(double delta) {
    final v = double.parse(
      (_t.width + delta).clamp(0.5, 3.0).toStringAsFixed(2),
    );
    if (_t.shape == TableShape.circle) {
      _emit(_t.copyWith(width: v, height: v));
    } else {
      _emit(_t.copyWith(width: v));
    }
  }

  /// Ajusta el LARGO en pasos de 10% (50%–300%).
  void _resizeHeight(double delta) {
    final v = double.parse(
      (_t.height + delta).clamp(0.5, 3.0).toStringAsFixed(2),
    );
    _emit(_t.copyWith(height: v));
  }

  Widget _dimStepper(
    String label,
    double value,
    VoidCallback onMinus,
    VoidCallback onPlus,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        IconButton.outlined(
          onPressed: value <= 0.5 ? null : onMinus,
          icon: const Icon(Icons.remove),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '${(value * 100).round()}%',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        IconButton.outlined(
          onPressed: value >= 3.0 ? null : onPlus,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Mesa ${_t.code}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),

          // Forma
          const Text('Forma', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<TableShape>(
            segments: const [
              ButtonSegment(
                value: TableShape.square,
                label: Text('Cuadrada'),
                icon: Icon(Icons.crop_square),
              ),
              ButtonSegment(
                value: TableShape.circle,
                label: Text('Redonda'),
                icon: Icon(Icons.circle_outlined),
              ),
            ],
            selected: {_t.shape},
            onSelectionChanged: (s) => _emit(_t.copyWith(shape: s.first)),
          ),
          const SizedBox(height: 20),

          // Asientos / capacidad
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Asientos',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton.outlined(
                onPressed: _t.capacity <= 1
                    ? null
                    : () => _emit(_t.copyWith(capacity: _t.capacity - 1)),
                icon: const Icon(Icons.remove),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '${_t.capacity}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton.outlined(
                onPressed: _t.capacity >= 50
                    ? null
                    : () => _emit(_t.copyWith(capacity: _t.capacity + 1)),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Tamaño manual en pasos de 10% (50%–300%). Ancho y largo
          // independientes — o también puedes jalar la esquina de la mesa.
          if (_t.shape == TableShape.circle)
            _dimStepper(
              'Diámetro',
              _t.width,
              () => _resizeWidth(-0.1),
              () => _resizeWidth(0.1),
            )
          else ...[
            _dimStepper(
              'Ancho',
              _t.width,
              () => _resizeWidth(-0.1),
              () => _resizeWidth(0.1),
            ),
            const SizedBox(height: 4),
            _dimStepper(
              'Largo',
              _t.height,
              () => _resizeHeight(-0.1),
              () => _resizeHeight(0.1),
            ),
          ],
          const SizedBox(height: 8),

          // Rotación
          const Text('Rotación', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final deg in const [0.0, 45.0, 90.0, 135.0])
                ChoiceChip(
                  label: Text('${deg.toStringAsFixed(0)}°'),
                  selected: _t.rotation == deg,
                  selectedColor:
                      MangoColors.primaryOrange.withValues(alpha: 0.2),
                  onSelected: (_) => _emit(_t.copyWith(rotation: deg)),
                ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Listo'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cuadrícula de fondo para guiar la colocación de las mesas.
class _GridPainter extends CustomPainter {
  final double scale;
  const _GridPainter({required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFEFF1F4)
      ..strokeWidth = 1;
    final step = kFloorGridSnap * scale;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.scale != scale;
}
