import 'package:equatable/equatable.dart';
import '../../../data/models/sales_models.dart';

/// 📄 Estado del proceso de división de cuenta
class SplitBillState extends Equatable {
  final bool loading;
  final String? error;

  // Orden original
  final Order? order;
  final List<OrderItem> allItems;

  // Checks creados
  final List<OrderCheck> checks;

  // Items seleccionados para asignar
  final Set<String> selectedItemIds;

  // División igualitaria
  final bool showEqualSplit;
  final int equalSplitPeople;

  // Estado del proceso
  final bool splitApplied;

  const SplitBillState({
    this.loading = false,
    this.error,
    this.order,
    this.allItems = const [],
    this.checks = const [],
    this.selectedItemIds = const {},
    this.showEqualSplit = false,
    this.equalSplitPeople = 2,
    this.splitApplied = false,
  });

  SplitBillState copyWith({
    bool? loading,
    String? error,
    Order? order,
    List<OrderItem>? allItems,
    List<OrderCheck>? checks,
    Set<String>? selectedItemIds,
    bool? showEqualSplit,
    int? equalSplitPeople,
    bool? splitApplied,
  }) {
    return SplitBillState(
      loading: loading ?? this.loading,
      error: error,
      order: order ?? this.order,
      allItems: allItems ?? this.allItems,
      checks: checks ?? this.checks,
      selectedItemIds: selectedItemIds ?? this.selectedItemIds,
      showEqualSplit: showEqualSplit ?? this.showEqualSplit,
      equalSplitPeople: equalSplitPeople ?? this.equalSplitPeople,
      splitApplied: splitApplied ?? this.splitApplied,
    );
  }

  // Items que aún no están asignados a ningún check
  List<OrderItem> get unassignedItems {
    return allItems.where((item) => item.checkId == null).toList();
  }

  // Items asignados a un check específico
  List<OrderItem> itemsForCheck(String checkId) {
    return allItems.where((item) => item.checkId == checkId).toList();
  }

  // Verificar si hay items seleccionados
  bool get hasSelectedItems => selectedItemIds.isNotEmpty;

  // Verificar si se puede aplicar la división
  bool get canApplySplit {
    // Debe haber al menos un check
    if (checks.isEmpty) return false;

    // Todos los items deben estar asignados
    if (unassignedItems.isNotEmpty) return false;

    return true;
  }

  @override
  List<Object?> get props => [
    loading,
    error,
    order,
    allItems,
    checks,
    selectedItemIds,
    showEqualSplit,
    equalSplitPeople,
    splitApplied,
  ];
}
