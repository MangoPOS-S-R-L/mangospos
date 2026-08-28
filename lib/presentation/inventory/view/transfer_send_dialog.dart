import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../state/inventory_state.dart';
import '../utils/transfer_validation.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../viewmodel/transfers_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../services/session/session_controller.dart';

class TransferSendDialog extends ConsumerStatefulWidget {
  /// Bodega de ORIGEN sugerida. La manda el interior de una bodega: si ya
  /// estás parado en el Bar, la transferencia sale del Bar.
  final String? initialFromWarehouseId;

  const TransferSendDialog({super.key, this.initialFromWarehouseId});

  @override
  ConsumerState<TransferSendDialog> createState() => _TransferSendDialogState();
}

class _TransferSendDialogState extends ConsumerState<TransferSendDialog> {
  // Sprint 2: tipo de transferencia.
  bool _isCrossBusiness = false;
  String? _targetBusinessId;

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

  /// Bodegas del business destino cuando es inter-sucursal.
  bool _loadingTargetWarehouses = false;
  List<InventoryWarehouseDetail> _targetWarehouses = const [];
  String? _targetWarehousesError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(inventoryViewModelProvider).init();
      // Pre-seleccionar la primera bodega como origen y la siguiente como destino.
      final inv = ref.read(inventoryViewModelProvider).state;
      final realWarehouses = inv.warehouses; // ya no incluye IN_TRANSIT
      final requested = widget.initialFromWarehouseId;
      final origin = requested == null
          ? null
          : realWarehouses.where((w) => w.id == requested).firstOrNull;
      if (realWarehouses.length >= 2) {
        setState(() {
          _fromWarehouseId = origin?.id ?? realWarehouses.first.id;
          _toWarehouseId = realWarehouses
              .firstWhere(
                (w) => w.id != _fromWarehouseId,
                orElse: () => realWarehouses[1],
              )
              .id;
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

  Future<void> _loadTargetWarehouses(String targetBusinessId) async {
    setState(() {
      _loadingTargetWarehouses = true;
      _targetWarehousesError = null;
      _targetWarehouses = const [];
      _toWarehouseId = null;
    });
    try {
      final repo = ref.read(inventoryRepositoryProvider);
      final list = await repo.getAllWarehouses(targetBusinessId);
      // Excluir IN_TRANSIT y bodegas inactivas como destino válido.
      final usable = list
          .where((w) => w.isActive && !w.isInTransit)
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _targetWarehouses = usable;
        _loadingTargetWarehouses = false;
        if (usable.length == 1) {
          _toWarehouseId = usable.first.id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingTargetWarehouses = false;
        _targetWarehousesError =
            'No se pudieron cargar las bodegas del negocio destino: $e';
      });
    }
  }

  /// Sucursales donde el usuario tiene rol owner/admin/manager y que no son
  /// la activa. Si la lista está vacía, no se puede hacer transferencia
  /// inter-sucursal.
  List<SessionBusiness> _candidateTargets(SessionState session) {
    final active = session.activeBusinessId;
    return session.availableBusinesses
        .where(
          (b) =>
              b.id != active &&
              (b.role == 'owner' || b.role == 'admin' || b.role == 'manager'),
        )
        .toList(growable: false);
  }

  /// Devuelve [value] sólo si aparece exactamente una vez en [ids]; de lo
  /// contrario null. Evita el assert de [DropdownButton] cuando el valor
  /// seleccionado ya no está (o quedó duplicado) en la lista de ítems.
  String? _safeDropdownValue(String? value, Iterable<String> ids) {
    if (value == null) return null;
    return ids.where((id) => id == value).length == 1 ? value : null;
  }

  bool get _hasSelection {
    if (_quantities.values.every((q) => q <= 0)) return false;
    if (_fromWarehouseId == null || _toWarehouseId == null) return false;
    if (_isCrossBusiness) {
      if (_targetBusinessId == null) return false;
      return true; // origen y destino están en negocios distintos
    }
    return _fromWarehouseId != _toWarehouseId;
  }

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

    // Validar el stock SOLO de lo que se va a transferir. La regla vive en
    // validateTransferLines para poder probarla: antes este recorrido pasaba
    // por TODOS los ítems de la bodega y un artículo en negativo que nadie
    // seleccionó tumbaba la transferencia completa.
    final stockError = validateTransferLines(
      items: _sourceItems,
      quantities: _quantities,
    );
    if (stockError != null) {
      setState(() => _errorMessage = stockError);
      return;
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(transfersViewModelProvider)
          .createTransfer(
            fromWarehouseId: _fromWarehouseId!,
            toWarehouseId: _toWarehouseId!,
            items: items,
            notes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
            targetBusinessId: _isCrossBusiness ? _targetBusinessId : null,
          );
      if (!mounted) return;
      navigator.pop();
      AppToast.info(
        context,
        _isCrossBusiness
            ? 'Transferencia inter-sucursal enviada'
            : 'Transferencia enviada',
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
    if (raw.contains('INSUFFICIENT_ROLE_TARGET')) {
      return 'No tienes permisos en el negocio destino';
    }
    if (raw.contains('INSUFFICIENT_ROLE_SOURCE') ||
        raw.contains('INSUFFICIENT_ROLE')) {
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
      return 'Bodega destino inválida (no pertenece al negocio destino)';
    }
    if (raw.contains('ITEM_NOT_FROM_SOURCE')) {
      return 'Uno de los ítems no pertenece al negocio origen';
    }
    return 'Error: $raw';
  }

  @override
  Widget build(BuildContext context) {
    final inv = ref.watch(inventoryViewModelProvider).state;
    final warehouses = inv.warehouses;
    final session = ref.watch(sessionProvider);
    final candidateTargets = _candidateTargets(session);
    final selectedCount = _quantities.values.where((q) => q > 0).length;

    // Selección efectiva de bodegas destino según tipo. Normalizamos a una
    // lista de records `(id, name)` porque InventoryWarehouse (intra) e
    // InventoryWarehouseDetail (inter) son tipos distintos.
    final List<({String id, String name})> destWarehouses = _isCrossBusiness
        ? _targetWarehouses
              .map((w) => (id: w.id, name: w.name))
              .toList(growable: false)
        : warehouses
              .where((w) => w.id != _fromWarehouseId)
              .map((w) => (id: w.id, name: w.name))
              .toList(growable: false);

    return AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: const Text('Nueva transferencia'),
      content: SizedBox(
        width: 600,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TransferTypeSelector(
              isCrossBusiness: _isCrossBusiness,
              canSelectCross: candidateTargets.isNotEmpty,
              onChanged: (cross) {
                setState(() {
                  _isCrossBusiness = cross;
                  _toWarehouseId = null;
                  if (!cross) {
                    _targetBusinessId = null;
                    _targetWarehouses = const [];
                    _targetWarehousesError = null;
                  }
                });
              },
            ),
            if (_isCrossBusiness && candidateTargets.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'No tienes otra sucursal disponible con rol de '
                  'administrador/supervisor.',
                  style: TextStyle(
                    color: AppColors.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ),
            if (_isCrossBusiness && candidateTargets.isNotEmpty) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _safeDropdownValue(
                  _targetBusinessId,
                  candidateTargets.map((b) => b.id),
                ),
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Negocio destino',
                  prefixIcon: Icon(Icons.storefront_outlined),
                  border: OutlineInputBorder(),
                ),
                items: candidateTargets
                    .map(
                      (b) => DropdownMenuItem(
                        value: b.id,
                        child: Text(
                          '${b.name}  ·  ${b.roleLabel}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (v) async {
                  setState(() {
                    _targetBusinessId = v;
                    _toWarehouseId = null;
                  });
                  if (v != null) await _loadTargetWarehouses(v);
                },
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _safeDropdownValue(
                      _fromWarehouseId,
                      warehouses.map((w) => w.id),
                    ),
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
                        // En intra-sucursal, origen y destino no pueden ser la
                        // misma bodega: si colisionan, limpiamos el destino para
                        // no dejar un valor que el dropdown destino filtra.
                        if (!_isCrossBusiness && _toWarehouseId == v) {
                          _toWarehouseId = null;
                        }
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
                  child: _loadingTargetWarehouses
                      ? const InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Bodega destino',
                            border: OutlineInputBorder(),
                          ),
                          child: SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : DropdownButtonFormField<String>(
                          initialValue: _safeDropdownValue(
                            _toWarehouseId,
                            destWarehouses.map((w) => w.id),
                          ),
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: _isCrossBusiness
                                ? 'Bodega destino (otra sucursal)'
                                : 'Bodega destino',
                            border: const OutlineInputBorder(),
                          ),
                          items: destWarehouses
                              .map(
                                (w) => DropdownMenuItem(
                                  value: w.id,
                                  child: Text(w.name),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: destWarehouses.isEmpty
                              ? null
                              : (v) => setState(() => _toWarehouseId = v),
                        ),
                ),
              ],
            ),
            if (_targetWarehousesError != null) ...[
              const SizedBox(height: 8),
              Text(
                _targetWarehousesError!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 12),
              ),
            ],
            if (_isCrossBusiness &&
                _targetBusinessId != null &&
                !_loadingTargetWarehouses &&
                _targetWarehouses.isEmpty &&
                _targetWarehousesError == null) ...[
              const SizedBox(height: 6),
              Text(
                'El negocio destino no tiene bodegas activas.',
                style: TextStyle(color: AppColors.mutedForeground, fontSize: 12),
              ),
            ],
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
            if (_isCrossBusiness && _targetBusinessId != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.06),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.25),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: AppColors.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Los insumos que no existan en la sucursal destino se '
                        'crearán automáticamente al recibirla (match por SKU '
                        'o nombre).',
                        style: TextStyle(
                          color: AppColors.foreground,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
}

class _TransferTypeSelector extends StatelessWidget {
  final bool isCrossBusiness;
  final bool canSelectCross;
  final ValueChanged<bool> onChanged;

  const _TransferTypeSelector({
    required this.isCrossBusiness,
    required this.canSelectCross,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: <ButtonSegment<bool>>[
        const ButtonSegment(
          value: false,
          icon: Icon(Icons.warehouse_outlined, size: 18),
          label: Text('Misma sucursal'),
        ),
        ButtonSegment(
          value: true,
          enabled: canSelectCross,
          icon: const Icon(Icons.storefront_outlined, size: 18),
          label: const Text('Otra sucursal'),
        ),
      ],
      selected: {isCrossBusiness},
      onSelectionChanged: (s) => onChanged(s.first),
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
    // Solo se marca en rojo lo que el usuario PIDIÓ de más. Sin el `selected`
    // toda fila con existencia negativa nacía en rojo aunque nadie la hubiera
    // tocado, porque 0 > -5.
    final exceedsStock = selected && widget.quantity > widget.item.stock;
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
