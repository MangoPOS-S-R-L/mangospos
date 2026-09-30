// Ficha de un insumo en Salidas / Mermas y la pregunta de impresión que sale
// al registrar una salida.
//
// Pedido del dueño (2026-09-30): «cada item debe ser clickeable y cada uno
// debe poder imprimirse por separado, igual al momento de darle a guardar debe
// salir la opción de imprimir». Antes solo existía el A4 de TODAS las salidas
// del día y un ticket que salía solo al guardar (o no salía, sin impresora).

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../state/inventory_state.dart';
import '../../utils/outflow_note.dart';

/// Qué eligió la persona al guardar una salida.
enum OutflowPrintChoice { ticket, a4, none }

String _fmtQty(double v) {
  final s = v.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// «Salida registrada — ¿imprimir el conduce?» con ticket, hoja A4 o nada.
class OutflowSavedPrintDialog extends StatelessWidget {
  const OutflowSavedPrintDialog({
    super.key,
    required this.itemName,
    required this.quantity,
    required this.unit,
    required this.reasonLabel,
  });

  final String itemName;
  final double quantity;
  final String unit;
  final String reasonLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.check_circle, color: AppColors.success),
          const SizedBox(width: 10),
          const Text('Salida registrada'),
        ],
      ),
      content: Text(
        'Se descontaron ${_fmtQty(quantity)} $unit de $itemName '
        '($reasonLabel).\n\n¿Imprimir el conduce para firmar?',
      ),
      actions: [
        TextButton(
          key: const Key('outflow-print-none'),
          onPressed: () => Navigator.of(context).pop(OutflowPrintChoice.none),
          child: const Text('No imprimir'),
        ),
        OutlinedButton.icon(
          key: const Key('outflow-print-a4'),
          onPressed: () => Navigator.of(context).pop(OutflowPrintChoice.a4),
          icon: const Icon(Icons.description_outlined, size: 18),
          label: const Text('Hoja A4'),
        ),
        FilledButton.icon(
          key: const Key('outflow-print-ticket'),
          onPressed: () => Navigator.of(context).pop(OutflowPrintChoice.ticket),
          icon: const Icon(Icons.receipt_long_outlined, size: 18),
          label: const Text('Ticket'),
        ),
      ],
    );
  }
}

/// Ficha de UN insumo: sus salidas en la bodega, cada una imprimible sola
/// (ticket o A4), todas juntas en A4, o registrar una nueva.
///
/// Devuelve `true` si la persona tocó «Registrar salida».
class InventoryItemOutflowsDialog extends StatefulWidget {
  const InventoryItemOutflowsDialog({
    super.key,
    required this.item,
    required this.warehouseName,
    required this.canRegister,
    required this.load,
    required this.onPrintTicket,
    required this.onPrintA4,
  });

  final InventoryItemSummary item;
  final String warehouseName;
  final bool canRegister;

  /// Salidas del insumo de los últimos N días (1 = hoy).
  final Future<List<InventoryMovementEntry>> Function(int days) load;
  final Future<void> Function(InventoryMovementEntry movement) onPrintTicket;
  final Future<void> Function(List<InventoryMovementEntry> movements) onPrintA4;

  @override
  State<InventoryItemOutflowsDialog> createState() =>
      _InventoryItemOutflowsDialogState();
}

class _InventoryItemOutflowsDialogState
    extends State<InventoryItemOutflowsDialog> {
  static final _dateFormat = DateFormat('dd/MM/yyyy HH:mm');

  int _days = 30;
  bool _loading = true;
  String? _error;
  List<InventoryMovementEntry> _entries = const [];

  /// Generación de la carga: cambiar de período rápido no deja que una
  /// respuesta vieja pise la nueva.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.load(_days);
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = 'No se pudieron leer las salidas. Revisa la conexión.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final summary = [
      if (item.sku.isNotEmpty) item.sku,
      widget.warehouseName,
      'Existencia ${_fmtQty(item.stock)} ${item.unit}',
    ].join(' · ');

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.name),
          const SizedBox(height: 4),
          Text(
            summary,
            style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Salidas',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('Hoy')),
                    ButtonSegment(value: 7, label: Text('7 días')),
                    ButtonSegment(value: 30, label: Text('30 días')),
                  ],
                  selected: {_days},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) {
                    setState(() => _days = v.first);
                    _reload();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxHeight: 340),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: _list(item),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cerrar'),
        ),
        OutlinedButton.icon(
          key: const Key('item-outflows-print-all'),
          onPressed: _loading || _entries.isEmpty
              ? null
              : () => widget.onPrintA4(_entries),
          icon: const Icon(Icons.description_outlined, size: 18),
          label: const Text('Imprimir todas (A4)'),
        ),
        if (widget.canRegister)
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Registrar salida'),
          ),
      ],
    );
  }

  Widget _list(InventoryItemSummary item) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error, style: TextStyle(color: AppColors.destructive)),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            _days == 1
                ? 'Este insumo no tiene salidas hoy.'
                : 'Este insumo no tiene salidas en los últimos $_days días.',
            style: TextStyle(color: AppColors.mutedForeground),
          ),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final m = _entries[index];
        final note = splitOutflowNote(m.notes);
        return ListTile(
          key: ValueKey('item-outflow-${m.id}'),
          dense: true,
          title: Text(
            '−${_fmtQty(m.quantity.abs())} ${item.unit} · ${note.reason}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            [
              _dateFormat.format(m.createdAt),
              if (m.destination != null) 'Para ${m.destination}',
              if (note.detail.isNotEmpty) note.detail,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: ValueKey('item-outflow-ticket-${m.id}'),
                tooltip: 'Imprimir ticket',
                icon: const Icon(Icons.receipt_long_outlined, size: 20),
                onPressed: () => widget.onPrintTicket(m),
              ),
              IconButton(
                key: ValueKey('item-outflow-a4-${m.id}'),
                tooltip: 'Imprimir hoja A4',
                icon: const Icon(Icons.description_outlined, size: 20),
                onPressed: () => widget.onPrintA4([m]),
              ),
            ],
          ),
        );
      },
    );
  }
}
