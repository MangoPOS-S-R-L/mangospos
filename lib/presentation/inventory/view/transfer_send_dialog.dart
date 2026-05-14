import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../viewmodel/transfers_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';

class TransferSendDialog extends ConsumerStatefulWidget {
  const TransferSendDialog({super.key});

  @override
  ConsumerState<TransferSendDialog> createState() => _TransferSendDialogState();
}

class _TransferSendDialogState extends ConsumerState<TransferSendDialog> {
  String? _fromWarehouseId;
  String? _toWarehouseId;
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  /// itemId → cantidad a transferir (sólo si > 0).
  final Map<String, double> _quantities = {};

  bool _loadingItems = false;
  bool _submitting = false;
  String? _errorMessage;
  List<InventoryItemSummary> _sourceItems = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(inventoryViewModelProvider).init();
      // Pre-seleccionar la primera bodega como origen y la siguiente como destino.
      final inv = ref.read(inventoryViewModelProvider).state;
      final realWarehouses = inv.warehouses; // ya no incluye IN_TRANSIT
      if (realWarehouses.length >= 2) {
        setState(() {
          _fromWarehouseId = realWarehouses.first.id;
          _toWarehouseId = realWarehouses[1].id;
        });
        await _loadSourceItems();
      } else if (realWarehouses.length == 1) {
        setState(() {
          _fromWarehouseId = realWarehouses.first.id;
        });
        await _loadSourceItems();
      }
    });
  }

  @override
  void dispose() {
    _notesController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSourceItems() async {
    if (_fromWarehouseId == null) return;
    setState(() => _loadingItems = true);
    try {
      // Cambiamos el warehouse seleccionado del VM para obtener su stock.
      final vm = ref.read(inventoryViewModelProvider);
      await vm.selectWarehouse(_fromWarehouseId);
      _sourceItems = vm.state.items;
    } finally {
      if (mounted) setState(() => _loadingItems = false);
    }
  }

  List<InventoryItemSummary> get _filteredItems {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _sourceItems;
    return _sourceItems
        .where(
          (i) =>
              i.name.toLowerCase().contains(q) ||
              i.sku.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  bool get _hasSelection =>
      _quantities.values.any((q) => q > 0) &&
      _fromWarehouseId != null &&
      _toWarehouseId != null &&
      _fromWarehouseId != _toWarehouseId;

  Future<void> _submit() async {
    if (!_hasSelection) {
      setState(() => _errorMessage = 'Selecciona al menos un ítem con cantidad');
      return;
    }
    final items = _sourceItems
        .where((i) => (_quantities[i.id] ?? 0) > 0)
        .map(
          (i) => <String, dynamic>{
            'item_id': i.id,
            'quantity': _quantities[i.id],
            'cost_per_unit': i.cost > 0 ? i.cost : null,
          },
        )
        .toList(growable: false);

    // Validar que ninguna cantidad supere el stock disponible.
    for (final i in _sourceItems) {
      final qty = _quantities[i.id] ?? 0;
      if (qty > i.stock) {
        setState(
          () => _errorMessage =
              '${i.name}: cantidad (${qty.toStringAsFixed(2)}) supera el stock (${i.stock.toStringAsFixed(2)})',
        );
        return;
      }
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(transfersViewModelProvider).createTransfer(
            fromWarehouseId: _fromWarehouseId!,
            toWarehouseId: _toWarehouseId!,
            items: items,
            notes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
          );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Transferencia enviada')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = _humanizeError(e.toString());
      });
    }
  }

  String _humanizeError(String raw) {
    if (raw.contains('INSUFFICIENT_ROLE')) {
      return 'No tienes permisos para enviar transferencias';
    }
    if (raw.contains('SAME_WAREHOUSE')) {
      return 'Origen y destino deben ser bodegas distintas';
    }
    if (raw.contains('EMPTY_ITEMS')) return 'Sin ítems seleccionados';
    if (raw.contains('FROM_WAREHOUSE_NOT_FOUND')) {
      return 'Bodega origen inválida';
    }
    if (raw.contains('TO_WAREHOUSE_NOT_FOUND')) {
      return 'Bodega destino inválida';
    }
    return 'Error: $raw';
  }

  @override
  Widget build(BuildContext context) {
    final inv = ref.watch(inventoryViewModelProvider).state;
    final warehouses = inv.warehouses;
    final selectedCount = _quantities.values.where((q) => q > 0).length;

    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: const Text('Nueva transferencia'),
      content: SizedBox(
        width: 560,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _fromWarehouseId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Bodega origen',
                      border: OutlineInputBorder(),
                    ),
                    items: warehouses
                        .map(
                          (w) => DropdownMenuItem(
                            value: w.id,
                            child: Text(w.name),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) async {
                      setState(() {
                        _fromWarehouseId = v;
                        _quantities.clear();
                      });
                      await _loadSourceItems();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    color: AppColors.mutedForeground,
                  ),
                ),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _toWarehouseId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Bodega destino',
                      border: OutlineInputBorder(),
                    ),
                    items: warehouses
                        .where((w) => w.id != _fromWarehouseId)
                        .map(
                          (w) => DropdownMenuItem(
                            value: w.id,
                            child: Text(w.name),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) => setState(() => _toWarehouseId = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: 'Buscar insumo...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _loadingItems
                  ? Center(
                      child: CircularProgressIndicator(color: AppColors.primary),
                    )
                  : _fromWarehouseId == null
                      ? Center(
                          child: Text(
                            'Selecciona una bodega origen para ver sus insumos.',
                            style: TextStyle(color: AppColors.mutedForeground),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _filteredItems.length,
                          itemBuilder: (context, index) {
                            final item = _filteredItems[index];
                            final qty = _quantities[item.id] ?? 0;
                            return _ItemRow(
                              item: item,
                              quantity: qty,
                              onChange: (v) {
                                setState(() {
                                  if (v <= 0) {
                                    _quantities.remove(item.id);
                                  } else {
                                    _quantities[item.id] = v;
                                  }
                                });
                              },
                            );
                          },
                        ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _notesController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Notas (opcional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                isDense: true,
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: Colors.red.shade700,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: Colors.red.shade700),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submitting || !_hasSelection ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Enviar ($selectedCount)'),
        ),
      ],
    );
  }
}

class _ItemRow extends StatefulWidget {
  final InventoryItemSummary item;
  final double quantity;
  final ValueChanged<double> onChange;

  const _ItemRow({
    required this.item,
    required this.quantity,
    required this.onChange,
  });

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.quantity > 0 ? widget.quantity.toString() : '',
    );
  }

  @override
  void didUpdateWidget(_ItemRow old) {
    super.didUpdateWidget(old);
    if (widget.quantity == 0 && _controller.text.isNotEmpty) {
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.quantity > 0;
    final exceedsStock = widget.quantity > widget.item.stock;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.06)
            : AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: exceedsStock
              ? Colors.red.shade300
              : selected
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.item.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Stock: ${widget.item.stock.toStringAsFixed(2)} ${widget.item.unit}',
                  style: TextStyle(
                    color: AppColors.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                hintText: '0',
                suffixText: widget.item.unit,
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              onChanged: (text) {
                final v = double.tryParse(text.replaceAll(',', '.')) ?? 0;
                widget.onChange(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
