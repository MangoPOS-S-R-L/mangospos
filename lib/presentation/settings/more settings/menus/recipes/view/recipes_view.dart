import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../../../../app/router/routes.dart';
import '../../../../../../../app/theme/mango_tokens.dart';
import '../state/recipes_state.dart';
import '../viewmodel/recipes_viewmodel.dart';

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
              DropdownButtonFormField<String>(
                initialValue: _menuItemId,
                decoration: const InputDecoration(labelText: 'Producto'),
                items: widget.menuProducts
                    .map(
                      (product) => DropdownMenuItem(
                        value: product.id,
                        child: Text(product.name),
                      ),
                    )
                    .toList(growable: false),
                onChanged: widget.initialRecipe != null
                    ? null
                    : (value) => setState(() => _menuItemId = value),
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
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: DropdownButtonFormField<String>(
                initialValue: row.inventoryItemId,
                decoration: const InputDecoration(labelText: 'Insumo'),
                items: widget.inventoryItems
                    .map(
                      (item) => DropdownMenuItem(
                        value: item.id,
                        child: Text(
                          item.sku.trim().isEmpty
                              ? item.name
                              : '${item.name} · ${item.sku}',
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  row.inventoryItemId = value;
                  final inventoryItem = widget.inventoryItems
                      .where((item) => item.id == value)
                      .cast<RecipeInventoryItem?>()
                      .firstWhere((item) => item != null, orElse: () => null);
                  if (inventoryItem != null && row.unit.text.trim().isEmpty) {
                    row.unit.text = inventoryItem.unit;
                  }
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
                  // La cantidad SIEMPRE va en la unidad base del insumo (ej.
                  // ml), no en la unidad de compra (botella).
                  helperText: 'en unidad base del insumo',
                  helperMaxLines: 2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: row.unit,
                decoration: const InputDecoration(labelText: 'Unidad base'),
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

  void _submit() {
    final menuItemId = _menuItemId;
    if (menuItemId == null || menuItemId.isEmpty) return;

    final yieldQuantity = double.tryParse(_yieldController.text.trim()) ?? 0;
    if (yieldQuantity <= 0) return;

    final ingredients = _rows
        .map((row) => row.toDraftIngredient())
        .where((row) => row != null)
        .cast<RecipeDraftIngredient>()
        .toList(growable: false);

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
  String? inventoryItemId;
  final TextEditingController quantity;
  final TextEditingController unit;

  _IngredientDraftRow({
    this.inventoryItemId,
    String quantity = '',
    String unit = '',
  }) : quantity = TextEditingController(text: quantity),
       unit = TextEditingController(text: unit);

  RecipeDraftIngredient? toDraftIngredient() {
    if (inventoryItemId == null || inventoryItemId!.isEmpty) return null;
    final parsedQuantity = double.tryParse(quantity.text.trim()) ?? 0;
    if (parsedQuantity <= 0) return null;
    final normalizedUnit = unit.text.trim();
    return RecipeDraftIngredient(
      inventoryItemId: inventoryItemId!,
      unit: normalizedUnit.isEmpty ? 'unidad' : normalizedUnit,
      quantity: parsedQuantity,
    );
  }

  void dispose() {
    quantity.dispose();
    unit.dispose();
  }
}
