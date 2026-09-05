// F2 — Pedir mercancía a otra bodega.
//
// No mueve stock: crea el documento. La mercancía se mueve cuando el almacén
// despacha, y ahí puede entregar menos de lo pedido.

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../services/inventory_scan.dart';
import '../state/inventory_state.dart';
import 'widgets/item_search_field.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// Abre el formulario. Devuelve `true` si se creó la requisición.
Future<bool> showRequisitionFormDialog(
  BuildContext context, {
  required String businessId,
  required InventoryRepository repo,
  required List<InventoryWarehouseDetail> warehouses,
}) async {
  final creada = await showDialog<bool>(
    context: context,
    builder: (_) => _RequisitionFormDialog(
      businessId: businessId,
      repo: repo,
      warehouses: warehouses,
    ),
  );
  return creada == true;
}

class _LineaEnEdicion {
  String? itemId;
  final TextEditingController qty = TextEditingController();

  void dispose() => qty.dispose();
}

class _RequisitionFormDialog extends StatefulWidget {
  final String businessId;
  final InventoryRepository repo;
  final List<InventoryWarehouseDetail> warehouses;

  const _RequisitionFormDialog({
    required this.businessId,
    required this.repo,
    required this.warehouses,
  });

  @override
  State<_RequisitionFormDialog> createState() => _RequisitionFormDialogState();
}

class _RequisitionFormDialogState extends State<_RequisitionFormDialog> {
  String? _fromId;
  String? _toId;
  final _notas = TextEditingController();
  final List<_LineaEnEdicion> _lineas = [_LineaEnEdicion()];
  List<InventoryItemSummary> _items = const [];
  bool _cargandoItems = false;
  bool _guardando = false;
  String? _error;

