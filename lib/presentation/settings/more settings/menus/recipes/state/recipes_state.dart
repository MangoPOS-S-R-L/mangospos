class RecipeMenuProduct {
  final String id;
  final String name;
  final bool isActive;

  const RecipeMenuProduct({
    required this.id,
    required this.name,
    required this.isActive,
  });

  factory RecipeMenuProduct.fromMap(Map<String, dynamic> map) {
    return RecipeMenuProduct(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Producto',
      isActive: map['is_active'] != false,
    );
  }
}

class RecipeInventoryItem {
  final String id;
  final String name;
  final String sku;
  final String unit;
  final double cost;
  final bool isActive;

  /// Unidad de compra (ej. botella) y su contenido en unidad base
  /// (`packSize`, ej. 700 ml). Permiten que una receta exprese cantidades en
  /// la unidad de compra (1 botella) o en otra de la familia (oz) y se
  /// conviertan a la unidad base al guardar. Ver core/inventory/unit_conversion.
  final String? purchaseUnit;
  final double packSize;

  const RecipeInventoryItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.unit,
    required this.cost,
    required this.isActive,
    this.purchaseUnit,
    this.packSize = 1,
  });

  factory RecipeInventoryItem.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    final rawPack = toDouble(map['pack_size']);
    final pu = map['purchase_unit']?.toString().trim();
    return RecipeInventoryItem(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Insumo',
      sku: map['sku']?.toString() ?? '',
      unit: map['unit']?.toString() ?? 'unidad',
      cost: toDouble(map['cost']),
      isActive: map['is_active'] != false,
      purchaseUnit: (pu == null || pu.isEmpty) ? null : pu,
      packSize: rawPack <= 0 ? 1 : rawPack,
    );
  }
}

class RecipeIngredientEntry {
  final String id;
  final String inventoryItemId;
  final String inventoryItemName;
  final String inventoryItemSku;
  final double quantity;
  final String unit;
  final double unitCost;

  const RecipeIngredientEntry({
    required this.id,
    required this.inventoryItemId,
    required this.inventoryItemName,
    required this.inventoryItemSku,
    required this.quantity,
    required this.unit,
    required this.unitCost,
  });

  double get totalCost => quantity * unitCost;
}

class RecipeDraftIngredient {
  final String inventoryItemId;
  final String unit;
  final double quantity;

  const RecipeDraftIngredient({
    required this.inventoryItemId,
    required this.unit,
    required this.quantity,
  });
}

class RecipeSummary {
  final String id;
  final String menuItemId;
  final String menuItemName;
  final bool menuItemIsActive;
  final double yieldQuantity;
  final String instructions;
  final DateTime createdAt;
  final List<RecipeIngredientEntry> ingredients;

  const RecipeSummary({
    required this.id,
    required this.menuItemId,
    required this.menuItemName,
    required this.menuItemIsActive,
    required this.yieldQuantity,
    required this.instructions,
    required this.createdAt,
    required this.ingredients,
  });

  double get totalCost => ingredients.fold<double>(
    0,
    (sum, ingredient) => sum + ingredient.totalCost,
  );

  double get costPerYield => yieldQuantity <= 0 ? totalCost : totalCost / yieldQuantity;
}

class RecipesState {
  final bool loading;
  final bool saving;
  final String? error;
  final String? businessId;
  final List<RecipeMenuProduct> menuProducts;
  final List<RecipeInventoryItem> inventoryItems;
  final List<RecipeSummary> recipes;

  const RecipesState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.menuProducts = const [],
    this.inventoryItems = const [],
    this.recipes = const [],
  });

  RecipesState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    String? businessId,
    List<RecipeMenuProduct>? menuProducts,
    List<RecipeInventoryItem>? inventoryItems,
    List<RecipeSummary>? recipes,
    bool clearError = false,
  }) {
    return RecipesState(
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      menuProducts: menuProducts ?? this.menuProducts,
      inventoryItems: inventoryItems ?? this.inventoryItems,
      recipes: recipes ?? this.recipes,
    );
  }
}
