// PRD 9 Fase 1D — CRUD de Insumos (inventory_items).
//
// Versión completa orientada al módulo Inventario, con todos los campos
// del schema incluyendo los nuevos de Fase 0:
//   - costing_method (average | fifo)
//   - barcode
//
// Diferencia con `inventory_outflow_view.dart`: aquélla mezcla CRUD con
// el registro de salidas. Ésta es CRUD puro y soporta los campos que
// el motor de costeo (Fase 3) va a necesitar.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/inventory_state.dart';

class InventoryItemsView extends ConsumerStatefulWidget {
  const InventoryItemsView({super.key});

  @override
  ConsumerState<InventoryItemsView> createState() => _InventoryItemsViewState();
}

class _InventoryItemsViewState extends ConsumerState<InventoryItemsView> {
  bool _loading = true;
  String? _error;
  String? _businessId;
  List<InventoryWarehouse> _warehouses = const [];
  String? _selectedWarehouseId;
  List<InventoryItemSummary> _items = const [];
  String _query = '';
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  InventoryRepository get _repo =>
      InventoryRepository(Supabase.instance.client);

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId =
          await resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
      if (businessId == null) {
        setState(() {
          _loading = false;
          _error = 'No se pudo resolver el negocio activo.';
        });
        return;
      }
      final warehouses = await _repo.getWarehouses(businessId);
      _businessId = businessId;
      _warehouses = warehouses;
      _selectedWarehouseId = warehouses.isNotEmpty ? warehouses.first.id : null;
      await _loadItems();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadItems() async {
    final businessId = _businessId;
    final warehouseId = _selectedWarehouseId;
    if (businessId == null || warehouseId == null) {
      setState(() {
        _loading = false;
        _items = const [];
      });
      return;
    }
    try {
      final items = await _repo.getItems(
        businessId: businessId,
        warehouseId: warehouseId,
        query: _query,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _onSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _query = value;
        _loading = true;
      });
      _loadItems();
    });
  }

  Future<void> _openForm({InventoryItemSummary? edit}) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ItemFormDialog(
        businessId: businessId,
        repo: _repo,
        edit: edit,
      ),
    );
    if (result == true) {
      setState(() => _loading = true);
      await _loadItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(
      locale: 'es_DO',
      symbol: 'RD\$',
      decimalDigits: 2,
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: _loading && _items.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 40, color: AppColors.destructive),
                        const SizedBox(height: 12),
                        Text(_error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.foreground)),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _bootstrap,
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Header(
                        warehouses: _warehouses,
                        selectedId: _selectedWarehouseId,
                        onSelect: (id) {
                          setState(() {
                            _selectedWarehouseId = id;
                            _loading = true;
                          });
                          _loadItems();
                        },
                        onCreate: () => _openForm(),
                        onSearch: _onSearch,
                      ),
                      const SizedBox(height: 20),
                      _ItemsTable(
                        items: _items,
                        currency: currency,
                        loading: _loading,
                        onEdit: (i) => _openForm(edit: i),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _Header extends StatelessWidget {
  final List<InventoryWarehouse> warehouses;
  final String? selectedId;
  final ValueChanged<String?> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<String> onSearch;

  const _Header({
    required this.warehouses,
    required this.selectedId,
    required this.onSelect,
    required this.onCreate,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Insumos',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Items inventariables, costo y método de costeo',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Nuevo insumo'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                initialValue: selectedId,
                decoration: const InputDecoration(
                  labelText: 'Bodega para mostrar stock',
                  isDense: true,
                ),
                items: [
                  for (final w in warehouses)
                    DropdownMenuItem(
                      value: w.id,
                      child: Text(w.isMain ? '${w.name}  •  principal' : w.name),
                    ),
                ],
                onChanged: onSelect,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Buscar por nombre, SKU o descripción',
                  isDense: true,
                ),
                onChanged: onSearch,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ItemsTable extends StatelessWidget {
  final List<InventoryItemSummary> items;
  final NumberFormat currency;
  final bool loading;
  final void Function(InventoryItemSummary) onEdit;

  const _ItemsTable({
    required this.items,
    required this.currency,
    required this.loading,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2_outlined,
                  size: 36, color: AppColors.mutedForeground),
              const SizedBox(height: 8),
              Text(
                loading ? 'Cargando...' : 'No hay insumos que mostrar.',
                style: TextStyle(color: AppColors.mutedForeground),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(flex: 4, child: _h('Insumo')),
                Expanded(flex: 2, child: _h('SKU / Barcode')),
                Expanded(flex: 2, child: _h('Costeo')),
                Expanded(flex: 2, child: _h('Costo')),
                Expanded(flex: 2, child: _h('Stock')),
                Expanded(flex: 1, child: _h('Estado')),
                const SizedBox(width: 60),
              ],
            ),
          ),
          Divider(color: AppColors.border, height: 1),
          ...items.asMap().entries.map((entry) {
            final i = entry.value;
            final last = entry.key == items.length - 1;
            return _ItemRow(
              item: i,
              currency: currency,
              onEdit: onEdit,
              isLast: last,
            );
          }),
        ],
      ),
    );
  }

  Widget _h(String t) => Text(
        t,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.mutedForeground,
        ),
      );
}

