// Sprint 4 Inventario — Dialog para crear una recepción directa.
//
// Usuario selecciona: bodega destino, proveedor (opcional), e indica
// cantidades a recibir por insumo (con costo unitario opcional). Al
// confirmar, llama fn_inventory_direct_receipt que crea atómicamente el
// header + items + movimientos de inventario tipo 'purchase'.
//
// Al cerrar devuelve el documento de la recepción (`GoodsReceipt`) para que
// quien lo abrió lo imprima: una compra manual también deja papel, con las
// mismas firmas que el conduce de una orden de compra.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/utils/app_toast.dart';

import '../../../core/inventory/pack_conversion.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../services/session/session_controller.dart';
import '../../purchases/state/goods_receipt.dart';
import '../services/inventory_scan.dart';
import '../state/inventory_state.dart';
import '../viewmodel/direct_receipts_viewmodel.dart';
import '../viewmodel/inventory_viewmodel.dart';

class DirectReceiptDialog extends ConsumerStatefulWidget {
  const DirectReceiptDialog({super.key});

  @override
  ConsumerState<DirectReceiptDialog> createState() =>
      _DirectReceiptDialogState();
}

class _DirectReceiptDialogState extends ConsumerState<DirectReceiptDialog> {
  String? _warehouseId;
  String? _supplierId;
  final TextEditingController _notesController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  /// itemId → { quantity, unitCost }
  final Map<String, _LineDraft> _drafts = {};

