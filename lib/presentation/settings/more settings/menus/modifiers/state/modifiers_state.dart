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
  });

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
    );
  }
}