class _ItemRow extends StatelessWidget {
  final InventoryItemSummary item;
  final NumberFormat currency;
  final void Function(InventoryItemSummary) onEdit;
  final bool isLast;

  const _ItemRow({
    required this.item,
    required this.currency,
    required this.onEdit,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                ),
                if (item.description.isNotEmpty)
                  Text(
                    item.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: AppColors.mutedForeground),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.sku.isEmpty ? '—' : item.sku,
                  style: TextStyle(
                      fontSize: 13, color: AppColors.foreground),
                ),
                if (item.barcode.isNotEmpty)
                  Text(
                    item.barcode,
                    style: TextStyle(
                        fontSize: 10, color: AppColors.mutedForeground),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: _CostingBadge(method: item.costingMethod),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currency.format(item.cost),
                  style: TextStyle(
                      fontSize: 13, color: AppColors.foreground),
                ),
                Text(
                  '/ ${item.unit}',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.mutedForeground),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: _StockCell(item: item),
          ),
          Expanded(
            flex: 1,
            child: item.isActive
                ? _Pill(text: 'Activo', color: AppColors.success)
                : _Pill(text: 'Inactivo', color: AppColors.mutedForeground),
          ),
          SizedBox(
            width: 60,
            child: Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Editar',
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => onEdit(item),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StockCell extends StatelessWidget {
  final InventoryItemSummary item;
  const _StockCell({required this.item});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern('es_DO');
    final low = item.isLowStock;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fmt.format(item.stock),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: low ? AppColors.warning : AppColors.foreground,
          ),
        ),
        Text(
          'min ${fmt.format(item.minStock)}',
          style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
        ),
      ],
    );
  }
}

class _CostingBadge extends StatelessWidget {
  final String method;
  const _CostingBadge({required this.method});