  /// Bodegas reales: fuera la virtual de tránsito y las desactivadas.
  List<InventoryWarehouseDetail> get _usables => widget.warehouses
      .where((w) => !w.isInTransit && w.isActive)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    final usables = _usables;
    if (usables.isNotEmpty) {
      // El origen natural es la principal: es de donde sale la mercancía.
      final principal = usables.firstWhere(
        (w) => w.isMain,
        orElse: () => usables.first,
      );
      _fromId = principal.id;
      final destino = usables.where((w) => w.id != principal.id);
      if (destino.isNotEmpty) _toId = destino.first.id;
      _cargarItems();
    }
  }

  @override
  void dispose() {
    _notas.dispose();
    for (final l in _lineas) {
      l.dispose();
    }
    super.dispose();
  }

  /// Los insumos con la existencia de la bodega de ORIGEN: sirve para no
  /// pedir lo que ya se sabe que no hay.
  Future<void> _cargarItems() async {
    final from = _fromId;
    if (from == null) return;
    setState(() => _cargandoItems = true);
    try {
      final items = await widget.repo.getItems(
        businessId: widget.businessId,
        warehouseId: from,
      );
      if (!mounted) return;
      setState(() {
        _items = items.where((i) => i.isActive).toList(growable: false);
        _cargandoItems = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargandoItems = false;
        _error = FriendlyError.humanize('No se pudieron cargar los insumos: $e');
      });
    }
  }

  InventoryItemSummary? _item(String? id) {
    if (id == null) return null;
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  Future<void> _guardar() async {
    final from = _fromId;
    final to = _toId;
    if (from == null || to == null) {
      setState(() => _error = 'Elegí las dos bodegas.');
      return;
    }
    if (from == to) {
      setState(() => _error = 'La bodega de origen y la de destino no pueden '
          'ser la misma.');
      return;
    }

    final payload = <Map<String, dynamic>>[];
    final vistos = <String>{};
    for (final l in _lineas) {
      final id = l.itemId;
      if (id == null) continue;
      final qty = double.tryParse(l.qty.text.trim().replaceAll(',', '.'));
      if (qty == null || qty <= 0) {
        setState(() => _error = 'Hay una línea sin cantidad válida.');
        return;
      }
      if (!vistos.add(id)) {
        setState(() => _error = 'Hay un insumo repetido. Sumalo en una sola '
            'línea.');
        return;
      }
      payload.add({
        'item_id': id,
        'requested_qty': qty,
        'unit': _item(id)?.unit ?? 'unidad',
      });
    }
    if (payload.isEmpty) {
      setState(() => _error = 'Agregá al menos un insumo.');
      return;
    }

    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final req = await widget.repo.createRequisition(
        businessId: widget.businessId,
        fromWarehouseId: from,
        toWarehouseId: to,
        lines: payload,
        notes: _notas.text.trim().isEmpty ? null : _notas.text.trim(),
      );
      if (!mounted) return;
      AppToast.success(context, '${req.code} enviada al almacén.');
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
    final usables = _usables;
    return InventoryScanListener(
      enabled: !_guardando && !_cargandoItems,
      items: _items,
      onItem: _onScannedItem,
      child: AlertDialog(
      title: const Text('Pedir mercancía'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _fromId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Pedirle a *',
                        isDense: true,
                      ),
                      items: [
                        for (final w in usables)
                          DropdownMenuItem(
                            value: w.id,
                            child: Text(
                              w.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() {
                          _fromId = v;
                          _items = const [];
                        });
                        _cargarItems();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _toId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Para *',
                        isDense: true,
                      ),
                      items: [
                        for (final w in usables)
                          DropdownMenuItem(
                            value: w.id,
                            child: Text(
                              w.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _toId = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_cargandoItems)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              for (var i = 0; i < _lineas.length; i++) _fila(i),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _lineas.add(_LineaEnEdicion())),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Agregar insumo'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notas,
                decoration: const InputDecoration(
                  labelText: 'Nota para el almacén (opcional)',
                  isDense: true,
                ),
                maxLines: 2,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: AppColors.destructive, fontSize: 12),
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
          onPressed: _guardando ? null : _guardar,
          child: _guardando
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Enviar pedido'),
        ),
      ],
      ),
    );
  }

  /// Escanear suma UNA unidad. Si el insumo ya está en una línea, sube su
  /// cantidad en vez de crear una segunda: dos líneas del mismo insumo el
  /// RPC las rechaza, y de todos modos no significan nada.
  void _onScannedItem(InventoryItemSummary item) {
    setState(() {
      for (final l in _lineas) {
        if (l.itemId == item.id) {
          final actual =
              double.tryParse(l.qty.text.trim().replaceAll(',', '.')) ?? 0;
          l.qty.text = _fmt(actual + 1);
          _avisar(item, actual + 1);
          return;
        }
      }
      // Reusa la primera línea vacía antes de agregar una nueva: escanear
      // sobre el formulario recién abierto no debería dejar un renglón
      // huérfano arriba.
      final vacia = _lineas.where((l) => l.itemId == null);
      final destino = vacia.isNotEmpty ? vacia.first : _LineaEnEdicion();
      if (vacia.isEmpty) _lineas.add(destino);
      destino.itemId = item.id;
      destino.qty.text = '1';
      _avisar(item, 1);
    });
  }

  void _avisar(InventoryItemSummary item, double total) {
    AppToast.success(
      context,
      '${item.name}: ${_fmt(total)} ${item.unit}',
    );
  }

  Widget _fila(int i) {
    final linea = _lineas[i];
    final item = _item(linea.itemId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: ItemSearchField(
              items: _items,
              selectedItemId: linea.itemId,
              onSelected: (id) => setState(() => linea.itemId = id),
              width: null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: linea.qty,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Cantidad',
                isDense: true,
                // Lo que hay en la bodega de origen. No bloquea pedir de más
                // —el almacén decide qué despacha— pero evita el pedido a
                // ciegas.
                helperText: item == null
                    ? null
                    : 'Hay ${_fmt(item.stock)} ${item.unit}',
              ),
            ),
          ),
          IconButton(
            tooltip: 'Quitar',
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: AppColors.mutedForeground,
            ),
            onPressed: _lineas.length == 1
                ? null
                : () => setState(() {
                      _lineas.removeAt(i).dispose();
                    }),
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
