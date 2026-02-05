import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/sales_models.dart';
import '../../../data/repositories/sales_repository.dart';
import '../../sales/viewmodel/sales_viewmodel.dart';
import '../state/split_bill_state.dart';

// Provider
final splitBillViewModelProvider =
    StateNotifierProvider.autoDispose<SplitBillViewModel, SplitBillState>(
      (ref) => SplitBillViewModel(ref.read(salesRepositoryProvider)),
    );

/// 📄 ViewModel para división de cuenta
class SplitBillViewModel extends StateNotifier<SplitBillState> {
  final SalesRepository _salesRepo;

  SplitBillViewModel(this._salesRepo) : super(const SplitBillState());

  // ============================================================
  // 🚀 INICIALIZACIÓN
  // ============================================================

  /// Inicializar con orden y sus items
  Future<void> initialize(Order order) async {
    state = state.copyWith(loading: true, error: null);

    try {
      // Obtener items de la orden
      final items = await _salesRepo.getOrderItems(order.id);

      // Obtener checks existentes (si ya se dividió antes)
      final existingChecks = await _salesRepo.getOrderChecks(order.id);

      state = state.copyWith(
        loading: false,
        order: order,
        allItems: items,
        checks: existingChecks,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error al cargar orden: $e',
      );
    }
  }

  // ============================================================
  // 📋 GESTIÓN DE CHECKS
  // ============================================================

  /// Crear nuevo check
  Future<void> createNewCheck() async {
    if (state.order == null) return;

    state = state.copyWith(loading: true, error: null);

    try {
      // Crear un solo check nuevo
      final newChecks = await _salesRepo.createSplitBill(
        orderId: state.order!.id,
        numberOfChecks: 1,
      );

      // Agregar a la lista existente
      final updatedChecks = [...state.checks, ...newChecks];

      state = state.copyWith(loading: false, checks: updatedChecks);
    } catch (e) {
      state = state.copyWith(loading: false, error: 'Error al crear check: $e');
    }
  }

  /// Eliminar check (solo si está vacío)
  Future<void> deleteCheck(String checkId) async {
    // Verificar que el check esté vacío
    final itemsInCheck = state.itemsForCheck(checkId);
    if (itemsInCheck.isNotEmpty) {
      state = state.copyWith(
        error: 'No se puede eliminar un check con items asignados',
      );
      return;
    }

    // Remover de la lista local
    final updatedChecks = state.checks.where((c) => c.id != checkId).toList();
    state = state.copyWith(checks: updatedChecks);
  }

  // ============================================================
  // 🔄 SELECCIÓN DE ITEMS
  // ============================================================

  /// Toggle selección de item
  void toggleItemSelection(String itemId) {
    final newSelection = Set<String>.from(state.selectedItemIds);

    if (newSelection.contains(itemId)) {
      newSelection.remove(itemId);
    } else {
      newSelection.add(itemId);
    }

    state = state.copyWith(selectedItemIds: newSelection);
  }

  /// Seleccionar todos los items no asignados
  void selectAllUnassigned() {
    final unassignedIds = state.unassignedItems.map((i) => i.id).toSet();
    state = state.copyWith(selectedItemIds: unassignedIds);
  }

  /// Limpiar selección
  void clearSelection() {
    state = state.copyWith(selectedItemIds: {});
  }

  // ============================================================
  // 📌 ASIGNACIÓN DE ITEMS A CHECKS
  // ============================================================

  /// Asignar items seleccionados a un check
  Future<void> assignSelectedItemsToCheck(String checkId) async {
    if (state.selectedItemIds.isEmpty) return;

    state = state.copyWith(loading: true, error: null);

    try {
      // Mover cada item seleccionado al check
      for (final itemId in state.selectedItemIds) {
        await _salesRepo.moveItemToCheck(
          itemId: itemId,
          checkPosition: _getCheckPosition(checkId),
        );
      }

      // Recargar items actualizados
      if (state.order != null) {
        final updatedItems = await _salesRepo.getOrderItems(state.order!.id);
        final updatedChecks = await _salesRepo.getOrderChecks(state.order!.id);

        state = state.copyWith(
          loading: false,
          allItems: updatedItems,
          checks: updatedChecks,
          selectedItemIds: {},
        );
      }
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error al asignar items: $e',
      );
    }
  }

  /// Obtener posición del check
  int _getCheckPosition(String checkId) {
    final check = state.checks.firstWhere((c) => c.id == checkId);
    return check.position;
  }

  /// Retornar item a 'Sin Asignar' (Check position 0)
  Future<void> unassignItem(String itemId) async {
    state = state.copyWith(loading: true, error: null);

    try {
      await _salesRepo.moveItemToCheck(
        itemId: itemId,
        checkPosition: 0, // 0 = Unassigned / Pool
      );

      // Recargar items actualizados
      if (state.order != null) {
        final updatedItems = await _salesRepo.getOrderItems(state.order!.id);
        final updatedChecks = await _salesRepo.getOrderChecks(state.order!.id);

        state = state.copyWith(
          loading: false,
          allItems: updatedItems,
          checks: updatedChecks,
        );
      }
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error al remover item: $e',
      );
    }
  }

  // ============================================================
  // ⚖️ DIVISIÓN IGUALITARIA
  // ============================================================

  /// Mostrar/ocultar panel de división igualitaria
  void toggleEqualSplit() {
    state = state.copyWith(showEqualSplit: !state.showEqualSplit);
  }

  /// Cambiar número de personas para división igualitaria
  void setEqualSplitPeople(int people) {
    if (people < 2) return;
    state = state.copyWith(equalSplitPeople: people);
  }

  /// Aplicar división igualitaria
  Future<void> applyEqualSplit() async {
    if (state.order == null) return;
    if (state.equalSplitPeople < 2) return;

    state = state.copyWith(loading: true, error: null);

    try {
      // Crear N checks
      final newChecks = await _salesRepo.createSplitBill(
        orderId: state.order!.id,
        numberOfChecks: state.equalSplitPeople,
      );

      // Distribuir items equitativamente
      final unassigned = state.unassignedItems;
      final itemsPerCheck = (unassigned.length / state.equalSplitPeople).ceil();

      for (int i = 0; i < newChecks.length; i++) {
        final startIndex = i * itemsPerCheck;
        final endIndex = (startIndex + itemsPerCheck).clamp(
          0,
          unassigned.length,
        );

        if (startIndex < unassigned.length) {
          final itemsForThisCheck = unassigned.sublist(startIndex, endIndex);

          for (final item in itemsForThisCheck) {
            await _salesRepo.moveItemToCheck(
              itemId: item.id,
              checkPosition: newChecks[i].position,
            );
          }
        }
      }

      // Recargar datos
      final updatedItems = await _salesRepo.getOrderItems(state.order!.id);
      final updatedChecks = await _salesRepo.getOrderChecks(state.order!.id);

      state = state.copyWith(
        loading: false,
        allItems: updatedItems,
        checks: updatedChecks,
        showEqualSplit: false,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error al dividir en partes iguales: $e',
      );
    }
  }

  // ============================================================
  // ✅ APLICAR DIVISIÓN
  // ============================================================

  /// Aplicar y confirmar la división
  Future<void> applySplit() async {
    if (!state.canApplySplit) {
      state = state.copyWith(
        error: 'Debes asignar todos los items a checks antes de aplicar',
      );
      return;
    }

    state = state.copyWith(loading: false, splitApplied: true);
  }

  // ============================================================
  // 🔄 RESET
  // ============================================================

  void reset() {
    state = const SplitBillState();
  }
}
