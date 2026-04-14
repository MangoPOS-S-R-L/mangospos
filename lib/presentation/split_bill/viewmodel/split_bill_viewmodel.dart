import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/sales_models.dart';
import '../../../data/repositories/sales_repository.dart';
import '../../../data/utils/order_pricing_utils.dart';
import '../../../services/session/session_controller.dart';
import '../../sales/viewmodel/sales_viewmodel.dart';
import '../state/split_bill_state.dart';

// Provider
final splitBillViewModelProvider =
    StateNotifierProvider.autoDispose<SplitBillViewModel, SplitBillState>(
      (ref) => SplitBillViewModel(ref),
    );

/// 📄 ViewModel para división de cuenta
class SplitBillViewModel extends StateNotifier<SplitBillState> {
  final Ref _ref;
  Map<String, String?> _initialCheckIdByItemId = const {};
  Timer? _errorDismissTimer;

  SplitBillViewModel(this._ref)
    : _salesRepo = _ref.read(salesRepositoryProvider),
      super(const SplitBillState());

  final SalesRepository _salesRepo;

  @override
  void dispose() {
    _errorDismissTimer?.cancel();
    super.dispose();
  }

  /// Sets error and auto-clears it after 5 seconds for non-critical errors.
  void _setErrorWithAutoDismiss(String message) {
    state = state.copyWith(error: message);
    _errorDismissTimer?.cancel();
    _errorDismissTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && state.error == message) {
        state = state.copyWith(error: null);
      }
    });
  }

  String? get _activeBusinessId => _ref.read(sessionProvider).activeBusinessId;

  // ============================================================
  // 🚀 INICIALIZACIÓN
  // ============================================================

  /// Inicializar con orden y sus items
  Future<void> initialize(Order order) async {
    state = state.copyWith(loading: true, error: null);

    try {
      // Carga compacta en una sola llamada RPC: order + checks + items abiertos.
      final bundle = await _salesRepo.getOrderBundle(
        order.id,
        businessId: _activeBusinessId,
      );
      if (!mounted) return;
      final items = bundle.items;
      final existingChecks = List<OrderCheck>.from(bundle.checks);
      final effectiveOrder = bundle.order ?? order;

      // 1. Identificar Checks Reales (Subcuentas Creadas)
      // Si tenemos C1, C2, C3. Ordenados por posicion.
      // C1 se considera la Cuenta Principal (Pool).
      // C2, C3 son las subcuentas visibles.
      List<OrderCheck> visibleChecks = [];
      Set<String> visibleCheckIds = {};

      if (existingChecks.length > 1) {
        // Ordenar
        existingChecks.sort((a, b) => a.position.compareTo(b.position));
        // Tomar todos MENOS el primero y solo abiertos
        visibleChecks = existingChecks
            .sublist(1)
            .where((c) => !c.isClosed)
            .toList();
        visibleCheckIds = visibleChecks.map((c) => c.id).toSet();
      }

      // 2. Preparar Items
      // Si el item NO pertenece a ninguno de los visibleChecks, lo forzamos a checkId: null
      // Esto "jala" items de la cuenta principal (C1) O items con checkId nulo real hacia la izquierda.
      List<OrderItem> visibleItems = items.map((i) {
        if (i.checkId != null && visibleCheckIds.contains(i.checkId)) {
          return i; // Se queda en su subcuenta (C2, C3...)
        }
        // Si no esta en una subcuenta visible, es "Sin Asignar" (C1 o Null)
        return i.copyWith(forceCheckIdNull: true);
      }).toList();

      state = state.copyWith(
        loading: false,
        order: effectiveOrder,
        allItems: visibleItems,
        checks: visibleChecks,
        pendingDeletedCheckIds: <String>{},
      );
      _snapshotItemAssignments(visibleItems);
    } catch (e) {
      if (!mounted) return;
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
  /// Crear nuevo check (LOCAL STATE)
  /// Crear nuevo check (LOCAL STATE)
  Future<void> createNewCheck() async {
    final newId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    final nextPosition = _getNextPosition();

    final newCheck = OrderCheck(
      id: newId,
      orderId: state.order?.id ?? '',
      label: 'C$nextPosition',
      position: nextPosition,
      isClosed: false,
      subtotal: 0,
      discounts: 0,
      serviceFee: 0,
      tax: 0,
      total: 0,
    );

    final updatedChecks = List<OrderCheck>.from(state.checks)..add(newCheck);

    state = state.copyWith(checks: updatedChecks);
  }

  int _getNextPosition() {
    // Si no hay checks visibles, la siguiente es 2 (C1 es main oculto)
    if (state.checks.isEmpty) return 2;
    final maxPos = state.checks
        .map((c) => c.position)
        .reduce((a, b) => a > b ? a : b);
    return maxPos + 1;
  }

  Future<void> assignCustomerToCheck({
    required String checkId,
    required String customerId,
    required String customerName,
  }) async {
    final updatedChecks = state.checks
        .map((check) {
          if (check.id != checkId) return check;
          return check.copyWith(
            customerId: customerId,
            customerName: customerName,
          );
        })
        .toList(growable: false);

    state = state.copyWith(checks: updatedChecks, error: null);

    if (_isUuid(checkId)) {
      try {
        await _salesRepo.assignCustomerToCheck(
          checkId: checkId,
          customerId: customerId,
          customerName: customerName,
        );
      } catch (e) {
        _setErrorWithAutoDismiss('Error asignando cliente: $e');
      }
    }
  }

  Future<void> clearCustomerFromCheck(String checkId) async {
    final updatedChecks = state.checks
        .map((check) {
          if (check.id != checkId) return check;
          return check.copyWith(clearCustomer: true);
        })
        .toList(growable: false);

    state = state.copyWith(checks: updatedChecks, error: null);

    if (_isUuid(checkId)) {
      try {
        await _salesRepo.clearCustomerFromCheck(checkId);
      } catch (e) {
        _setErrorWithAutoDismiss('Error limpiando cliente: $e');
      }
    }
  }

  Future<void> deleteCheck(String checkId) async {
    final previousItems = state.allItems;
    final mainCheck = state.checks.firstWhere(
      (c) => c.position == 1,
      orElse: () => OrderCheck(
        id: '',
        orderId: '',
        label: '',
        position: 1,
        isClosed: false,
        subtotal: 0,
        discounts: 0,
        serviceFee: 0,
        tax: 0,
        total: 0,
      ),
    );

    final movedToMainItems = state.allItems.map((item) {
      if (item.checkId == checkId) {
        return item.copyWith(
          checkId: mainCheck.id.isNotEmpty ? mainCheck.id : null,
          forceCheckIdNull: mainCheck.id.isEmpty,
        );
      }
      return item;
    }).toList();

    final normalizedItems = mainCheck.id.isNotEmpty
        ? _consolidateCheckItemsLocally(
            items: movedToMainItems,
            checkId: mainCheck.id,
          )
        : _consolidateUnassignedItemsLocally(movedToMainItems);

    final updatedChecks = state.checks.where((c) => c.id != checkId).toList();
    final updatedPendingDeletes = Set<String>.from(state.pendingDeletedCheckIds)
      ..remove(checkId);

    state = state.copyWith(
      checks: _recalculateChecksTotals(updatedChecks, normalizedItems),
      allItems: normalizedItems,
      selectedItemIds: {},
      pendingDeletedCheckIds: updatedPendingDeletes,
      error: null,
    );

    if (_isUuid(checkId)) {
      Future(() async {
        try {
          final itemIdsToMove = previousItems
              .where((i) => i.checkId == checkId)
              .map((i) => i.id)
              .toList(growable: false);

          if (itemIdsToMove.isNotEmpty) {
            await _salesRepo.moveItemsToCheckBatch(
              itemIds: itemIdsToMove,
              checkPosition: 1,
            );
          }

          await _salesRepo.deleteCheck(checkId);
          if (mainCheck.id.isNotEmpty && _isUuid(mainCheck.id)) {
            await _salesRepo.consolidateCheckItems(
              checkId: mainCheck.id,
              normalizeQtyToInteger: true,
            );
          }
        } catch (e) {
          // Manejo de error silencioso o notificación global
          // Por ahora, solo log en consola o update de error si aún montado
          if (mounted) {
            // No revertimos drásticamente para no romper flujo usuario, pero avisamos
            debugPrint('Error sync deleteCheck: $e');
            // Podríamos poner un mensajito en error state
            state = state.copyWith(
              error:
                  'Error sincronizando eliminación. Recarga si es necesario.',
            );
          }
        }
      });
    }
  }

  bool _isUuid(String value) {
    final regex = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return regex.hasMatch(value);
  }

  /// Unir una subcuenta origen dentro de una subcuenta destino.
  Future<void> mergeChecks({
    required String sourceCheckId,
    required String targetCheckId,
  }) async {
    if (sourceCheckId == targetCheckId) return;

    final sourceCheck = state.checks.firstWhere(
      (c) => c.id == sourceCheckId,
      orElse: () => OrderCheck(
        id: '',
        orderId: '',
        label: '',
        position: -1,
        isClosed: false,
        subtotal: 0,
        discounts: 0,
        serviceFee: 0,
        tax: 0,
        total: 0,
      ),
    );
    final targetCheck = state.checks.firstWhere(
      (c) => c.id == targetCheckId,
      orElse: () => OrderCheck(
        id: '',
        orderId: '',
        label: '',
        position: -1,
        isClosed: false,
        subtotal: 0,
        discounts: 0,
        serviceFee: 0,
        tax: 0,
        total: 0,
      ),
    );
    if (sourceCheck.position <= 0 || targetCheck.position <= 0) {
      _setErrorWithAutoDismiss('No se pudo unir cuentas seleccionadas.');
      return;
    }

    final sourceItems = state.allItems
        .where((i) => i.checkId == sourceCheckId)
        .toList();
    final movedItems = state.allItems.map((item) {
      if (item.checkId == sourceCheckId) {
        return item.copyWith(checkId: targetCheckId, forceCheckIdNull: false);
      }
      return item;
    }).toList();
    final updatedItems = _consolidateCheckItemsLocally(
      items: movedItems,
      checkId: targetCheckId,
    );

    final updatedChecks = state.checks
        .where((c) => c.id != sourceCheckId)
        .toList();
    final updatedPendingDeletes = Set<String>.from(
      state.pendingDeletedCheckIds,
    );
    if (_isUuid(sourceCheckId)) {
      updatedPendingDeletes.add(sourceCheckId);
    }

    state = state.copyWith(
      allItems: updatedItems,
      checks: _recalculateChecksTotals(updatedChecks, updatedItems),
      selectedItemIds: {},
      pendingDeletedCheckIds: updatedPendingDeletes,
      error: null,
    );

    // Si ambas cuentas existen en DB, sincronizamos de una vez.
    if (_isUuid(sourceCheckId) && _isUuid(targetCheckId)) {
      try {
        if (sourceItems.isNotEmpty) {
          await _salesRepo.moveItemsToCheckBatch(
            itemIds: sourceItems.map((i) => i.id).toList(),
            checkPosition: targetCheck.position,
          );
        }
        await _salesRepo.deleteCheck(sourceCheckId);
        await _salesRepo.consolidateCheckItems(checkId: targetCheckId);
        if (!mounted) return;
        final order = state.order;
        if (order != null) {
          await initialize(order);
        } else {
          state = state.copyWith(
            pendingDeletedCheckIds: Set<String>.from(
              state.pendingDeletedCheckIds,
            )..remove(sourceCheckId),
          );
        }
      } catch (e) {
        if (!mounted) return;
        state = state.copyWith(
          error: 'La unión quedó local. Aplica división para sincronizar ($e)',
        );
      }
    }
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
  /// Asignar items seleccionados a un check (LOCAL)
  /// Asignar items seleccionados a un check (LOCAL)
  Future<void> assignSelectedItemsToCheck(String checkId) async {
    if (state.selectedItemIds.isEmpty) return;

    // Actualizar items locales
    final updatedItems = state.allItems.map((item) {
      if (state.selectedItemIds.contains(item.id)) {
        // Si el item se asigna, le ponemos el checkId
        return item.copyWith(checkId: checkId, forceCheckIdNull: false);
      }
      return item;
    }).toList();

    // Recalcular totales de checks locales (opcional pero bueno para UI)
    final updatedChecks = _recalculateChecksTotals(state.checks, updatedItems);

    state = state.copyWith(
      allItems: updatedItems,
      checks: updatedChecks,
      selectedItemIds: {},
    );
  }

  List<OrderCheck> _recalculateChecksTotals(
    List<OrderCheck> checks,
    List<OrderItem> items,
  ) {
    final itemsByCheckId = <String, List<OrderItem>>{};

    for (final item in items) {
      final checkId = item.checkId;
      if (checkId == null) continue;
      itemsByCheckId.putIfAbsent(checkId, () => <OrderItem>[]).add(item);
    }

    return checks
        .map((c) {
          final checkItems = itemsByCheckId[c.id] ?? const <OrderItem>[];
          final summary = summarizeOrderPricing(state.order, checkItems);

          return OrderCheck(
            id: c.id,
            orderId: c.orderId,
            label: c.label,
            position: c.position,
            isClosed: c.isClosed,
            subtotal: summary.subtotal,
            discounts: summary.discounts,
            serviceFee: summary.serviceFee,
            tax: summary.tax,
            total: summary.total,
            items: checkItems,
          );
        })
        .toList(growable: false);
  }

  List<OrderItem> _consolidateCheckItemsLocally({
    required List<OrderItem> items,
    required String checkId,
  }) {
    final consolidatedByKey = <String, OrderItem>{};
    final otherItems = <OrderItem>[];

    for (final item in items) {
      if (item.checkId != checkId) {
        otherItems.add(item);
        continue;
      }

      final modifiersKey = item.modifiers
          .map((m) => '${m.name}|${m.qty}|${m.price}')
          .join('~');
      final key =
          '${item.productId ?? ''}|${item.productName}|${item.sku ?? ''}|'
          '${item.unitPrice}|${item.isTakeout}|${item.status}|${item.notes ?? ''}|$modifiersKey';

      final existing = consolidatedByKey[key];
      if (existing == null) {
        consolidatedByKey[key] = item;
      } else {
        consolidatedByKey[key] = existing.copyWith(
          quantity: existing.quantity + item.quantity,
          subtotal: existing.subtotal + item.subtotal,
          discounts: existing.discounts + item.discounts,
          tax: existing.tax + item.tax,
          total: existing.total + item.total,
        );
      }
    }

    return [...otherItems, ...consolidatedByKey.values];
  }

  List<OrderItem> _consolidateUnassignedItemsLocally(List<OrderItem> items) {
    final consolidatedByKey = <String, OrderItem>{};
    final assignedItems = <OrderItem>[];

    for (final item in items) {
      if (item.checkId != null) {
        assignedItems.add(item);
        continue;
      }

      final modifiersKey = item.modifiers
          .map((m) => '${m.name}|${m.qty}|${m.price}')
          .join('~');
      final key =
          '${item.productId ?? ''}|${item.productName}|${item.sku ?? ''}|'
          '${item.unitPrice}|${item.isTakeout}|${item.status}|${item.notes ?? ''}|$modifiersKey';

      final existing = consolidatedByKey[key];
      if (existing == null) {
        consolidatedByKey[key] = item;
      } else {
        consolidatedByKey[key] = existing.copyWith(
          quantity: existing.quantity + item.quantity,
          subtotal: existing.subtotal + item.subtotal,
          discounts: existing.discounts + item.discounts,
          tax: existing.tax + item.tax,
          total: existing.total + item.total,
          forceCheckIdNull: true,
        );
      }
    }

    return [...assignedItems, ...consolidatedByKey.values];
  }

  /// Retornar item a 'Sin Asignar' (Check position 0)
  /// Retornar item a 'Sin Asignar' (LOCAL)
  /// Retornar item a 'Sin Asignar' (LOCAL)
  Future<void> unassignItem(String itemId) async {
    final updatedItems = state.allItems.map((item) {
      if (item.id == itemId) {
        return item.copyWith(forceCheckIdNull: true);
      }
      return item;
    }).toList();

    final updatedChecks = _recalculateChecksTotals(state.checks, updatedItems);

    state = state.copyWith(allItems: updatedItems, checks: updatedChecks);
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

  /// Aplicar división igualitaria en backend y refrescar estado local.
  Future<void> applyEqualSplit() async {
    if (state.order == null) return;
    if (state.equalSplitPeople < 2) return;

    try {
      state = state.copyWith(loading: true, error: null);

      await _salesRepo.splitItemsEqually(
        orderId: state.order!.id,
        people: state.equalSplitPeople,
      );

      // Refrescar snapshot local desde backend para mostrar cantidades fraccionadas reales.
      await initialize(state.order!);
      if (!mounted) return;
      state = state.copyWith(
        showEqualSplit: false,
        error: null,
        selectedItemIds: {},
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        loading: false,
        error: 'Error al dividir en partes iguales: $e',
      );
    }
  }

  // ============================================================
  // ✅ APLICAR DIVISIÓN (PERSISTENCIA)
  // ============================================================

  /// Aplicar y confirmar la división
  Future<void> applySplit() async {
    if (!state.canApplySplit) {
      _setErrorWithAutoDismiss('No hay cambios para aplicar.');
      return;
    }

    state = state.copyWith(loading: true, error: null);

    try {
      final orderId = state.order!.id;
      final checkPositionById = <String, int>{
        for (final check in state.checks) check.id: check.position,
      };

      // Mover solo los items cuyo destino cambió en esta sesión.
      final itemsByTargetPosition = <int, List<String>>{};
      final affectedPositions = <int>{};
      for (final item in state.allItems) {
        var targetPosition = 1; // Main Check (unassigned)
        if (item.checkId != null) {
          final position = checkPositionById[item.checkId];
          if (position != null && position > 0) {
            targetPosition = position;
          }
        }

        final initialCheckId = _initialCheckIdByItemId[item.id];
        if (initialCheckId == item.checkId) {
          continue;
        }

        itemsByTargetPosition
            .putIfAbsent(targetPosition, () => <String>[])
            .add(item.id);
        affectedPositions.add(targetPosition);
      }

      if (itemsByTargetPosition.isNotEmpty) {
        await Future.wait(
          itemsByTargetPosition.entries.map((entry) {
            return _salesRepo.moveItemsToCheckBatch(
              itemIds: entry.value,
              checkPosition: entry.key,
            );
          }),
        );
      }

      final pendingDeletes = state.pendingDeletedCheckIds
          .where(_isUuid)
          .toList(growable: false);

      if (itemsByTargetPosition.isEmpty && pendingDeletes.isEmpty) {
        state = state.copyWith(loading: false, splitApplied: true);
        return;
      }

      if (pendingDeletes.isNotEmpty) {
        await Future.wait(
          pendingDeletes.map((checkId) => _salesRepo.deleteCheck(checkId)),
        );
      }

      if (affectedPositions.isNotEmpty) {
        final consolidatedChecks = await _salesRepo.getOrderChecks(
          orderId,
          businessId: _activeBusinessId,
        );
        final affectedCheckIds = consolidatedChecks
            .where((c) => !c.isClosed && affectedPositions.contains(c.position))
            .map((c) => c.id)
            .toList(growable: false);
        if (affectedCheckIds.isNotEmpty) {
          await Future.wait(
            affectedCheckIds.map((checkId) {
              return _salesRepo.consolidateCheckItems(checkId: checkId);
            }),
          );
        }
      }

      state = state.copyWith(
        loading: false,
        splitApplied: true,
        pendingDeletedCheckIds: <String>{},
      );
      _snapshotItemAssignments(state.allItems);
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error al aplicar cambios: $e',
      );
    }
  }

  void _snapshotItemAssignments(List<OrderItem> items) {
    _initialCheckIdByItemId = {for (final item in items) item.id: item.checkId};
  }

  // ============================================================
  // 🔄 RESET
  // ============================================================

  void reset() {
    _initialCheckIdByItemId = const {};
    state = const SplitBillState();
  }
}
