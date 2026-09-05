import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../../../../core/inventory/unit_conversion.dart';
import '../../../../../../../app/router/routes.dart';
import '../../../../../../../app/theme/mango_tokens.dart';
import '../state/recipes_state.dart';
import '../viewmodel/recipes_viewmodel.dart';
import 'widgets/searchable_select_field.dart';

class RecipesView extends ConsumerStatefulWidget {
  const RecipesView({super.key});

  @override
  ConsumerState<RecipesView> createState() => _RecipesViewState();
}

class _RecipesViewState extends ConsumerState<RecipesView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(recipesViewModelProvider).init();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(recipesViewModelProvider);
    final state = vm.state;
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    final totalIngredients = state.recipes.fold<int>(
      0,
      (sum, recipe) => sum + recipe.ingredients.length,
    );
    final totalCost = state.recipes.fold<double>(
      0,
      (sum, recipe) => sum + recipe.totalCost,
    );

    return Scaffold(
      backgroundColor: MangoTokens.background,
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeaderRow(
                  onBack: () => context.go(AppRoutes.settings),
                  onRefresh: state.saving
                      ? null
                      : () => ref.read(recipesViewModelProvider).refresh(),
                  onAdd: state.saving ? null : () => _openRecipeDialog(),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _KpiCard(
                      label: 'Recetas activas',
                      value: '${state.recipes.length}',
                      valueColor: MangoTokens.foreground,
                    ),
                    _KpiCard(
                      label: 'Ingredientes ligados',
                      value: '$totalIngredients',
                      valueColor: MangoTokens.info,
                    ),
                    _KpiCard(
                      label: 'Costo teorico total',
                      value: currency.format(totalCost),
                      valueColor: MangoTokens.success,
                    ),
                  ],
                ),
                if (state.error != null) ...[
                  const SizedBox(height: 16),
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
                ],
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: MangoTokens.card,
                    borderRadius: BorderRadius.circular(MangoTokens.radius),
                    border: Border.all(color: MangoTokens.border),
                    boxShadow: MangoTokens.shadowCard,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: state.loading && state.recipes.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : state.recipes.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              'Todavia no hay recetas configuradas.',
                              style: TextStyle(color: MangoTokens.mutedForeground),
                            ),
                          )
                        : Column(
                            children: state.recipes
                                .map(
                                  (recipe) => Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: _RecipeCard(
                                      recipe: recipe,
                                      currency: currency,
                                      onEdit: state.saving
                                          ? null
                                          : () => _openRecipeDialog(
                                                initialRecipe: recipe,
                                              ),
                                      onDelete: state.saving
                                          ? null
                                          : () => _confirmDelete(recipe),
                                    ),
                                  ),
                                )
                                .toList(growable: false),
                          ),
                  ),
                ),
              ],
            ),
          ),
          if (state.loading && state.recipes.isNotEmpty)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: MangoTokens.primary,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openRecipeDialog({RecipeSummary? initialRecipe}) async {
    final state = ref.read(recipesViewModelProvider).state;
    final result = await showDialog<_RecipeFormResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecipeFormDialog(
        menuProducts: state.menuProducts,
        inventoryItems: state.inventoryItems,
        initialRecipe: initialRecipe,
      ),
    );

    if (result == null) return;

    await ref.read(recipesViewModelProvider).saveRecipe(
      menuItemId: result.menuItemId,
      yieldQuantity: result.yieldQuantity,
      instructions: result.instructions,
      ingredients: result.ingredients,
    );
  }

  Future<void> _confirmDelete(RecipeSummary recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar receta'),
        content: Text(
          'Se eliminara la receta de "${recipe.menuItemName}" y todos sus ingredientes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    await ref.read(recipesViewModelProvider).deleteRecipe(recipe.id);
  }
}