  @override
  Widget build(BuildContext context) {
    final isFifo = method == 'fifo';
    return _Pill(
      text: isFifo ? 'FIFO' : 'Promedio',
      color: isFifo ? AppColors.info : AppColors.primary,
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _ItemFormDialog extends StatefulWidget {
  final String businessId;
  final InventoryRepository repo;
  final InventoryItemSummary? edit;

  const _ItemFormDialog({
    required this.businessId,
    required this.repo,
    this.edit,
  });

  @override
  State<_ItemFormDialog> createState() => _ItemFormDialogState();
}

class _ItemFormDialogState extends State<_ItemFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _skuCtrl;
  late final TextEditingController _barcodeCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _unitCtrl;
  late final TextEditingController _costCtrl;
  late final TextEditingController _minStockCtrl;
  late final TextEditingController _maxStockCtrl;
  late String _costingMethod;
  late bool _isActive;
  late bool _tracksLots;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.edit != null;

  @override
  void initState() {
    super.initState();
    final e = widget.edit;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _skuCtrl = TextEditingController(text: e?.sku ?? '');
    _barcodeCtrl = TextEditingController(text: e?.barcode ?? '');
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _unitCtrl = TextEditingController(text: e?.unit ?? 'unidad');
    _costCtrl = TextEditingController(text: e?.cost.toString() ?? '0');
    _minStockCtrl =
        TextEditingController(text: e?.minStock.toString() ?? '0');
    _maxStockCtrl = TextEditingController(
        text: e?.maxStock != null ? e!.maxStock!.toString() : '');
    _costingMethod = e?.costingMethod == 'fifo' ? 'fifo' : 'average';
    _isActive = e?.isActive ?? true;
    _tracksLots = e?.tracksLots ?? false;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _skuCtrl.dispose();
    _barcodeCtrl.dispose();
    _descCtrl.dispose();
    _unitCtrl.dispose();
    _costCtrl.dispose();
    _minStockCtrl.dispose();
    _maxStockCtrl.dispose();
    super.dispose();
  }

  String? _orNull(String v) => v.trim().isEmpty ? null : v.trim();
  double _toDouble(String v) => double.tryParse(v.trim().replaceAll(',', '.')) ?? 0;
  double? _toDoubleOrNull(String v) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t.replaceAll(',', '.'));
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        await widget.repo.updateItem(
          itemId: widget.edit!.id,
          name: name,
          sku: _orNull(_skuCtrl.text),
          description: _orNull(_descCtrl.text),
          unit: _unitCtrl.text.trim().isEmpty
              ? 'unidad'
              : _unitCtrl.text.trim(),
          cost: _toDouble(_costCtrl.text),
          minStock: _toDouble(_minStockCtrl.text),
          maxStock: _toDoubleOrNull(_maxStockCtrl.text),
          isActive: _isActive,
          costingMethod: _costingMethod,
          barcode: _orNull(_barcodeCtrl.text) ?? '',
          tracksLots: _tracksLots,
        );
      } else {
        await widget.repo.createItem(
          businessId: widget.businessId,
          name: name,
          sku: _orNull(_skuCtrl.text),
          description: _orNull(_descCtrl.text),
          unit: _unitCtrl.text.trim().isEmpty
              ? 'unidad'
              : _unitCtrl.text.trim(),
          cost: _toDouble(_costCtrl.text),
          minStock: _toDouble(_minStockCtrl.text),
          maxStock: _toDoubleOrNull(_maxStockCtrl.text),
          isActive: _isActive,
          costingMethod: _costingMethod,
          barcode: _orNull(_barcodeCtrl.text),
          tracksLots: _tracksLots,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Editar insumo' : 'Nuevo insumo'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Nombre *'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _skuCtrl,
                      decoration: const InputDecoration(labelText: 'SKU'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _barcodeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Código de barras',
                        hintText: 'EAN-13, UPC, etc.',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(labelText: 'Descripción'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  SizedBox(
                    width: 140,
                    child: TextField(
                      controller: _unitCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Unidad',
                        hintText: 'unidad, kg, ml',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _costCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Costo (RD\$)',
                        prefixText: 'RD\$ ',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minStockCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Stock mínimo',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _maxStockCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Stock máximo (opcional)',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Método de costeo',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'average',
                    label: Text('Promedio ponderado'),
                    icon: Icon(Icons.calculate_outlined),
                  ),
                  ButtonSegment(
                    value: 'fifo',
                    label: Text('FIFO'),
                    icon: Icon(Icons.layers_outlined),
                  ),
                ],
                selected: {_costingMethod},
                onSelectionChanged: (s) =>
                    setState(() => _costingMethod = s.first),
              ),
              const SizedBox(height: 6),
              Text(
                _costingMethod == 'fifo'
                    ? 'FIFO: la primera capa que entró es la primera en consumirse. Útil para perecederos.'
                    : 'Promedio: el costo se recalcula al recibir mercancía. Más simple para no perecederos.',
                style: TextStyle(
                    fontSize: 11, color: AppColors.mutedForeground),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v ?? true),
                title: const Text('Insumo activo'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              CheckboxListTile(
                value: _tracksLots,
                onChanged: (v) => setState(() => _tracksLots = v ?? false),
                title: const Text('Rastrear lotes y vencimientos'),
                subtitle: Text(
                  'Al recibir mercancía se solicitará número de lote y fecha '
                  'de vencimiento. Útil para perecederos, farmacéuticos y '
                  'químicos.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedForeground,
                  ),
                ),
                isThreeLine: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style:
                      TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text(_isEdit ? 'Guardar' : 'Crear'),
        ),
      ],
    );
  }
}
