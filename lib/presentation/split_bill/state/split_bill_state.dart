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
  final Set<String> pendingDeletedCheckIds;

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
    this.pendingDeletedCheckIds = const {},
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
    Set<String>? pendingDeletedCheckIds,
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
      pendingDeletedCheckIds:
          pendingDeletedCheckIds ?? this.pendingDeletedCheckIds,
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
    if (loading || order == null) return false;

    // Permitir guardar también cuando todas las subcuentas se eliminaron
    // y los items quedaron en la cuenta principal (C1).
    return allItems.isNotEmpty ||
        checks.isNotEmpty ||
        pendingDeletedCheckIds.isNotEmpty;
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
    pendingDeletedCheckIds,
  ];
}
