class ModifierProduct {
  final String id;
  final String name;
  final bool isActive;

  const ModifierProduct({
    required this.id,
    required this.name,
    required this.isActive,
  });

  factory ModifierProduct.fromMap(Map<String, dynamic> map) {
    return ModifierProduct(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Producto',
      isActive: map['is_active'] != false,
    );
  }
}

class ModifierGroupSummary {
  final String id;
  final String name;
  final int minSelect;
  final int maxSelect;
  final bool isActive;
  final DateTime createdAt;

  const ModifierGroupSummary({
    required this.id,
    required this.name,
    required this.minSelect,
    required this.maxSelect,
    required this.isActive,
    required this.createdAt,
  });

  factory ModifierGroupSummary.fromMap(Map<String, dynamic> map) {
    int toInt(dynamic value) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return ModifierGroupSummary(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Grupo',
      minSelect: toInt(map['min_select']),
      maxSelect: toInt(map['max_select']),
      isActive: map['is_active'] != false,
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

class ModifierOption {
  final String id;
  final String groupId;
  final String name;
  final double priceDelta;
  final bool isActive;
  final DateTime createdAt;

  const ModifierOption({
    required this.id,
    required this.groupId,
    required this.name,
    required this.priceDelta,
    required this.isActive,
    required this.createdAt,
  });

  factory ModifierOption.fromMap(
    Map<String, dynamic> map, {
    required double Function(dynamic value) priceParser,
  }) {
    return ModifierOption(
      id: map['id']?.toString() ?? '',
      groupId: map['group_id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Modificador',
      priceDelta: priceParser(map['price_delta']),
      isActive: map['is_active'] != false,
      createdAt:
          DateTime.tryParse(map['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

/// Insumo del inventario, tal como lo necesita el formulario de modificadores
/// para armar sus líneas de descuento. Gemelo de `RecipeInventoryItem` del
/// módulo de recetas — cada módulo trae el suyo, igual que
/// [ModifierProduct]/`RecipeMenuProduct`.
class ModifierInventoryItem {
  final String id;
  final String name;
  final String sku;
  final String unit;
  final double cost;

  /// Unidad de compra (ej. Botella) y su contenido en unidad base
  /// (`packSize`, ej. 700 ml): permiten capturar «1 botella» y guardar 700 ml.
  final String? purchaseUnit;
  final double packSize;

  const ModifierInventoryItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.unit,
    required this.cost,
    this.purchaseUnit,
    this.packSize = 1,
  });

  factory ModifierInventoryItem.fromMap(Map<String, dynamic> map) {
    double toDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '') ?? 0;
    }

    final rawPack = toDouble(map['pack_size']);
    final pu = map['purchase_unit']?.toString().trim();
    return ModifierInventoryItem(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Insumo',
      sku: map['sku']?.toString() ?? '',
      unit: map['unit']?.toString() ?? 'unidad',
      cost: toDouble(map['cost']),
      purchaseUnit: (pu == null || pu.isEmpty) ? null : pu,
      packSize: rawPack <= 0 ? 1 : rawPack,
    );
  }
}

/// Una línea de insumo ya guardada de un modificador.
///
/// `quantity` va en la unidad BASE del insumo y LLEVA SIGNO: positiva descuenta
/// (queso extra), negativa anula lo que la receta base del producto iba a
/// descontar (sin queso, cambio de pan).
class ModifierIngredientEntry {
  final String id;
  final String modifierId;
  final String inventoryItemId;
  final String inventoryItemName;
  final String inventoryItemSku;
  final double quantity;
  final String unit;
  final double unitCost;

  const ModifierIngredientEntry({
    required this.id,
    required this.modifierId,
    required this.inventoryItemId,
    required this.inventoryItemName,
    required this.inventoryItemSku,
    required this.quantity,
    required this.unit,
    required this.unitCost,
  });

  bool get isDeduction => quantity >= 0;

  double get totalCost => quantity * unitCost;
}

/// Línea en borrador que el formulario manda a guardar (ya convertida a
/// unidad base y con el signo aplicado).
class ModifierIngredientDraft {
  final String inventoryItemId;
  final double quantity;
  final String unit;

  const ModifierIngredientDraft({
    required this.inventoryItemId,
    required this.quantity,
    required this.unit,
  });

  Map<String, dynamic> toMap(String modifierId) => {
        'modifier_id': modifierId,
        'inventory_item_id': inventoryItemId,
        'quantity': quantity,
        'unit': unit,
      };
}

class ModifiersState {
  final bool loading;
  final bool saving;
  final String? error;
  final String? businessId;
  final String? selectedGroupId;
  final List<ModifierProduct> products;
  final List<ModifierGroupSummary> groups;
  final List<ModifierOption> modifiers;
  final Map<String, List<String>> assignedProductIdsByGroup;

  /// Catálogo de insumos del negocio (para el selector del formulario).
  final List<ModifierInventoryItem> inventoryItems;

  /// Líneas de insumo por modificador, indexadas por `modifiers.id`.
  final Map<String, List<ModifierIngredientEntry>> ingredientsByModifier;

  /// `false` cuando la base todavía no tiene `modifier_ingredients`
  /// (migración 20260907_0001 sin aplicar). La pantalla esconde la sección
  /// de insumos en vez de reventar: el resto de los modificadores sigue
  /// funcionando igual que siempre.
  final bool ingredientsSupported;

  const ModifiersState({
    this.loading = false,
    this.saving = false,
    this.error,
    this.businessId,
    this.selectedGroupId,
    this.products = const [],
    this.groups = const [],
    this.modifiers = const [],
    this.assignedProductIdsByGroup = const {},
    this.inventoryItems = const [],
    this.ingredientsByModifier = const {},
    this.ingredientsSupported = true,
  });

  List<ModifierIngredientEntry> ingredientsOf(String modifierId) =>
      ingredientsByModifier[modifierId] ?? const [];

  ModifierGroupSummary? get selectedGroup {
    if (groups.isEmpty) return null;
    final selected = selectedGroupId;
    if (selected == null) return groups.first;
    for (final group in groups) {
      if (group.id == selected) return group;
    }
    return groups.first;
  }

  List<ModifierOption> get selectedGroupModifiers {
    final group = selectedGroup;
    if (group == null) return const [];
    return modifiers
        .where((modifier) => modifier.groupId == group.id)
        .toList(growable: false);
  }

  List<String> get selectedGroupAssignedProductIds {
    final group = selectedGroup;
    if (group == null) return const [];
    return assignedProductIdsByGroup[group.id] ?? const [];
  }

  ModifiersState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    String? businessId,
    String? selectedGroupId,
    List<ModifierProduct>? products,
    List<ModifierGroupSummary>? groups,
    List<ModifierOption>? modifiers,
    Map<String, List<String>>? assignedProductIdsByGroup,
    List<ModifierInventoryItem>? inventoryItems,
    Map<String, List<ModifierIngredientEntry>>? ingredientsByModifier,
    bool? ingredientsSupported,
    bool clearError = false,
  }) {
    return ModifiersState(
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
      selectedGroupId: selectedGroupId ?? this.selectedGroupId,
      products: products ?? this.products,
      groups: groups ?? this.groups,
      modifiers: modifiers ?? this.modifiers,
      assignedProductIdsByGroup:
          assignedProductIdsByGroup ?? this.assignedProductIdsByGroup,
      inventoryItems: inventoryItems ?? this.inventoryItems,
      ingredientsByModifier:
          ingredientsByModifier ?? this.ingredientsByModifier,
      ingredientsSupported: ingredientsSupported ?? this.ingredientsSupported,
    );
  }
}
