import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../data/models/sales_models.dart';
import '../../../data/repositories/sales_repository.dart';
import '../../../data/utils/order_pricing_utils.dart';
import 'package:mangopos/core/multimesero/operator_permissions.dart';
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
    // Split bill UX (2026-05-13): si el cajero abrió el modal (que
    // auto-explotó items qty>1 a unidades) y luego cerró sin aplicar,
    // los items quedan exploded en BD. Re-consolidamos en background
    // para que precuenta/recibos no muestren 2 filas de "1 Coca Cola"
    // cuando deberían ser "2 Coca Cola". Fire-and-forget: no podemos
    // await en dispose, pero capturamos las refs ANTES de super.dispose()
    // y dejamos la tarea correr en background.
    final repo = _salesRepo;
    final checkIds = state.checks
        .where((c) => !c.isClosed && _isUuid(c.id))
        .map((c) => c.id)
        .toList(growable: false);
    if (checkIds.isNotEmpty && !state.splitApplied) {
      unawaited(_consolidateChecksInBackground(repo, checkIds));
    }
    super.dispose();
  }

  /// Helper fire-and-forget para consolidar varios checks en paralelo.
  /// Se ejecuta DESPUÉS de dispose(), así que no toca `state` ni `_ref`.
  /// Errores se loguean pero no se propagan (el modal ya no existe).
  static Future<void> _consolidateChecksInBackground(
    SalesRepository repo,
    List<String> checkIds,
  ) async {
    for (final checkId in checkIds) {
      try {
        await repo.consolidateCheckItems(checkId: checkId);
      } catch (e) {
        debugPrint(
          '[SplitBill] consolidate background para $checkId falló (no crítico): $e',
        );
      }
    }
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
      // Split bill UX (2026-05-13): divide items con qty>1 en filas
      // unitarias ANTES de cargar el bundle, así el modal ve cada unidad
      // como fila separada y permite mover una a la vez. Idempotente —
      // si todos los items ya están en qty=1, es no-op. Si la red falla
      // o el RPC no está aún en BD (rollout incompleto), seguimos con
      // el flujo legacy en vez de bloquear al cajero.
      try {
        await _salesRepo.explodeItemsToUnits(orderId: order.id);
      } catch (e) {
        debugPrint(
          '[SplitBill] explodeItemsToUnits falló (no crítico, fallback a flujo legacy): $e',
        );
      }

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

      // Recalculate check totals using catalog prices (not DB values which
      // may include service fee or have rounding drift for inclusive items).
      final reconciledChecks = _recalculateChecksTotals(visibleChecks, visibleItems);

      // reservedPositions incluye TODAS las positions ya en uso en BD,
      // tanto abiertas como cerradas. _getNextPosition lo consulta para
      // no asignar position de un check cerrado (que fn_get_or_create_check
      // retornaría como existente, redirigiendo el item al check cerrado
      // y disparando el guard 0004 que lo manda a NULL — la sub-cuenta
      // "nueva" desaparece silenciosamente).
      final reservedPositions = <int>{
        for (final check in existingChecks) check.position,
      };

      state = state.copyWith(
        loading: false,
        order: effectiveOrder,
        allItems: visibleItems,
        checks: reconciledChecks,
        pendingDeletedCheckIds: <String>{},
        reservedPositions: reservedPositions,
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
    // Empezamos en 2 (C1 es principal oculto). Saltamos positions que ya
    // están reservadas en BD (checks abiertos visibles + checks cerrados
    // del state, + las explícitas en reservedPositions cargadas en
    // initialize).
    final inUse = <int>{
      ...state.reservedPositions,
      ...state.checks.map((c) => c.position),
    };
    var candidate = 2;
    while (inUse.contains(candidate)) {
      candidate += 1;
    }
    return candidate;
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

  /// Asigna o limpia el tipo de comprobante de una sub-cuenta.
  /// Pasa `ncfType=null` para volver al default del business al cobrar.
  Future<void> setNcfTypeForCheck(String checkId, String? ncfType) async {
    final normalized = ncfType?.trim();
    final newValue = (normalized == null || normalized.isEmpty) ? null : normalized;

    final updatedChecks = state.checks
        .map((check) {
          if (check.id != checkId) return check;
          return newValue == null
              ? check.copyWith(clearNcfType: true)
              : check.copyWith(requestedNcfType: newValue);
        })
        .toList(growable: false);

    state = state.copyWith(checks: updatedChecks, error: null);

    if (_isUuid(checkId)) {
      try {
        await _salesRepo.setCheckNcfType(checkId: checkId, ncfType: newValue);
      } catch (e) {
        _setErrorWithAutoDismiss('Error asignando comprobante: $e');
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
    if (!operatorHasPermissionRef(_ref, 'ventas.mesas.mover_unir')) {
      _setErrorWithAutoDismiss(
        'No tienes permiso para unir o mover sub-cuentas.',
      );
      return;
    }
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
    if (!operatorHasPermissionRef(_ref, 'ventas.cuenta.split_manual')) {
      _setErrorWithAutoDismiss(
        'No tienes permiso para dividir cuentas manualmente.',
      );
      return;
    }
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

          // For the displayed total, use the catalog prices (itemDisplayTotal)
          // so inclusive items show the menu price, not base+tax recomposition.
          final catalogTotal = double.parse(
            checkItems.fold<double>(
              0,
              (sum, item) => sum + itemDisplayTotal(state.order, item),
            ).toStringAsFixed(2),
          );

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
            total: catalogTotal,
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
          discounts: existing.discounts + item.discounts,
          // subtotal, tax and total will be recalculated by summarizeOrderPricing
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
          discounts: existing.discounts + item.discounts,
          // subtotal, tax and total will be recalculated by summarizeOrderPricing
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
  ///
  /// Pre-validaciones:
  ///   1. Si ya hay división activa (items abiertos en sub-cuentas abiertas),
  ///      bloquear con mensaje. El cajero debe deshacer primero. Esto evita
  ///      que un segundo "Dividir en partes iguales" machaque asignaciones
  ///      manuales (drag & drop) o re-fraccione items ya distribuidos.
  ///   2. Si total de unidades abiertas < personas, bloquear (no se puede
  ///      repartir 2 productos entre 4 personas sin fraccionar).
  Future<void> applyEqualSplit() async {
    if (!operatorHasPermissionRef(_ref, 'ventas.cuenta.split_equiv')) {
      _setErrorWithAutoDismiss(
        'No tienes permiso para dividir la cuenta en partes iguales.',
      );
      return;
    }
    if (state.order == null) return;
    if (state.equalSplitPeople < 2) return;

    if (state.hasActiveDivision) {
      state = state.copyWith(
        loading: false,
        error:
            'La mesa ya tiene una división activa. Si quieres redistribuir '
            'desde cero, primero deshaz la división actual con "Unir todo" '
            'y vuelve a dividir. Si solo quieres mover items entre '
            'sub-cuentas, hazlo arrastrándolos uno por uno.',
      );
      return;
    }

    final totalUnits = state.allItems
        .where((i) => i.status != 'paid' && i.status != 'void')
        .fold<double>(0, (sum, item) => sum + item.quantity);
    final totalUnitsInt = totalUnits.round();
    final people = state.equalSplitPeople;

    if (totalUnitsInt < people) {
      state = state.copyWith(
        loading: false,
        error:
            'No se puede dividir $totalUnitsInt producto(s) entre $people '
            'persona(s): no hay suficientes unidades para repartir una a '
            'cada cuenta. Reduce el número de personas o agrega más '
            'productos a la mesa antes de dividir.',
      );
      return;
    }

    // Solo unidades enteras: el cajero del MangoPOS decidió mantener split
    // estrictamente entero. Si los productos no se reparten de forma
    // exacta entre las personas, rechazamos en vez de generar fracciones.
    // Ej: 5 productos entre 3 personas = 1.67 cada uno → bloqueado.
    if (totalUnitsInt % people != 0) {
      final base = totalUnitsInt ~/ people;
      final remainder = totalUnitsInt - (base * people);
      state = state.copyWith(
        loading: false,
        error:
            'No se puede dividir $totalUnitsInt producto(s) entre $people '
            'persona(s) de forma exacta (quedan $remainder de sobra). '
            'Para mantener cantidades enteras: usa un número de personas '
            'que divida exacto, o asigna los productos manualmente '
            'arrastrándolos a cada sub-cuenta.',
      );
      return;
    }

    try {
      state = state.copyWith(loading: true, error: null);

      await _salesRepo.splitItemsEqually(
        orderId: state.order!.id,
        people: people,
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
      final msg = e.toString();
      final friendly =
          msg.contains('PEOPLE_OUT_OF_RANGE')
              ? 'El sistema permite dividir entre 2 y 4 personas.'
              : msg.contains('ORDER_NOT_FOUND')
                  ? 'La orden ya no existe o fue cerrada.'
                  : 'No se pudo dividir la cuenta. Intentá de nuevo o '
                    'recargá la mesa. Detalle técnico: $e';
      state = state.copyWith(
        loading: false,
        error: friendly,
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

        // Persistir el cliente asignado a cada sub-cuenta. Cuando el cajero
        // le asigna un cliente a una sub-cuenta recién creada dentro del
        // modal, el check todavía es "temp_" (sin UUID) y
        // assignCustomerToCheck no pudo escribirlo en BD. Ahora que el
        // backend ya creó los checks reales por posición, mapeamos
        // posición → id real y los persistimos. Idempotente para los checks
        // que ya existían (re-escribe el mismo cliente).
        final realIdByPosition = <int, String>{
          for (final rc in consolidatedChecks) rc.position: rc.id,
        };
        final customerWrites = state.checks
            .where(
              (c) =>
                  c.customerId != null &&
                  c.customerId!.isNotEmpty &&
                  c.customerName != null &&
                  c.customerName!.trim().isNotEmpty &&
                  realIdByPosition.containsKey(c.position),
            )
            .map(
              (c) => _salesRepo.assignCustomerToCheck(
                checkId: realIdByPosition[c.position]!,
                customerId: c.customerId!,
                customerName: c.customerName!,
              ),
            )
            .toList(growable: false);
        if (customerWrites.isNotEmpty) {
          await Future.wait(customerWrites);
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
