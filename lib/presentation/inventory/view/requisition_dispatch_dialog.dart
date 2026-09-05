// F2 — Despachar una requisición.
//
// Acá sí se mueve el stock. El almacén entrega lo que TIENE, que puede ser
// menos de lo pedido: el faltante queda registrado en la línea para poder
// reclamarlo, en vez de desaparecer.

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../services/inventory_scan.dart';
import '../state/inventory_state.dart';
import '../state/requisitions_state.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// Abre el diálogo de despacho. Devuelve `true` si se despachó.
Future<bool> showRequisitionDispatchDialog(
  BuildContext context, {
  required InventoryRepository repo,
  required Requisition requisition,
}) async {
  final hecho = await showDialog<bool>(
    context: context,
    builder: (_) => _RequisitionDispatchDialog(
      repo: repo,
      requisition: requisition,
    ),
  );
  return hecho == true;
}

class _RequisitionDispatchDialog extends StatefulWidget {
  final InventoryRepository repo;
  final Requisition requisition;

  const _RequisitionDispatchDialog({
    required this.repo,
    required this.requisition,
  });

  @override
  State<_RequisitionDispatchDialog> createState() =>
      _RequisitionDispatchDialogState();
}

class _RequisitionDispatchDialogState
    extends State<_RequisitionDispatchDialog> {
  bool _cargando = true;
  bool _guardando = false;
  String? _error;
  List<RequisitionLine> _lineas = const [];
  final Map<String, TextEditingController> _ctrl = {};
  final Map<String, double> _existencia = {};

  /// El catálogo con códigos de barras, sólo para resolver el escaneo: las
  /// líneas de la requisición no traen código.
  List<InventoryItemSummary> _catalogo = const [];
  final _notas = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _cargar());
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    _notas.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final req = widget.requisition;
      final lineas = await widget.repo.getRequisitionLines(req.id);
      // La existencia de la bodega que despacha: es el tope real de lo que
      // se puede entregar hoy.
      final items = await widget.repo.getItems(
        businessId: req.businessId,
        warehouseId: req.fromWarehouseId,
      );
      final porId = <String, InventoryItemSummary>{
        for (final i in items) i.id: i,
      };
      if (!mounted) return;
      setState(() {
        _catalogo = items;
        _lineas = lineas;
        for (final l in lineas) {
          _existencia[l.itemId] = porId[l.itemId]?.stock ?? 0;
          // Se propone entregar lo pedido, pero nunca más de lo que hay:
          // sugerir un número imposible sólo genera un error al guardar.
          final sugerido = _existencia[l.itemId]! < l.requestedQty
              ? _existencia[l.itemId]!
              : l.requestedQty;
          _ctrl[l.itemId] = TextEditingController(
            text: sugerido <= 0 ? '0' : _fmt(sugerido),
          );
        }
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  double _valor(String itemId) =>
      double.tryParse(
        (_ctrl[itemId]?.text ?? '').trim().replaceAll(',', '.'),
      ) ??
      0;

  bool get _hayFaltante =>
      _lineas.any((l) => _valor(l.itemId) < l.requestedQty);

  Future<void> _despachar() async {
    for (final l in _lineas) {
      final v = _valor(l.itemId);
      if (v < 0) {
        setState(() => _error = 'Hay una cantidad negativa.');
        return;
      }
      final hay = _existencia[l.itemId] ?? 0;
      if (v > hay) {
        setState(() => _error =
            'De ${l.itemName} hay ${_fmt(hay)} ${l.unit} y estás despachando '
            '${_fmt(v)}.');
        return;
      }
    }

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final req = await widget.repo.dispatchRequisition(
        requisitionId: widget.requisition.id,
        lines: [
          for (final l in _lineas)
            {'item_id': l.itemId, 'dispatched_qty': _valor(l.itemId)},
        ],
        notes: _notas.text.trim().isEmpty ? null : _notas.text.trim(),
      );
      if (!mounted) return;
      AppToast.success(
        context,
        req.status == RequisitionStatus.partial
            ? '${req.code} despachada parcial. El faltante queda registrado.'
            : '${req.code} despachada completa.',
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _guardando = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.requisition;
    return InventoryScanListener(
      enabled: !_guardando && !_cargando,
      items: _catalogo,
      onItem: _onScannedItem,
      child: AlertDialog(
      title: Text('Despachar ${req.code}'),
      content: SizedBox(
        width: 560,
        child: _cargando
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${req.fromWarehouseName}  →  ${req.toWarehouseName}',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                    if ((req.notes ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        req.notes!,
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    for (final l in _lineas) _fila(l),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _notas,
                      decoration: const InputDecoration(
                        labelText: 'Nota del despacho (opcional)',
                        isDense: true,
                      ),
                      maxLines: 2,
                    ),
                    if (_hayFaltante) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Vas a despachar menos de lo pedido. La requisición '
                        'queda como parcial y el faltante se registra.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.warning,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: AppColors.destructive,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _guardando || _cargando ? null : _despachar,
          child: _guardando
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Despachar'),
        ),
      ],
      ),
    );
  }

  /// Escanear suma UNA unidad a lo que se va a entregar de ese insumo,
  /// topeado por lo que hay en la bodega. Así el almacén carga el despacho
  /// pasando la pistola por cada cosa que saca del anaquel.
  ///
  /// Un insumo que no está en la requisición NO se agrega: la requisición es
  /// lo que pidieron, y entregar algo que nadie pidió es otra operación.
  void _onScannedItem(InventoryItemSummary item) {
    final linea = _lineas.where((l) => l.itemId == item.id);
    if (linea.isEmpty) {
      AppToast.warning(
        context,
        '${item.name} no está en esta requisición.',
      );
      return;
    }
    final hay = _existencia[item.id] ?? 0;
    final actual = _valor(item.id);
    if (actual + 1 > hay) {
      AppToast.warning(
        context,
        'De ${item.name} solo hay ${_fmt(hay)} ${linea.first.unit}.',
      );
      return;
    }
    setState(() => _ctrl[item.id]?.text = _fmt(actual + 1));
    AppToast.success(
      context,
      '${item.name}: ${_fmt(actual + 1)} ${linea.first.unit}',
    );
  }

  Widget _fila(RequisitionLine l) {
    final hay = _existencia[l.itemId] ?? 0;
    final alcanza = hay >= l.requestedQty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.itemName,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Pidió ${_fmt(l.requestedQty)} ${l.unit} · '
                  'hay ${_fmt(hay)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: alcanza
                        ? AppColors.mutedForeground
                        : AppColors.warning,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _ctrl[l.itemId],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Entregar',
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }
}