class _HeaderRow extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback? onRefresh;
  final VoidCallback? onAdd;

  const _HeaderRow({
    required this.onBack,
    required this.onRefresh,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Recetas', style: MangoTokens.h1()),
              const SizedBox(height: 2),
              Text(
                'Relaciona productos con insumos y costo teorico.',
                style: MangoTokens.subtitle(),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Nueva receta'),
        ),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _KpiCard({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MangoTokens.card,
        borderRadius: BorderRadius.circular(MangoTokens.radius),
        border: Border.all(color: MangoTokens.border),
        boxShadow: MangoTokens.shadowCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: MangoTokens.label()),
          const SizedBox(height: 8),
          Text(value, style: MangoTokens.kpiValue(color: valueColor)),
        ],
      ),
    );
  }
}

class _RecipeCard extends StatelessWidget {
  final RecipeSummary recipe;
  final NumberFormat currency;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _RecipeCard({
    required this.recipe,
    required this.currency,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MangoTokens.background,
        borderRadius: BorderRadius.circular(MangoTokens.radius),
        border: Border.all(color: MangoTokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recipe.menuItemName,
                        style: MangoTokens.body().copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        recipe.menuItemIsActive ? 'Producto activo' : 'Producto inactivo',
                        style: MangoTokens.label(
                          color: recipe.menuItemIsActive
                              ? MangoTokens.success
                              : MangoTokens.warning,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Editar'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Eliminar'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                Text('Rinde: ${recipe.yieldQuantity.toStringAsFixed(2)}'),
                Text('Ingredientes: ${recipe.ingredients.length}'),
                Text('Costo total: ${currency.format(recipe.totalCost)}'),
                Text('Costo x rendimiento: ${currency.format(recipe.costPerYield)}'),
              ],
            ),
            if (recipe.instructions.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                recipe.instructions,
                style: MangoTokens.body(color: MangoTokens.mutedForeground),
              ),
            ],
            const SizedBox(height: 16),
            ...recipe.ingredients.map(
              (ingredient) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        ingredient.inventoryItemSku.trim().isEmpty
                            ? ingredient.inventoryItemName
                            : '${ingredient.inventoryItemName} · ${ingredient.inventoryItemSku}',
                      ),
                    ),
                    Text(
                      '${ingredient.quantity.toStringAsFixed(2)} ${ingredient.unit}',
                      style: MangoTokens.label(),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      currency.format(ingredient.totalCost),
                      style: MangoTokens.label(color: MangoTokens.foreground),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipeFormResult {
  final String menuItemId;
  final double yieldQuantity;
  final String? instructions;
  final List<RecipeDraftIngredient> ingredients;

  const _RecipeFormResult({
    required this.menuItemId,
    required this.yieldQuantity,
    required this.instructions,
    required this.ingredients,
  });
}

class _RecipeFormDialog extends StatefulWidget {
  final List<RecipeMenuProduct> menuProducts;
  final List<RecipeInventoryItem> inventoryItems;
  final RecipeSummary? initialRecipe;

  const _RecipeFormDialog({
    required this.menuProducts,
    required this.inventoryItems,
    this.initialRecipe,
  });

  @override
  State<_RecipeFormDialog> createState() => _RecipeFormDialogState();
}

class _RecipeFormDialogState extends State<_RecipeFormDialog> {
  final _yieldController = TextEditingController(text: '1');
  final _instructionsController = TextEditingController();
  String? _menuItemId;
  final List<_IngredientDraftRow> _rows = <_IngredientDraftRow>[];

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRecipe;
    _menuItemId = initial?.menuItemId ??
        (widget.menuProducts.isEmpty ? null : widget.menuProducts.first.id);
    if (initial != null) {
      _yieldController.text = initial.yieldQuantity.toStringAsFixed(2);
      _instructionsController.text = initial.instructions;
      for (final ingredient in initial.ingredients) {
        _rows.add(
          _IngredientDraftRow(
            inventoryItemId: ingredient.inventoryItemId,
            quantity: ingredient.quantity.toStringAsFixed(2),
            unit: ingredient.unit,
          ),
        );
      }
    }
    if (_rows.isEmpty) {
      _rows.add(_IngredientDraftRow());
    }
  }

  @override
  void dispose() {
    _yieldController.dispose();
    _instructionsController.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initialRecipe == null ? 'Nueva receta' : 'Editar receta'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SearchableSelectField<RecipeMenuProduct>(
                labelText: 'Producto',
                hintText: 'Busca el producto por nombre...',
                items: widget.menuProducts,
                selected: _productById(_menuItemId),
                labelOf: (product) => product.name,
                subtitleOf: (product) =>
                    product.isActive ? null : 'Producto inactivo',
                // El producto de una receta ya creada no se puede cambiar.
                enabled: widget.initialRecipe == null,
                onSelected: (product) =>
                    setState(() => _menuItemId = product.id),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _yieldController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rendimiento'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _instructionsController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Instrucciones',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Ingredientes',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextButton.icon(
                    onPressed: _addRow,
                    icon: const Icon(Icons.add),
                    label: const Text('Agregar'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._buildRows(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Guardar'),
        ),
      ],
    );
  }

  List<Widget> _buildRows() {
    return List<Widget>.generate(_rows.length, (index) {
      final row = _rows[index];
      return Padding(
        key: row.key,
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: SearchableSelectField<RecipeInventoryItem>(
                labelText: 'Insumo',
                hintText: 'Busca por nombre o SKU...',
                items: widget.inventoryItems,
                selected: _itemById(row.inventoryItemId),
                labelOf: (item) => item.name,
                subtitleOf: (item) => item.sku.trim().isEmpty
                    ? item.unit
                    : '${item.sku} · ${item.unit}',
                keywordsOf: (item) => [item.sku],
                onSelected: (item) {
                  setState(() {
                    row.inventoryItemId = item.id;
                    // Al cambiar de insumo, fijamos la unidad a su unidad base
                    // (las opciones del selector dependen del insumo).
                    row.unit.text = item.unit;
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: row.quantity,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Cantidad',
                  // Se puede escribir en oz/ml/botella; se convierte a la
                  // unidad base del insumo al guardar.
                  helperText: 'se convierte a la unidad base',
                  helperMaxLines: 2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Builder(
                builder: (_) {
                  final options = _unitOptionsFor(row.inventoryItemId);
                  final current = row.unit.text.trim();
                  final value = options.contains(current)
                      ? current
                      : (options.isNotEmpty ? options.first : null);
                  return DropdownButtonFormField<String>(
                    initialValue: value,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Unidad'),
                    items: options
                        .map(
                          (u) => DropdownMenuItem(value: u, child: Text(u)),
                        )
                        .toList(growable: false),
                    onChanged: (u) {
                      if (u != null) setState(() => row.unit.text = u);
                    },
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _rows.length == 1 ? null : () => _removeRow(index),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      );
    });
  }

  void _addRow() {
    setState(() {
      _rows.add(_IngredientDraftRow());
    });
  }

  void _removeRow(int index) {
    setState(() {
      final removed = _rows.removeAt(index);
      removed.dispose();
    });
  }

  RecipeMenuProduct? _productById(String? id) {
    if (id == null || id.isEmpty) return null;
    return widget.menuProducts
        .where((product) => product.id == id)
        .cast<RecipeMenuProduct?>()
        .firstWhere((product) => product != null, orElse: () => null);
  }

  RecipeInventoryItem? _itemById(String? id) {
    if (id == null || id.isEmpty) return null;
    return widget.inventoryItems
        .where((item) => item.id == id)
        .cast<RecipeInventoryItem?>()
        .firstWhere((item) => item != null, orElse: () => null);
  }

  /// Unidades ofrecidas para un ingrediente: su unidad base + las de su misma
  /// familia (oz/ml/L… ó g/kg) + la unidad de compra del insumo (ej. botella).
  List<String> _unitOptionsFor(String? itemId) {
    final item = _itemById(itemId);
    final base = (item?.unit.trim().isNotEmpty ?? false)
        ? item!.unit.trim()
        : 'unidad';
    final opts = <String>{base};
    switch (unitFamily(base)) {
      case UnitFamily.volume:
        opts.addAll(const ['ml', 'cl', 'L', 'oz']);
        break;
      case UnitFamily.weight:
        // `oz` va acá aunque su familia por defecto sea volumen: contra un
        // insumo de peso la conversión la resuelve como onza de peso. Es el
        // caso de la pechuga — se compra por libra y la receta la pide en oz.
        opts.addAll(const ['g', 'kg', 'lb', 'oz']);
        break;
      case UnitFamily.count:
      case UnitFamily.unknown:
        break;
    }
    final pu = item?.purchaseUnit?.trim();
    if (pu != null && pu.isNotEmpty) opts.add(pu);
    return opts.toList(growable: false);
  }

  /// Convierte `qty` (en `fromUnit`) a la unidad base del insumo:
  /// 1) si es la unidad de compra → ×pack_size; 2) si es de la misma familia
  /// → factor; 3) si no → se asume ya en unidad base.
  double _toBaseQty(double qty, String fromUnit, RecipeInventoryItem item) {
    final from = fromUnit.trim();
    if (from.isEmpty) return qty;
    final pu = item.purchaseUnit?.trim();
    if (pu != null && pu.isNotEmpty && from.toLowerCase() == pu.toLowerCase()) {
      return qty * (item.packSize <= 0 ? 1 : item.packSize);
    }
    final converted = convertUnit(qty, from, item.unit);
    return converted ?? qty;
  }

  void _submit() {
    final menuItemId = _menuItemId;
    if (menuItemId == null || menuItemId.isEmpty) return;

    final yieldQuantity = double.tryParse(_yieldController.text.trim()) ?? 0;
    if (yieldQuantity <= 0) return;

    // Convertimos cada ingrediente a la UNIDAD BASE del insumo al guardar, para
    // que el descuento de stock (que opera en unidad base) sea correcto.
    final ingredients = <RecipeDraftIngredient>[];
    for (final row in _rows) {
      final id = row.inventoryItemId;
      if (id == null || id.isEmpty) continue;
      final qty = double.tryParse(row.quantity.text.trim()) ?? 0;
      if (qty <= 0) continue;
      final item = _itemById(id);
      final baseUnit = (item?.unit.trim().isNotEmpty ?? false)
          ? item!.unit.trim()
          : 'unidad';
      final fromUnit =
          row.unit.text.trim().isEmpty ? baseUnit : row.unit.text.trim();
      final baseQty = item == null ? qty : _toBaseQty(qty, fromUnit, item);
      ingredients.add(
        RecipeDraftIngredient(
          inventoryItemId: id,
          unit: baseUnit,
          quantity: baseQty,
        ),
      );
    }

    if (ingredients.isEmpty) return;

    Navigator.of(context).pop(
      _RecipeFormResult(
        menuItemId: menuItemId,
        yieldQuantity: yieldQuantity,
        instructions: _instructionsController.text.trim().isEmpty
            ? null
            : _instructionsController.text.trim(),
        ingredients: ingredients,
      ),
    );
  }
}

class _IngredientDraftRow {
  /// Identidad estable de la fila: los buscadores mantienen su texto en el
  /// estado del widget, asi que al borrar una fila el resto debe conservar
  /// el suyo en vez de correrse por indice.
  final Key key = UniqueKey();
  String? inventoryItemId;
  final TextEditingController quantity;
  final TextEditingController unit;

  _IngredientDraftRow({
    this.inventoryItemId,
    String quantity = '',
    String unit = '',
  }) : quantity = TextEditingController(text: quantity),
       unit = TextEditingController(text: unit);

  void dispose() {
    quantity.dispose();
    unit.dispose();
  }
}
