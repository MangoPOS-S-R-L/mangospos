import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../services/inventory_scan.dart';
import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/inventory/unit_conversion.dart';
import '../../../core/theme/app_shadows.dart';
import 'widgets/inventory_back_button.dart';
import 'widgets/unit_dropdown.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

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
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: state.loading && state.items.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppColors.primary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: InventoryBackButton(),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Inventario',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Insumos, stock actual y salidas manuales',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
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
                              foregroundColor: AppColors.primary,
                              side: BorderSide(color: AppColors.primary),
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
                              backgroundColor: AppColors.primary,
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
                        color: AppColors.destructive.withValues(alpha:0.05),
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border: Border.all(color: AppColors.destructive.withValues(alpha:0.2)),
                      ),
                      child: Text(
                        state.error!,
                        style: TextStyle(color: AppColors.destructive),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) => ref
                              .read(inventoryViewModelProvider)
                              .search(value),
                          decoration: InputDecoration(
                            hintText: 'Buscar por nombre, SKU o descripcion',
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.card),
                            ),
                            filled: true,
                            fillColor: AppColors.card,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 1,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(state.selectedWarehouseId),
                          isExpanded: true,
                          initialValue: state.selectedWarehouseId,
                          decoration: InputDecoration(
                            labelText: 'Almacen',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(AppRadius.card),
                            ),
                            filled: true,
                            fillColor: AppColors.card,
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
                          backgroundColor: AppColors.primary.withValues(alpha:0.1),
                          foregroundColor: AppColors.primary,
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
                        color: AppColors.primary,
                      ),
                      _SummaryCard(
                        title: 'Stock bajo',
                        value:
                            '${state.items.where((item) => item.isLowStock).length}',
                        color: AppColors.warning,
                      ),
                      _SummaryCard(
                        title: 'Valor inventario',
                        value: currency.format(
                          state.items.fold<double>(
                            0,
                            (sum, item) => sum + (item.stock * item.cost),
                          ),
                        ),
                        color: AppColors.success,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppShadows.cardElevated,
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Text(
                                  'INSUMO',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'STOCK',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'UNIDAD BASE',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  'COSTO',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.mutedForeground,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 120),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        if (state.items.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.inventory_2_outlined, size: 32, color: AppColors.mutedForeground),
                                  const SizedBox(height: 8),
                                  Text(
                                    'No hay insumos registrados en este almacen.',
                                    style: TextStyle(color: AppColors.mutedForeground),
                                  ),
                                ],
                              ),
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
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              color: AppColors.foreground,
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
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: AppColors.mutedForeground,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        item.stock.toStringAsFixed(2),
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: item.isLowStock
                                              ? AppColors.warning
                                              : AppColors.foreground,
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
                                      width: 168,
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
                                          IconButton(
                                            tooltip: 'Eliminar insumo',
                                            onPressed: state.saving
                                                ? null
                                                : () => _showDeleteItemDialog(
                                                    context,
                                                    item,
                                                  ),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Color(0xFFEF4444),
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
                                              backgroundColor: AppColors.primary.withValues(alpha:0.1),
                                              foregroundColor: AppColors.primary,
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
                  Text(
                    'Ultimos movimientos',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: AppColors.border),
                      boxShadow: AppShadows.cardElevated,
                    ),
                    child: state.movements.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.swap_vert_outlined, size: 32, color: AppColors.mutedForeground),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Sin movimientos recientes.',
                                    style: TextStyle(color: AppColors.mutedForeground),
                                  ),
                                ],
                              ),
                            ),
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
                                      ? AppColors.warning.withValues(alpha:0.1)
                                      : AppColors.success.withValues(alpha:0.1),
                                  child: Icon(
                                    isOutflow
                                        ? Icons.trending_down
                                        : Icons.trending_up,
                                    color: isOutflow
                                        ? AppColors.primary
                                        : AppColors.success,
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
                                        ? AppColors.destructive
                                        : AppColors.success,
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
                purchaseUnit: payload.purchaseUnit,
                packSize: payload.packSize,
                conversionUnit: payload.conversionUnit,
                conversionFactor: payload.conversionFactor,
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
                purchaseUnit: payload.purchaseUnit,
                packSize: payload.packSize,
                conversionUnit: payload.conversionUnit,
                conversionFactor: payload.conversionFactor,
              );
        },
      ),
    );
  }

  Future<void> _showDeleteItemDialog(
    BuildContext context,
    InventoryItemSummary item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text('Eliminar insumo'),
        content: Text(
          'Se eliminará "${item.name}" de la lista. Su historial de '
          'movimientos y recetas se conservan; puedes reactivarlo luego. '
          '¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(inventoryViewModelProvider).deactivateItem(item.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(content: Text('"${item.name}" eliminado')),
      );
    }
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
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.mutedForeground,
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
  final String? purchaseUnit;
  final double packSize;
  // Equivalencia propia: null = no tocarla; '' = borrarla.
  final String? conversionUnit;
  final double? conversionFactor;

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
    required this.purchaseUnit,
    required this.packSize,
    this.conversionUnit,
    this.conversionFactor,
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
  // Conversión de empaque: se compra en `purchase_unit` (ej. botella) que
  // contiene `pack_size` unidades base (ej. 700 ml). Vacío = sin conversión.
  late final TextEditingController _purchaseUnitController;
  late final TextEditingController _packSizeController;
  String _selectedPresentation = 'unidad';
  bool _isActive = true;
  bool _saving = false;
  // Secciones del catálogo según lo GUARDADO: una unidad fuera del catálogo
  // queda en «Actual» para no perderla al editar.
  late final List<UnitSection> _baseSections;
  late final List<UnitSection> _purchaseSections;
  // Equivalencia propia: 1 [unidad base] = N [otra unidad] (1 ea = 200 g).
  late final TextEditingController _conversionFactorController;
  String _conversionUnit = '';
  // Si la ficha llegó sabiendo qué equivalencia tenía. Si no (esquema viejo)
  // y nadie la toca, al guardar no se manda: así no se borra una que exista.
  late final bool _conversionKnown;
  bool _conversionTouched = false;

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
    _baseSections = baseUnitSections(current: item?.unit);
    _purchaseSections = purchaseUnitSections(current: item?.purchaseUnit);
    // Antes la unidad se pasaba a minúsculas y un «L» se guardaba «l». Ahora
    // arranca como su código del catálogo («gr» → g) o, si no está en el
    // catálogo, tal cual.
    _selectedPresentation = unitSelectionValue(
      _baseSections,
      item?.unit,
      fallback: 'unidad',
    );

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
    _purchaseUnitController = TextEditingController(
      text: unitSelectionValue(
        _purchaseSections,
        item?.purchaseUnit,
        fallback: '',
      ),
    );
    _conversionKnown = item == null || item.conversionKnown;
    _conversionUnit = item?.conversionUnit ?? '';
    _conversionFactorController = TextEditingController(
      text: (item != null && item.conversionFactor > 0)
          ? _trimNum(item.conversionFactor)
          : '',
    );
    _packSizeController = TextEditingController(
      text: (item != null && item.packSize > 1)
          ? _trimNum(item.packSize)
          : '',
    );
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
    _purchaseUnitController.dispose();
    _packSizeController.dispose();
    _conversionFactorController.dispose();
    super.dispose();
  }

  String _trimNum(double v) {
    final s = v.toStringAsFixed(2);
    if (s.endsWith('.00')) return s.substring(0, s.length - 3);
    if (s.endsWith('0')) return s.substring(0, s.length - 1);
    return s;
  }

  /// Contenido que sale solo cuando se compra en una medida convertible
  /// (1 lb = 453.59 g, 1 gal = 3785.41 mL).
  double? get _autoPackSize {
    final pu = _purchaseUnitController.text.trim();
    if (pu.isEmpty) return null;
    return autoPackSize(
      purchaseUnit: pu,
      baseUnit: _selectedPresentation,
      conversionUnit: _conversion?.unit,
      conversionFactor: _conversion?.factor,
    );
  }

  double get _packSizeValue => resolvePackSize(
        purchaseUnit: _purchaseUnitController.text,
        baseUnit: _selectedPresentation,
        conversionUnit: _conversion?.unit,
        conversionFactor: _conversion?.factor,
        manual: double.tryParse(
          _packSizeController.text.trim().replaceAll(',', '.'),
        ),
      );

  double? get _conversionFactorValue => double.tryParse(
        _conversionFactorController.text.trim().replaceAll(',', '.'),
      );

  List<UnitSection> get _conversionSections => conversionUnitSections(
        baseUnit: _selectedPresentation,
        current: _conversionUnit,
      );

  /// La equivalencia válida para la base elegida, o null.
  ({String unit, double factor})? get _conversion => resolveItemConversion(
        baseUnit: _selectedPresentation,
        unit: _conversionUnit,
        factor: _conversionFactorValue,
      );

  /// Qué mandar al guardar: null = no tocarla (la ficha llegó sin saber cuál
  /// tenía y nadie la cambió); '' = borrarla; si no, la unidad.
  String? get _conversionUnitForSave {
    final conversion = _conversion;
    if (conversion != null) return conversion.unit;
    if (!_conversionKnown && !_conversionTouched) return null;
    return '';
  }

  /// Texto bajo la equivalencia: «1 ea = 200 g», o por qué no se guardará.
  String? _conversionHint() {
    final conversion = _conversion;
    if (conversion != null) {
      return conversionLabel(
        baseUnit: _selectedPresentation,
        unit: conversion.unit,
        factor: conversion.factor,
      );
    }
    if (_conversionUnit.trim().isEmpty) return null;
    if ((_conversionFactorValue ?? 0) <= 0) {
      return '¿Cuánto equivale 1 ${unitShortLabel(_selectedPresentation)}?';
    }
    return 'No aplica con esta unidad base: no se guardará';
  }

  /// Texto bajo el bloque de empaque: «700 mL / Botella» + costo por base.
  String? _packPreview() {
    final pu = _purchaseUnitController.text.trim();
    final size = _packSizeValue;
    if (pu.isEmpty || size == 1) return null;
    final baseLabel = unitShortLabel(_selectedPresentation);
    final cost = double.tryParse(_costController.text.trim().replaceAll(',', '.'));
    final perBase = (cost != null && cost > 0)
        ? '  ·  costo ${_trimNum(cost / size)} / $baseLabel'
        : '';
    final pack = packLabel(
      packSize: size,
      baseUnit: _selectedPresentation,
      purchaseUnit: pu,
    );
    return '$pack$perBase';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.lg)),
      title: Text(
        widget.title,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 22,
          color: AppColors.foreground,
        ),
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      content: SizedBox(
        // Responsivo: en pantallas chicas el diálogo ocupa el ancho
        // disponible (evita que se corten campos/botones); en grandes, 460.
        width: MediaQuery.of(context).size.width < 520 ? double.maxFinite : 460,
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
                      initialValue: _selectedPresentation,
                      dropdownColor: AppColors.card,
                      decoration: InputDecoration(
                        labelText: 'Unidad base',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          borderSide: BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.card),
                          borderSide: BorderSide(color: AppColors.primary, width: 2),
                        ),
                      ),
                      isExpanded: true,
                      items: unitDropdownItems(_baseSections),
                      selectedItemBuilder:
                          unitDropdownSelectedBuilder(_baseSections),
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
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Conversión de empaque: comprar en botella/caja, consumir en la
              // unidad base. Ej: 1 botella = 700 ml. Vacío = sin conversión.
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _purchaseUnitController.text,
                      isExpanded: true,
                      dropdownColor: AppColors.card,
                      decoration: _dropdownDecoration('Unidad de compra'),
                      items: unitDropdownItems(
                        _purchaseSections,
                        emptyLabel: 'Sin empaque',
                      ),
                      selectedItemBuilder: unitDropdownSelectedBuilder(
                        _purchaseSections,
                        emptyLabel: 'Sin empaque',
                      ),
                      onChanged: (v) => setState(
                        () => _purchaseUnitController.text = v ?? '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _autoPackSize != null
                        ? InputDecorator(
                            decoration:
                                _dropdownDecoration('Contenido por empaque'),
                            child: Text(
                              '${formatUnitQty(_autoPackSize!)} '
                              '${unitShortLabel(_selectedPresentation)} · automático',
                              style: TextStyle(
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          )
                        : _field(
                            _packSizeController,
                            'Contenido por empaque',
                            hint: '24',
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                  ),
                ],
              ),
              if (_packPreview() != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _packPreview()!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              // Equivalencia propia: cuánto pesa o mide UNA unidad base. Con
              // ella una receta en gramos descuenta de un insumo que se cuenta
              // por unidad (1 ea = 200 g de aguacate).
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '1 ${unitShortLabel(_selectedPresentation)} =',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: _field(
                      _conversionFactorController,
                      'Cantidad',
                      hint: '200',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) =>
                          setState(() => _conversionTouched = true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      // Las opciones dependen de la base: al cambiarla, la key
                      // rehace el campo con la lista nueva.
                      key: ValueKey('conversion|$_selectedPresentation'),
                      initialValue: unitSelectionValue(
                        _conversionSections,
                        _conversionUnit,
                        fallback: '',
                      ),
                      isExpanded: true,
                      dropdownColor: AppColors.card,
                      decoration: _dropdownDecoration('Equivale a (opcional)'),
                      items: unitDropdownItems(
                        _conversionSections,
                        emptyLabel: 'Sin equivalencia',
                      ),
                      selectedItemBuilder: unitDropdownSelectedBuilder(
                        _conversionSections,
                        emptyLabel: 'Sin equivalencia',
                      ),
                      onChanged: (v) => setState(() {
                        _conversionUnit = v ?? '';
                        _conversionTouched = true;
                      }),
                    ),
                  ),
                ],
              ),
              if (_conversionHint() != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _conversionHint()!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _conversion != null
                          ? AppColors.primary
                          : AppColors.mutedForeground,
                    ),
                  ),
                ),
              ],
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
                  activeThumbColor: AppColors.primary,
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
          child: Text(
            'Cancelar',
            style: TextStyle(color: AppColors.mutedForeground),
          ),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
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

  /// Mismo borde que el selector de unidad base, para los campos que no son
  /// texto (unidad de compra, contenido automático).
  InputDecoration _dropdownDecoration(String label) {
    return InputDecoration(
      labelText: label,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        borderSide: BorderSide(color: AppColors.primary, width: 2),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    void Function(String)? onChanged,
    String? hint,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: AppColors.mutedForeground),
        filled: true,
        fillColor: AppColors.muted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          borderSide: BorderSide(color: AppColors.primary, width: 2),
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
          purchaseUnit: _purchaseUnitController.text.trim().isEmpty
              ? null
              : _purchaseUnitController.text.trim(),
          packSize: _packSizeValue,
          conversionUnit: _conversionUnitForSave,
          conversionFactor: _conversion?.factor,
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
  final TextEditingController _searchController = TextEditingController();
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
    _searchController.dispose();
    _quantityController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  List<InventoryItemSummary> get _filteredItems {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items
        .where(
          (i) =>
              i.name.toLowerCase().contains(q) ||
              i.sku.toLowerCase().contains(q) ||
              i.description.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;
    return InventoryScanListener(
      enabled: true,
      items: widget.items,
      // En una salida, escanear elige el insumo y lo deja visible: la
      // cantidad y el motivo los pone la persona, que es el punto de
      // registrar una merma.
      onItem: (item) {
        _searchController.text = item.name;
        setState(() => _selectedItemId = item.id);
      },
      child: AlertDialog(
      title: const Text('Registrar salida de inventario'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: 'Buscar insumo...',
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              height: 200,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No se encontraron insumos.',
                        style: TextStyle(color: AppColors.mutedForeground),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        final selected = item.id == _selectedItemId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          selectedTileColor:
                              AppColors.primary.withValues(alpha: 0.08),
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (item.sku.isNotEmpty) item.sku,
                              'Stock: ${item.stock.toStringAsFixed(2)} ${item.unit}',
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: selected
                              ? Icon(
                                  Icons.check_circle,
                                  color: AppColors.primary,
                                  size: 20,
                                )
                              : null,
                          onTap: _saving
                              ? null
                              : () => setState(
                                    () => _selectedItemId = item.id,
                                  ),
                        );
                      },
                    ),
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
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Motivo / notas',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
              ),
            ),
          ],
          ),
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
      ),
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
