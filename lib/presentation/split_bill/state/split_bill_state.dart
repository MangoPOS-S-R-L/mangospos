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

  /// Positions de checks que YA están reservadas en BD (incluyendo checks
  /// cerrados/cobrados). Necesario para que `_getNextPosition` no asigne
  /// una position que ya está ocupada por un check cerrado — eso causaba
  /// que al "Aplicar División" la nueva sub-cuenta cayera silenciosamente
  /// en el check cerrado existente.
  final Set<int> reservedPositions;

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
    this.reservedPositions = const {},
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
    Set<int>? reservedPositions,
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
      reservedPositions: reservedPositions ?? this.reservedPositions,
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

  /// True si la mesa YA tiene una división activa: hay items abiertos
  /// (no paid, no void) asignados a sub-cuentas abiertas (position > 1,
  /// is_closed=false).
  ///
  /// Cuando es true, el botón "Dividir en partes iguales" se deshabilita
  /// para evitar machacar la asignación actual por accidente. El cajero
  /// debe "Deshacer división" primero si quiere re-distribuir desde cero.
  ///
  /// Items ya pagados y sub-cuentas ya cerradas se ignoran a propósito —
  /// si un pago parcial está hecho pero quedan abiertos, el cajero puede
  /// reorganizar lo que queda sin tocar lo cobrado.
  bool get hasActiveDivision {
    final openSubChecks = {
      for (final check in checks)
        if (check.position > 1 && !check.isClosed) check.id,
    };
    if (openSubChecks.isEmpty) return false;

    for (final item in allItems) {
      if (item.checkId == null) continue;
      if (item.status == 'paid' || item.status == 'void') continue;
      if (openSubChecks.contains(item.checkId)) return true;
    }
    return false;
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
    reservedPositions,
  ];
}