  bool _loadingItems = false;
  bool _submitting = false;
  String? _errorMessage;
  List<InventoryItemSummary> _items = const [];
  List<InventorySupplierDetail> _suppliers = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(inventoryViewModelProvider).init();
      final inv = ref.read(inventoryViewModelProvider).state;
      final warehouses = inv.warehouses;
      if (warehouses.isNotEmpty) {
        // Default: bodega principal si existe, sino la primera.
        final main = warehouses.firstWhere(
          (w) => w.isMain,
          orElse: () => warehouses.first,
        );
        setState(() => _warehouseId = main.id);
        await _loadItems();
      }
      await _loadSuppliers();
    });
  }

  Future<void> _loadSuppliers() async {
    final businessId = ref.read(inventoryViewModelProvider).state.businessId;
    if (businessId == null) return;
    try {
      final repo = ref.read(inventoryRepositoryProvider);
      final list = await repo.getAllSuppliers(businessId);
      if (!mounted) return;
      setState(() {
        _suppliers = list.where((s) => s.isActive).toList(growable: false);
      });
    } catch (_) {
      // Silenciar: si falla, simplemente no aparecen proveedores en el dropdown.
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadItems() async {
    if (_warehouseId == null) return;
    setState(() => _loadingItems = true);
    try {
      final vm = ref.read(inventoryViewModelProvider);
      await vm.selectWarehouse(_warehouseId);
      _items = vm.state.items;
    } finally {
      if (mounted) setState(() => _loadingItems = false);
    }
  }

  List<InventoryItemSummary> get _filteredItems {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where(
          (i) =>
              i.name.toLowerCase().contains(q) ||
              i.sku.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  /// Escanear suma UNA unidad de lo que se está recibiendo y lo deja
  /// visible. Recibir mercancía es contar bultos: la pistola sirve
  /// exactamente para eso, un disparo por bulto.
  void _onScannedItem(InventoryItemSummary item) {
    setState(() {
      final actual = _drafts[item.id];
      final nueva = (actual?.quantity ?? 0) + 1;
      _drafts[item.id] = actual == null
          ? _LineDraft(quantity: nueva)
          : actual.copyWith(quantity: nueva);
      _searchController.text = item.name;
    });
    final total = _drafts[item.id]!.quantity;
    AppToast.success(
      context,
      '${item.name}: '
      '${total == total.roundToDouble() ? total.toStringAsFixed(0) : total.toStringAsFixed(2)} '
      '${item.unit}',
    );
  }

  int get _selectedCount =>
      _drafts.values.where((d) => d.quantity > 0).length;

  /// Costo unitario que se va a REGISTRAR: el que el usuario tipeó o, si lo
  /// dejó en blanco, el costo maestro del insumo.
  ///
  /// Antes el total en pantalla aplicaba este respaldo pero el payload de
  /// `_submit` mandaba `draft.unitCost` crudo, o sea `null`. Resultado: la
  /// línea entraba sin costo, el total de la recepción quedaba en cero y el
  /// trigger de recosteo no disparaba porque exige `cost_per_unit > 0`. Es el
  /// hallazgo 3 de la auditoría DH del 02-09-2026 (436 de 454 líneas de
  /// recepción directa sin costo unitario, 10,459 unidades). Una sola fuente
  /// para pantalla y payload para que no vuelvan a divergir.
  double _resolvedUnitCost(String itemId, double? typed) {
    if (typed != null) return typed;
    for (final item in _items) {
      if (item.id == itemId) return item.cost;
    }
    return 0;
  }

  double get _grandTotal {
    var total = 0.0;
    for (final entry in _drafts.entries) {
      final qty = entry.value.quantity;
      if (qty <= 0) continue;
      total += qty * _resolvedUnitCost(entry.key, entry.value.unitCost);
    }
    return total;
  }

  Future<void> _submit() async {
    if (_warehouseId == null) {
      setState(() => _errorMessage = 'Selecciona una bodega destino');
      return;
    }
    if (_selectedCount == 0) {
      setState(() => _errorMessage = 'Indica al menos un ítem con cantidad');
      return;
    }
    final items = <Map<String, dynamic>>[];
    for (final entry in _drafts.entries) {
      final draft = entry.value;
      if (draft.quantity <= 0) continue;
      items.add({
        'item_id': entry.key,
        'quantity': draft.quantity,
        'unit_cost': _resolvedUnitCost(entry.key, draft.unitCost),
        if (draft.lotNumber != null && draft.lotNumber!.isNotEmpty)
          'lot_number': draft.lotNumber,
        if (draft.expiryDate != null)
          'expiry_date': draft.expiryDate!.toIso8601String().split('T').first,
      });
    }

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final navigator = Navigator.of(context);
    try {
      final header = await ref
          .read(directReceiptsViewModelProvider)
          .createReceipt(
            warehouseId: _warehouseId!,
            items: items,
            supplierId: _supplierId,
            notes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
          );
      if (!mounted) return;
      // El documento se arma acá, con lo que se acaba de recibir, y viaja
      // como resultado del diálogo: quien lo abrió lo imprime.
      navigator.pop(_buildDocument(header));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = _humanize(e.toString());
      });
    }
  }

  /// Documento de la recepción directa: el papel que prueba la entrada.
  ///
  /// Es el MISMO documento que el conduce de una orden de compra —mismo
  /// formato, mismas firmas— pero sin orden detrás: la mercancía entró sin OC
  /// previa, así que no hay número de orden ni factura que declarar.
  GoodsReceipt _buildDocument(Map<String, dynamic> header) {
    final inv = ref.read(inventoryViewModelProvider).state;
    final warehouseName = inv.warehouses
            .where((w) => w.id == _warehouseId)
            .map((w) => w.name)
            .firstOrNull ??
        'Almacén';
    final supplierName = _suppliers
            .where((sup) => sup.id == _supplierId)
            .map((sup) => sup.name)
            .firstOrNull ??
        'Sin proveedor';

    final lines = <GoodsReceiptLine>[];
    for (final entry in _drafts.entries) {
      final draft = entry.value;
      if (draft.quantity <= 0) continue;
      final item = _items.where((i) => i.id == entry.key).firstOrNull;
      lines.add(
        GoodsReceiptLine(
          code: item?.sku ?? '',
          reference: '',
          description: item?.name ?? 'Artículo',
          // Las cantidades del borrador ya están en unidad BASE: es lo que se
          // manda a la RPC y lo que entra al kardex.
          quantity: draft.quantity,
          unit: item?.unit ?? 'unidad',
          unitCost: _resolvedUnitCost(entry.key, draft.unitCost),
        ),
      );
    }

    final createdAt =
        DateTime.tryParse(header['created_at']?.toString() ?? '')?.toLocal() ??
            DateTime.now();

    return GoodsReceipt(
      id: header['id']?.toString() ?? '',
      number: header['receipt_number']?.toString() ?? '',
      date: createdAt,
      createdAt: createdAt,
      status: header['status']?.toString() ?? 'received',
      orderId: null,
      orderNumber: '',
      invoiceNumber: '',
      ncf: '',
      supplierName: supplierName,
      supplierRnc: '',
      warehouseName: warehouseName,
      // En una compra manual quien registra es quien recibió: la RPC guarda
      // su `auth.uid()` en `received_by` y el papel dice lo mismo.
      receivedByName: (ref.read(sessionProvider).userName ?? '').trim(),
      notes: _notesController.text.trim(),
      lines: lines,
    );
  }

  String _humanize(String raw) {
    if (raw.contains('INSUFFICIENT_ROLE')) {
      return 'No tienes permisos para registrar recepciones.';
    }
    if (raw.contains('WAREHOUSE_NOT_FOUND_OR_INACTIVE')) {
      return 'La bodega seleccionada no es válida.';
    }
    if (raw.contains('SUPPLIER_NOT_FOUND')) {
      return 'El proveedor seleccionado no es válido.';
    }
    if (raw.contains('ITEM_NOT_IN_BUSINESS')) {
      return 'Un ítem no pertenece a este negocio.';
    }
    if (raw.contains('EMPTY_ITEMS')) {
      return 'Debes indicar al menos un ítem.';
    }
    return 'Error: $raw';
  }

  @override
  Widget build(BuildContext context) {
    final inv = ref.watch(inventoryViewModelProvider).state;
    final warehouses = inv.warehouses;
    final suppliers = _suppliers;

    return InventoryScanListener(
      enabled: !_submitting,
      items: _items,
      onItem: _onScannedItem,
      child: AlertDialog(
      backgroundColor: AppColors.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: const Text(
        'Nueva recepción directa',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 640,
        height: 580,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _warehouseId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Bodega destino',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: warehouses
                        .map(
                          (w) => DropdownMenuItem(
                            value: w.id,
                            child: Text(
                              w.isMain ? '${w.name}  ★' : w.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (v) async {
                      setState(() {
                        _warehouseId = v;
                        _drafts.clear();
                      });
                      await _loadItems();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _supplierId ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Proveedor (opcional)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Sin proveedor'),
                      ),
                      ...suppliers
                          .where((s) => s.isActive)
                          .map(
                            (s) => DropdownMenuItem(
                              value: s.id,
                              child: Text(
                                s.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                    ],
                    onChanged: (v) => setState(() {
                      _supplierId = v == null || v.isEmpty ? null : v;
                    }),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
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
            const SizedBox(height: 8),
            Expanded(
              child: _loadingItems
                  ? Center(
                      child: CircularProgressIndicator(color: AppColors.primary),
                    )
                  : _warehouseId == null
                  ? Center(
                      child: Text(
                        'Selecciona una bodega para continuar.',
                        style: TextStyle(color: AppColors.mutedForeground),
                      ),
                    )
                  : _items.isEmpty
                  ? Center(
                      child: Text(
                        'Este negocio no tiene insumos registrados.',
                        style: TextStyle(color: AppColors.mutedForeground),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filteredItems.length,
                      itemBuilder: (context, index) {
                        final item = _filteredItems[index];
                        final draft = _drafts[item.id];
                        return _ItemRow(
                          item: item,
                          draft: draft,
                          onChange: (newDraft) {
                            setState(() {
                              if (newDraft == null || newDraft.quantity <= 0) {
                                _drafts.remove(item.id);
                              } else {
                                _drafts[item.id] = newDraft;
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _notesController,
                    maxLines: 1,
                    decoration: InputDecoration(
                      labelText: 'Notas (opcional)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                      ),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Total',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      Text(
                        'RD\$ ${_grandTotal.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
          onPressed: _submitting || _selectedCount == 0 ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Registrar ($_selectedCount)'),
        ),
      ],
      ),
    );
  }
}

// ── fin del diálogo ──

class _LineDraft {
  final double quantity;
  final double? unitCost;
  final String? lotNumber;
  final DateTime? expiryDate;
  const _LineDraft({
    required this.quantity,
    this.unitCost,
    this.lotNumber,
    this.expiryDate,
  });

  _LineDraft copyWith({
    double? quantity,
    double? unitCost,
    String? lotNumber,
    DateTime? expiryDate,
    bool clearUnitCost = false,
    bool clearLotNumber = false,
    bool clearExpiryDate = false,
  }) {
    return _LineDraft(
      quantity: quantity ?? this.quantity,
      unitCost: clearUnitCost ? null : (unitCost ?? this.unitCost),
      lotNumber: clearLotNumber ? null : (lotNumber ?? this.lotNumber),
      expiryDate: clearExpiryDate ? null : (expiryDate ?? this.expiryDate),
    );
  }
}

class _ItemRow extends StatefulWidget {
  final InventoryItemSummary item;
  final _LineDraft? draft;
  final ValueChanged<_LineDraft?> onChange;

  const _ItemRow({
    required this.item,
    required this.draft,
    required this.onChange,
  });

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  late TextEditingController _qtyController;
  late TextEditingController _costController;
  late TextEditingController _lotController;
  DateTime? _expiryDate;

  // Conversión de empaque: input/display en unidad de compra (botellas),
  // draft/movimiento en unidad base (ml).
  bool get _hasPack =>
      widget.item.packSize > 1 && widget.item.purchaseUnit.trim().isNotEmpty;
  String get _displayUnit =>
      _hasPack ? widget.item.purchaseUnit.trim() : widget.item.unit;
  double get _packSize => widget.item.packSize;

  @override
  void initState() {
    super.initState();
    final draftQty = widget.draft?.quantity ?? 0;
    _qtyController = TextEditingController(
      text: draftQty > 0
          ? _formatQty(_hasPack ? baseToPack(draftQty, _packSize) : draftQty)
          : '',
    );
    _costController = TextEditingController(
      text: widget.draft?.unitCost != null
          ? (_hasPack
                  ? widget.draft!.unitCost! * _packSize
                  : widget.draft!.unitCost!)
              .toStringAsFixed(2)
          : '',
    );
    _lotController = TextEditingController(text: widget.draft?.lotNumber ?? '');
    _expiryDate = widget.draft?.expiryDate;
  }

  @override
  void didUpdateWidget(_ItemRow old) {
    super.didUpdateWidget(old);
    final draftQty = widget.draft?.quantity ?? 0;
    final expectedQty = draftQty > 0
        ? _formatQty(_hasPack ? baseToPack(draftQty, _packSize) : draftQty)
        : '';
    if (_qtyController.text != expectedQty) {
      _qtyController.text = expectedQty;
    }
  }

  String _formatQty(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _costController.dispose();
    _lotController.dispose();
    super.dispose();
  }

  void _emit() {
    final entered =
        double.tryParse(_qtyController.text.replaceAll(',', '.')) ?? 0;
    if (entered <= 0) {
      widget.onChange(null);
      return;
    }
    // Entrada en unidad de compra → base.
    final qty = _hasPack ? packToBase(entered, _packSize) : entered;
    final enteredCost = _costController.text.trim().isEmpty
        ? null
        : double.tryParse(_costController.text.replaceAll(',', '.'));
    final cost = enteredCost == null
        ? null
        : (_hasPack ? packCostToBaseCost(enteredCost, _packSize) : enteredCost);
    final lot = _lotController.text.trim().isEmpty
        ? null
        : _lotController.text.trim();
    widget.onChange(
      _LineDraft(
        quantity: qty,
        unitCost: cost,
        lotNumber: lot,
        expiryDate: _expiryDate,
      ),
    );
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
      initialDate: _expiryDate ?? now.add(const Duration(days: 30)),
      helpText: 'Fecha de vencimiento del lote',
    );
    if (picked != null) {
      setState(() => _expiryDate = picked);
      _emit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = (widget.draft?.quantity ?? 0) > 0;
    final tracksLots = widget.item.tracksLots;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.06)
            : AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.4)
              : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.item.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (tracksLots)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'LOTE',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: AppColors.primary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                    Text(
                      widget.item.sku.isNotEmpty
                          ? 'SKU ${widget.item.sku} · Stock actual: ${widget.item.stock.toStringAsFixed(2)} ${widget.item.unit}'
                          : 'Stock actual: ${widget.item.stock.toStringAsFixed(2)} ${widget.item.unit}',
                      style: TextStyle(
                        color: AppColors.mutedForeground,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 100,
                child: TextField(
                  controller: _qtyController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.right,
                  decoration: InputDecoration(
                    hintText: '0',
                    suffixText: _displayUnit,
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (_) => setState(_emit),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _costController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.right,
                  decoration: InputDecoration(
                    hintText: _hasPack
                        ? 'Costo/${widget.item.purchaseUnit.trim()}'
                        : (widget.item.cost > 0
                              ? widget.item.cost.toStringAsFixed(2)
                              : 'Costo'),
                    prefixText: 'RD\$',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (_) => _emit(),
                ),
              ),
            ],
          ),
          if (_hasPack && (widget.draft?.quantity ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '= ${_formatQty(widget.draft!.quantity)} ${widget.item.unit}',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                ),
              ),
            ),
          if (tracksLots && selected) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _lotController,
                    decoration: const InputDecoration(
                      labelText: 'Nº lote (auto si vacío)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: Icon(Icons.qr_code_2_rounded, size: 18),
                    ),
                    onChanged: (_) => _emit(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickExpiry,
                    icon: const Icon(Icons.calendar_today_outlined, size: 16),
                    label: Text(
                      _expiryDate != null
                          ? 'Vence ${_expiryDate!.day.toString().padLeft(2, '0')}/${_expiryDate!.month.toString().padLeft(2, '0')}/${_expiryDate!.year}'
                          : 'Fecha de vencimiento',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                ),
                if (_expiryDate != null)
                  IconButton(
                    onPressed: () {
                      setState(() => _expiryDate = null);
                      _emit();
                    },
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Quitar fecha',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
