import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../../data/models/order_edit.dart';
import '../../../data/models/bill_split_edit.dart';
import '../../../data/utils/grouped_item_edit.dart';
import '../../../data/utils/offer_deal_pricing.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/sales_repository.dart';
import '../../../data/utils/order_pricing_utils.dart';
import 'package:mangopos/core/multimesero/operator_permissions.dart';
import '../../../services/session/session_controller.dart';
import '../../sales/state/sales_state.dart' show EditConflictNotice;
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
  Map<String, OrderItem> _initialItems = {};
  Map<String, OrderCheck> _initialChecks = {};
  BillSplitEdit? _pendingCommit;
  bool _canStage() {
    if (state.loading || state.initializationFailed) return false;
    if (_pendingCommit != null) {
      _setErrorWithAutoDismiss(
        'Hay una división sin confirmar. Reintenta Aplicar antes de cambiarla.',
      );
      return false;
    }
    return true;
  }

  List<OrderItem> _priceItems(List<OrderItem> items) =>
      repriceOfferGroups(items.map(recoverLegacyOfferRule).toList());

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
  // T04 (20261010_0006): ediciones versionadas
  // ============================================================

  // Versión de la cuenta que ve el operador (la del bundle más las que
  // dejaron sus propias ediciones).
  int? _orderVersion;

  Future<void> Function()? _conflictApplyMine;
  Future<void> Function()? _conflictKeepCurrent;

  /// Vuelve a cargar lo que hay en el servidor (descarta lo no aplicado).
  Future<void> _reloadFromServer() async {
    final order = state.order;
    if (!mounted || order == null) return;
    await initialize(order);
  }

  void _onEditConflict(
    OrderEditConflict conflict, {
    required String what,
    required Future<void> Function() applyMine,
    Future<void> Function()? keepCurrent,
  }) {
    if (!mounted) return;
    final canApply =
        conflict.result.reason != 'order_closed' &&
        conflict.result.reason != 'item_missing' &&
        conflict.result.reason != 'item_closed' &&
        conflict.result.reason != 'check_closed' &&
        conflict.result.reason != 'check_exists' &&
        conflict.result.reason != 'check_not_empty';
    _conflictApplyMine = canApply ? applyMine : null;
    _conflictKeepCurrent = keepCurrent ?? _reloadFromServer;
    state = state.copyWith(
      loading: false,
      error: state.error,
      editConflict: EditConflictNotice(
        id: const Uuid().v4(),
        message: '${conflict.message} Tu cambio: $what.',
        detail: conflict.currentDescription,
      ),
    );
  }

  /// ¿Se puede aplicar el cambio del operador ante el conflicto actual?
  bool get canApplyConflictingEdit => _conflictApplyMine != null;

  /// La decisión del operador ante el conflicto [noticeId]: [applyMine]
  /// aplica su cambio sobre lo vigente; si no, se muestra lo que hay ahora.
  Future<void> resolveEditConflict({
    required bool applyMine,
    required String noticeId,
  }) async {
    if (!mounted || state.editConflict?.id != noticeId) return;
    final apply = _conflictApplyMine;
    final keep = _conflictKeepCurrent;
    _conflictApplyMine = null;
    _conflictKeepCurrent = null;
    if (!mounted) return;
    state = state.copyWith(error: state.error, clearEditConflict: true);
    try {
      if (applyMine && apply != null) {
        await apply();
      } else if (keep != null) {
        await keep();
      }
    } on OrderEditConflict catch (conflict) {
      // Otro cambio más mientras decidía: se vuelve a preguntar.
      _onEditConflict(
        conflict,
        what: 'el mismo cambio',
        applyMine: apply ?? () async {},
        keepCurrent: keep,
      );
    } catch (e) {
      if (mounted) _setErrorWithAutoDismiss('No se pudo aplicar tu cambio: $e');
    }
  }

  // ============================================================
  // 🚀 INICIALIZACIÓN
  // ============================================================

  /// Inicializar con orden y sus items
  Future<void> initialize(Order order) async {
    _pendingCommit = null;
    state = state.copyWith(
      loading: true,
      initializationFailed: false,
      error: null,
      clearEditConflict: true,
    );

    try {
      // Preparación idempotente: una fila ordinaria por unidad. No continuar
      // con grupos si falla; seleccionar una fila no puede mover tres jugos
      // cuando el operador pretende repartir uno.
      await _salesRepo.explodeItemsToUnits(orderId: order.id);

      // Carga compacta en una sola llamada RPC: order + checks + items abiertos.
      final bundle = await _salesRepo.getOrderBundle(
        order.id,
        businessId: _activeBusinessId,
      );
      if (!mounted) return;
      final items = bundle.items
          .where((i) => i.status != 'paid' && i.status != 'void')
          .toList();
      // También detecta un servidor antiguo o una nueva ronda agrupada que
      // haya llegado entre preparar y leer. Nunca moverla entera en silencio.
      if (items.any(
        (i) =>
            !isOfferDealItem(i) &&
            i.quantity > 1 &&
            i.quantity == i.quantity.truncateToDouble(),
      )) {
        throw const BillSplitUnitsNotReady();
      }
      _initialItems = {for (final i in items) i.id: i};
      final existingChecks = List<OrderCheck>.from(bundle.checks);
      final effectiveOrder = bundle.order ?? order;
      _initialChecks = {for (final c in existingChecks) c.id: c};

      // 1. Identificar Checks Reales (Subcuentas Creadas)
      // Si tenemos C1, C2, C3. Ordenados por posicion.
      // C1 se considera la Cuenta Principal (Pool).
      // C2, C3 son las subcuentas visibles.
      List<OrderCheck> visibleChecks = [];
      Set<String> visibleCheckIds = {};

      if (existingChecks.isNotEmpty) {
        // Ordenar
        existingChecks.sort((a, b) => a.position.compareTo(b.position));
        // Tomar todos MENOS el primero y solo abiertos
        visibleChecks = existingChecks
            .where((c) => c.position > 1 && !c.isClosed)
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

      visibleItems = _priceItems(visibleItems);

      // Recalculate check totals using catalog prices (not DB values which
      // may include service fee or have rounding drift for inclusive items).
      final reconciledChecks = _recalculateChecksTotals(
        visibleChecks,
        visibleItems,
      );

      // reservedPositions incluye TODAS las positions ya en uso en BD,
      // tanto abiertas como cerradas. _getNextPosition lo consulta para
      // no asignar position de un check cerrado (que fn_get_or_create_check
      // retornaría como existente, redirigiendo el item al check cerrado
      // y disparando el guard 0004 que lo manda a NULL — la sub-cuenta
      // "nueva" desaparece silenciosamente).
      final reservedPositions = <int>{
        for (final check in existingChecks) check.position,
      };

      _orderVersion = effectiveOrder.version;
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
      _initialItems = {};
      _initialChecks = {};
      _initialCheckIdByItemId = const {};
      state = state.copyWith(
        loading: false,
        initializationFailed: true,
        allItems: [],
        checks: [],
        selectedItemIds: {},
        pendingDeletedCheckIds: {},
        error: e is BillSplitUnitsNotReady
            ? BillSplitUnitsNotReady.message
            : 'No se pudo preparar la división. Reintenta. ${FriendlyError.from(e)}',
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
    if (!_canStage()) return;
    final newId = 'temp_${const Uuid().v4()}';
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
    String? customerRnc,
  }) async {
    if (!_canStage()) return;
    state = state.copyWith(
      checks: [
        for (final c in state.checks)
          if (c.id == checkId)
            c
                .copyWith(clearCustomer: true)
                .copyWith(
                  customerId: customerId,
                  customerName: customerName,
                  customerRnc: customerRnc?.trim(),
                )
          else
            c,
      ],
    );
  }

  Future<void> clearCustomerFromCheck(String checkId) async {
    if (!_canStage()) return;
    state = state.copyWith(
      checks: [
        for (final c in state.checks)
          c.id == checkId ? c.copyWith(clearCustomer: true) : c,
      ],
    );
  }

  Future<void> setNcfTypeForCheck(String checkId, String? ncfType) async {
    if (!_canStage()) return;
    final value = ncfType?.trim();
    state = state.copyWith(
      checks: [
        for (final c in state.checks)
          if (c.id != checkId)
            c
          else if (value == null || value.isEmpty)
            c.copyWith(clearNcfType: true)
          else
            c.copyWith(requestedNcfType: value),
      ],
    );
  }

  Future<void> deleteCheck(String checkId) async {
    if (!_canStage()) return;
    final items = _priceItems([
      for (final i in state.allItems)
        i.checkId == checkId ? i.copyWith(forceCheckIdNull: true) : i,
    ]);
    final checks = state.checks.where((c) => c.id != checkId).toList();
    state = state.copyWith(
      allItems: items,
      checks: _recalculateChecksTotals(checks, items),
      selectedItemIds: {},
      pendingDeletedCheckIds: {
        ...state.pendingDeletedCheckIds,
        if (_isUuid(checkId)) checkId,
      },
    );
  }

  bool _isUuid(String value) {
    final regex = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return regex.hasMatch(value);
  }

  /// Todas las filas físicas conservan su ID hasta confirmar la transacción.
  Future<void> mergeChecks({
    required String sourceCheckId,
    required String targetCheckId,
  }) async {
    if (!_canStage()) return;
    if (!operatorHasPermissionRef(_ref, 'ventas.mesas.mover_unir')) {
      _setErrorWithAutoDismiss(
        'No tienes permiso para unir o mover sub-cuentas.',
      );
      return;
    }
    if (sourceCheckId == targetCheckId ||
        !state.checks.any((c) => c.id == sourceCheckId && !c.isClosed) ||
        !state.checks.any((c) => c.id == targetCheckId && !c.isClosed)) {
      return;
    }
    final items = _priceItems([
      for (final i in state.allItems)
        i.checkId == sourceCheckId ? i.copyWith(checkId: targetCheckId) : i,
    ]);
    final checks = state.checks.where((c) => c.id != sourceCheckId).toList();
    state = state.copyWith(
      allItems: items,
      checks: _recalculateChecksTotals(checks, items),
      selectedItemIds: {},
      pendingDeletedCheckIds: {
        ...state.pendingDeletedCheckIds,
        if (_isUuid(sourceCheckId)) sourceCheckId,
      },
    );
  }

  // ============================================================
  // 🔄 SELECCIÓN DE ITEMS
  // ============================================================

  /// Toggle selección de item
  void toggleItemSelection(String itemId) {
    if (!_canStage()) return;
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
    if (!_canStage()) return;
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
    if (!_canStage()) return;
    if (!state.checks.any((c) => c.id == checkId && !c.isClosed)) return;
    if (!operatorHasPermissionRef(_ref, 'ventas.cuenta.split_manual')) {
      _setErrorWithAutoDismiss(
        'No tienes permiso para dividir cuentas manualmente.',
      );
      return;
    }
    if (state.selectedItemIds.isEmpty) return;

    // Actualizar items locales
    final updatedItems = _priceItems(
      state.allItems.map((item) {
        if (state.selectedItemIds.contains(item.id)) {
          // Si el item se asigna, le ponemos el checkId
          return item.copyWith(checkId: checkId, forceCheckIdNull: false);
        }
        return item;
      }).toList(),
    );

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

          return c.copyWith(
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

  /// Retornar item a 'Sin Asignar' (Check position 0)
  /// Retornar item a 'Sin Asignar' (LOCAL)
  /// Retornar item a 'Sin Asignar' (LOCAL)
  Future<void> unassignItem(String itemId) async {
    if (!_canStage()) return;
    final updatedItems = _priceItems(
      state.allItems.map((item) {
        if (item.id == itemId) {
          return item.copyWith(forceCheckIdNull: true);
        }
        return item;
      }).toList(),
    );

    final updatedChecks = _recalculateChecksTotals(state.checks, updatedItems);

    state = state.copyWith(allItems: updatedItems, checks: updatedChecks);
  }

  // ============================================================
  // ⚖️ DIVISIÓN IGUALITARIA
  // ============================================================

  /// Mostrar/ocultar panel de división igualitaria
  void toggleEqualSplit() {
    if (!_canStage()) return;
    state = state.copyWith(showEqualSplit: !state.showEqualSplit);
  }

  /// Cambiar número de personas para división igualitaria
  void setEqualSplitPeople(int people) {
    if (!_canStage()) return;
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
    if (state.loading || state.initializationFailed) return;
    if (_pendingCommit != null) {
      await _commit(_pendingCommit!);
      return;
    }
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

    await _commit(_makeCommit(equalPeople: people));
  }

  // ============================================================
  // ✅ APLICAR DIVISIÓN (PERSISTENCIA)
  // ============================================================

  /// Aplicar y confirmar la división. [force]: el operador decidió aplicar
  /// su división sobre lo que cambió otro equipo (T04).
  Future<void> applySplit({bool force = false}) async {
    if (!state.canApplySplit) return;
    await _commit(_pendingCommit ?? _makeCommit(force: force));
  }

  BillSplitEdit _makeCommit({bool force = false, int? equalPeople}) {
    final positions = {for (final c in state.checks) c.id: c.position};
    return BillSplitEdit(
      opId: const Uuid().v4(),
      orderId: state.order!.id,
      baseVersion: _orderVersion,
      force: force,
      equalPeople: equalPeople,
      assignments: [
        for (final item in state.allItems)
          if (_initialCheckIdByItemId[item.id] != item.checkId)
            {
              'item_id': item.id,
              'target_position': positions[item.checkId] ?? 1,
              'source_check_id': _initialItems[item.id]?.checkId,
              ...OrderEditBase.ofItem(
                _initialItems[item.id] ?? item,
              ).toAction(),
            },
      ],
      checks: [
        for (final c in state.checks)
          {
            'id': _isUuid(c.id) ? c.id : null,
            'position': c.position,
            'write_metadata':
                _initialChecks[c.id] == null ||
                _initialChecks[c.id]!.customerId != c.customerId ||
                _initialChecks[c.id]!.customerName != c.customerName ||
                _initialChecks[c.id]!.customerRnc != c.customerRnc ||
                _initialChecks[c.id]!.requestedNcfType != c.requestedNcfType,
            'customer_id': c.customerId,
            'customer_name': c.customerName,
            'customer_rnc': c.customerRnc,
            'requested_ncf_type': c.requestedNcfType,
            if (_initialChecks[c.id] case final original?)
              'expected_metadata': {
                'customer_id': original.customerId,
                'customer_name': original.customerName,
                'customer_rnc': original.customerRnc,
                'requested_ncf_type': original.requestedNcfType,
              },
          },
      ],
      deletedCheckIds: state.pendingDeletedCheckIds.where(_isUuid).toList(),
    );
  }

  Future<void> _commit(BillSplitEdit intent) async {
    if (state.loading) return;
    _pendingCommit = intent;
    state = state.copyWith(loading: true, error: null);
    try {
      final result = await _salesRepo.applyBillSplit(intent);
      _pendingCommit = null;
      if (!mounted) return;
      _orderVersion = result.version ?? _orderVersion;
      if (intent.equalPeople != null) {
        await initialize(state.order!);
        if (!mounted) return;
        state = state.copyWith(
          showEqualSplit: false,
          selectedItemIds: {},
          error: state.error,
        );
      } else {
        state = state.copyWith(
          loading: false,
          splitApplied: true,
          pendingDeletedCheckIds: {},
        );
        _snapshotItemAssignments(state.allItems);
      }
    } on OrderEditConflict catch (conflict) {
      _pendingCommit = null;
      _onEditConflict(
        conflict,
        what: 'la división completa',
        applyMine: () =>
            _commit(_makeCommit(force: true, equalPeople: intent.equalPeople)),
      );
    } catch (e) {
      if (!mounted) return;
      // Un rechazo SQL confirmado permite corregir la intención. Solo una
      // respuesta incierta conserva la llave/payload para consultar por replay.
      if (e is PostgrestException || e is BillSplitServerOutdated) {
        _pendingCommit = null;
      }
      final detail = e.toString();
      final known = detail.contains('OFFER_PACKAGES_NOT_DIVISIBLE')
          ? 'Las ofertas completas no se pueden repartir así. Asigna los productos manualmente.'
          : detail.contains('ACTIVE_SPLIT_EXISTS')
          ? 'La cuenta ya tiene una división. Recárgala antes de redistribuir.'
          : detail.contains('MAX_CHECKS_REACHED')
          ? 'No hay posiciones disponibles para más subcuentas.'
          : detail.contains('SPLIT_AMOUNT_MISMATCH')
          ? 'Se rechazó la división porque alteraba el importe. No se guardó ningún cambio.'
          : null;
      state = state.copyWith(
        loading: false,
        error: e is BillSplitServerOutdated
            ? BillSplitServerOutdated.message
            : known ??
                  'No se confirmó la división. Reintenta para comprobarla. ${FriendlyError.from(e)}',
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
    _initialItems = {};
    _initialChecks = {};
    _pendingCommit = null;
    state = const SplitBillState();
  }
}
