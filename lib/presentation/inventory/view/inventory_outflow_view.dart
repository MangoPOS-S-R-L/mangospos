import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../../../app/theme/mango_colors.dart';

class InventoryOutflowView extends ConsumerStatefulWidget {
  const InventoryOutflowView({super.key});

  @override
  ConsumerState<InventoryOutflowView> createState() =>
      _InventoryOutflowViewState();
}

class _InventoryOutflowViewState extends ConsumerState<InventoryOutflowView> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(inventoryViewModelProvider).init();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(inventoryViewModelProvider);
    final state = vm.state;
    final currency = NumberFormat.currency(
      locale: 'es_DO',
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    return Scaffold(
      backgroundColor: MangoColors.sidebarBg,
      body: state.loading && state.items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Inventario',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: MangoColors.darkGray,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Insumos, stock actual y salidas manuales',
                            style: TextStyle(
                              fontSize: 14,
                              color: MangoColors.muted,
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          OutlinedButton.icon(
                            onPressed: state.saving
                                ? null
                                : () => _showCreateItemDialog(context),
                            icon: const Icon(Icons.add_box_outlined),
                            label: const Text('Nuevo insumo'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: MangoColors.primaryOrange,
                              side: const BorderSide(color: MangoColors.primaryOrange),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: state.items.isEmpty || state.saving
                                ? null
                                : () => _showOutflowDialog(
                                    context,
                                    initialItem: state.items.first,
                                  ),
                            icon: const Icon(Icons.logout_rounded),
                            label: const Text('Registrar salida'),
                            style: FilledButton.styleFrom(
                              backgroundColor: MangoColors.primaryOrange,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (state.error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFECACA)),
                      ),
                      child: Text(
                        state.error!,
                        style: const TextStyle(color: Color(0xFF991B1B)),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) => ref
                              .read(inventoryViewModelProvider)
                              .search(value),
                          decoration: InputDecoration(
                            hintText: 'Buscar por nombre, SKU o descripcion',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 260,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(state.selectedWarehouseId),
                          initialValue: state.selectedWarehouseId,
                          decoration: InputDecoration(
                            labelText: 'Almacen',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Colors.white,
                          ),
                          items: state.warehouses
                              .map(
                                (warehouse) => DropdownMenuItem(
                                  value: warehouse.id,
                                  child: Text(
                                    warehouse.isMain
                                        ? '${warehouse.name} · Principal'
                                        : warehouse.name,
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: state.saving
                              ? null
                              : (value) => ref
                                    .read(inventoryViewModelProvider)
                                    .selectWarehouse(value),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        onPressed: state.saving
                            ? null
                            : () => ref
                                  .read(inventoryViewModelProvider)
                                  .refresh(),
                        icon: const Icon(Icons.refresh),
                        style: IconButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange.withValues(alpha: 0.1),
                          foregroundColor: MangoColors.primaryOrange,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(
                        title: 'Insumos activos',
                        value:
                            '${state.items.where((item) => item.isActive).length}',
                        color: MangoColors.primaryOrange,
                      ),
                      _SummaryCard(
                        title: 'Stock bajo',
                        value:
                            '${state.items.where((item) => item.isLowStock).length}',
                        color: const Color(0xFFF59E0B),
                      ),
                      _SummaryCard(
                        title: 'Valor inventario',
                        value: currency.format(
                          state.items.fold<double>(
                            0,
                            (sum, item) => sum + (item.stock * item.cost),
                          ),
                        ),
                        color: const Color(0xFF059669),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Text(
                                  'INSUMO',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: MangoColors.muted,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'STOCK',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'PRESENTACIÓN',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'COSTO',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ),
                              SizedBox(width: 120),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (state.items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'No hay insumos registrados en este almacen.',
                            ),
                          )
                        else
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: state.items.length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = state.items[index];
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 14,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              color: MangoColors.darkGray,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            [
                                              if (item.sku.isNotEmpty) item.sku,
                                              item.unit,
                                              if (item.description.isNotEmpty)
                                                item.description,
                                            ].join(' · '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              color: MangoColors.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        '${item.stock.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: item.isLowStock
                                              ? Colors.orange.shade700
                                              : MangoColors.darkGray,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        item.unit.toUpperCase(),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(currency.format(item.cost)),
                                    ),
                                    SizedBox(
                                      width: 120,
                                      child: Wrap(
                                        alignment: WrapAlignment.end,
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          IconButton(
                                            tooltip: 'Editar insumo',
                                            onPressed: state.saving
                                                ? null
                                                : () => _showEditItemDialog(
                                                    context,
                                                    item,
                                                  ),
                                            icon: const Icon(
                                              Icons.edit_outlined,
                                            ),
                                          ),
                                          FilledButton.tonal(
                                            onPressed: state.saving
                                                ? null
                                                : () => _showOutflowDialog(
                                                    context,
                                                    initialItem: item,
                                                  ),
                                            style: FilledButton.styleFrom(
                                              backgroundColor: MangoColors.primaryOrange.withValues(alpha: 0.1),
                                              foregroundColor: MangoColors.primaryOrange,
                                            ),
                                            child: const Text('Salida'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Ultimos movimientos',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: state.movements.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Sin movimientos recientes.'),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: state.movements.take(8).length,
                            separatorBuilder: (context, index) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final movement = state.movements[index];
                              final isOutflow = movement.quantity < 0;
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isOutflow
                                      ? const Color(0xFFFFEDD5)
                                      : const Color(0xFFDCFCE7),
                                  child: Icon(
                                    isOutflow
                                        ? Icons.trending_down
                                        : Icons.trending_up,
                                    color: isOutflow
                                        ? const Color(0xFFEA580C)
                                        : const Color(0xFF15803D),
                                  ),
                                ),
                                title: Text(movement.itemName),
                                subtitle: Text(
                                  '${movement.warehouseName} · ${movement.movementType} · ${DateFormat('dd/MM/yyyy HH:mm').format(movement.createdAt)}',
                                ),
                                trailing: Text(
                                  movement.quantity.toStringAsFixed(2),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: isOutflow
                                        ? const Color(0xFFB91C1C)
                                        : const Color(0xFF15803D),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _showCreateItemDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _InventoryItemDialog(
        title: 'Nuevo insumo',
        onSubmit: (payload) async {
          await ref
              .read(inventoryViewModelProvider)
              .createItem(
                name: payload.name,
                sku: payload.sku,
                description: payload.description,
                unit: payload.unit,
                cost: payload.cost,
                minStock: payload.minStock,
                maxStock: payload.maxStock,
                initialStock: payload.initialStock,
              );
        },
      ),
    );
  }

  Future<void> _showEditItemDialog(
    BuildContext context,
    InventoryItemSummary item,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _InventoryItemDialog(
        title: 'Editar insumo',
        initialItem: item,
        onSubmit: (payload) async {
          await ref
              .read(inventoryViewModelProvider)
              .updateItem(
                itemId: item.id,
                name: payload.name,
                sku: payload.sku,
                description: payload.description,
                unit: payload.unit,
                cost: payload.cost,
                minStock: payload.minStock,
                maxStock: payload.maxStock,
                isActive: payload.isActive,
              );
        },
      ),
    );
  }

  Future<void> _showOutflowDialog(
    BuildContext context, {
    required InventoryItemSummary initialItem,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _InventoryOutflowDialog(
        items: ref.read(inventoryViewModelProvider).state.items,
        initialItemId: initialItem.id,
        onSubmit: (itemId, quantity, notes) async {
          await ref
              .read(inventoryViewModelProvider)
              .registerOutflow(
                itemId: itemId,
                quantity: quantity,
                notes: notes,
              );
        },
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: MangoColors.muted,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemDialogPayload {
  final String name;
  final String? sku;
  final String? description;
  final String unit;
  final double cost;
  final double minStock;
  final double? maxStock;
  final double initialStock;
  final bool isActive;

  const _ItemDialogPayload({
    required this.name,
    required this.sku,
    required this.description,
    required this.unit,
    required this.cost,
    required this.minStock,
    required this.maxStock,
    required this.initialStock,
    required this.isActive,
  });
}

class _InventoryItemDialog extends StatefulWidget {
  final String title;
  final InventoryItemSummary? initialItem;
  final Future<void> Function(_ItemDialogPayload payload) onSubmit;

  const _InventoryItemDialog({
    required this.title,
    required this.onSubmit,
    this.initialItem,
  });

  @override
  State<_InventoryItemDialog> createState() => _InventoryItemDialogState();
}

class _InventoryItemDialogState extends State<_InventoryItemDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _skuController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _unitController;
  late final TextEditingController _costController;
  late final TextEditingController _minStockController;
  late final TextEditingController _maxStockController;
  late final TextEditingController _initialStockController;
  String _selectedPresentation = 'unidad';
  bool _isActive = true;
  bool _saving = false;

  final List<String> _presentationOptions = [
    'unidad',
    'lb',
    'kg',
    'oz',
    'gr',
    'gal',
    'lt',
    'ml',
    'caja',
    'paquete',
    'botella',
    'saco',
    'lata',
    'porcion',
    'bandeja',
  ];

  @override
  void initState() {
    super.initState();
    final item = widget.initialItem;
    _nameController = TextEditingController(text: item?.name ?? '');
    _skuController = TextEditingController(text: item?.sku ?? '');
    _descriptionController = TextEditingController(
      text: item?.description ?? '',
    );
    _unitController = TextEditingController(text: item?.unit ?? 'unidad');
    _selectedPresentation = (item?.unit ?? 'unidad').toLowerCase();
    
    // Si la unidad actual no esta en las opciones, la agregamos temporalmente
    if (!_presentationOptions.contains(_selectedPresentation)) {
      _presentationOptions.add(_selectedPresentation);
    }
    
    _costController = TextEditingController(
      text: item == null ? '' : item.cost.toStringAsFixed(2),
    );
    _minStockController = TextEditingController(
      text: item == null ? '' : item.minStock.toStringAsFixed(2),
    );
    _maxStockController = TextEditingController(
      text: item?.maxStock?.toStringAsFixed(2) ?? '',
    );
    _initialStockController = TextEditingController();
    _isActive = item?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _skuController.dispose();
    _descriptionController.dispose();
    _unitController.dispose();
    _costController.dispose();
    _minStockController.dispose();
    _maxStockController.dispose();
    _initialStockController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: MangoColors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: Text(
        widget.title,
        style: const TextStyle(
          fontWeight: FontWeight.w800, 
          fontSize: 22,
          color: MangoColors.darkGray,
        ),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(_nameController, 'Nombre'),
              const SizedBox(height: 12),
              _field(_skuController, 'SKU'),
              const SizedBox(height: 12),
              _field(_descriptionController, 'Descripcion'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _selectedPresentation,
                      dropdownColor: MangoColors.white,
                      decoration: InputDecoration(
                        labelText: 'Presentacion',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: MangoColors.cardBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: MangoColors.primaryOrange, width: 2),
                        ),
                      ),
                      items: _presentationOptions
                          .map(
                            (opt) => DropdownMenuItem(
                              value: opt,
                              child: Text(opt),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() => _selectedPresentation = val);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _costController,
                      'Costo',
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
                    child: _field(
                      _minStockController,
                      'Stock minimo',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _field(
                      _maxStockController,
                      'Stock maximo',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.initialItem == null) ...[
                const SizedBox(height: 12),
                _field(
                  _initialStockController,
                  'Stock inicial',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _isActive,
                  activeColor: MangoColors.primaryOrange,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Insumo activo'),
                  onChanged: (value) => setState(() => _isActive = value),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text(
            'Cancelar',
            style: TextStyle(color: MangoColors.muted),
          ),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: Text(
            _saving ? 'Guardando...' : 'Guardar',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: MangoColors.muted),
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: MangoColors.cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: MangoColors.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: MangoColors.primaryOrange, width: 2),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    double parse(String value) => double.tryParse(value.trim()) ?? 0;
    final maxStockRaw = _maxStockController.text.trim();

    setState(() => _saving = true);
    try {
      await widget.onSubmit(
        _ItemDialogPayload(
          name: name,
          sku: _skuController.text.trim().isEmpty
              ? null
              : _skuController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          unit: _selectedPresentation,
          cost: parse(_costController.text),
          minStock: parse(_minStockController.text),
          maxStock: maxStockRaw.isEmpty ? null : parse(maxStockRaw),
          initialStock: parse(_initialStockController.text),
          isActive: _isActive,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

class _InventoryOutflowDialog extends StatefulWidget {
  final List<InventoryItemSummary> items;
  final String initialItemId;
  final Future<void> Function(String itemId, double quantity, String? notes)
  onSubmit;

  const _InventoryOutflowDialog({
    required this.items,
    required this.initialItemId,
    required this.onSubmit,
  });

  @override
  State<_InventoryOutflowDialog> createState() =>
      _InventoryOutflowDialogState();
}

class _InventoryOutflowDialogState extends State<_InventoryOutflowDialog> {
  late String _selectedItemId;
  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedItemId = widget.initialItemId;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar salida de inventario'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _selectedItemId,
              decoration: InputDecoration(
                labelText: 'Insumo',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              items: widget.items
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(item.name),
                    ),
                  )
                  .toList(growable: false),
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() => _selectedItemId = value);
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _quantityController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Cantidad',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Motivo / notas',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Guardando...' : 'Registrar'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final quantity = double.tryParse(_quantityController.text.trim()) ?? 0;
    if (quantity <= 0) return;

    setState(() => _saving = true);
    try {
      await widget.onSubmit(
        _selectedItemId,
        quantity,
        _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}
