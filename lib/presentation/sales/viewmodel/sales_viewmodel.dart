import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/core/multimesero/active_waiter_provider.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/offline_queue_status_provider.dart';
import 'package:mangopos/core/offline/hub/hub_mode.dart' show kHubModeEnabled;
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/core/tax/tax_engine.dart';
import 'package:mangopos/core/tax/tax_exceptions.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'retail_carts_provider.dart';
import '../state/sales_state.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/models/order_item_tax_line.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart'
    show
        cashierViewModelProvider,
        cashierRepositoryProvider;
import '../../inventory/viewmodel/inventory_viewmodel.dart' show inventoryRepositoryProvider;
import '../../../services/fiscal/fiscal_service.dart';
import '../../../data/models/fiscal_models.dart';

final salesRepositoryProvider = Provider<SalesRepository>(
  (ref) => SalesRepository(Supabase.instance.client),
);

final printingServiceProvider = Provider<PrintingService>(
  (ref) => PrintingService(Supabase.instance.client),
);

final currentOrderProvider =
    NotifierProvider<SalesViewModel, CurrentOrderState>(SalesViewModel.new);

class SelectedModifierInput {
  final String name;
  final double qty;
  final double price;

  /// Producto-componente (menu_items.id) cuando este modifier representa la
  /// selección de un grupo de combo. NULL para modifiers normales (extras).
  /// Es la identidad que el inventario usa para descontar cada componente.
  final String? menuItemId;

  const SelectedModifierInput({
    required this.name,
    this.qty = 1,
    this.price = 0,
    this.menuItemId,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'qty': qty,
        'price': price,
        if (menuItemId != null) 'menu_item_id': menuItemId,
      };
}

class SalesViewModel extends Notifier<CurrentOrderState> {
  static const _courtesyPrefix = '[CORTESIA:';
  static const _promoPrefix = '[PROMO_AUTO:';
  // Línea vendida como OFERTA (tile del catálogo): ya viene al precio final, el
  // motor de auto-ofertas debe IGNORARLA para no volver a descontarla.
  static const _dealPrefix = '[DEAL:';
  final Map<String, CurrentOrderState> _tableCache = {};
  // Retail: slotId del carrito de venta rápida actualmente activo. null en
  // restaurante o cuando no hay carritos retail. Es la clave del snapshot
  // offline del carrito activo (persistencia por carrito). Ver
  // [retailCartsProvider] y newRetailCart/switchRetailCart.
  String? _activeRetailSlotId;
  // Tope suave de ventas rápidas simultáneas para evitar acumulación.
  static const int _maxRetailCarts = 12;
  final OfflinePosService _offlinePos = OfflinePosService();
  final ConnectivityService _connectivity = ConnectivityService();
  Timer? _refreshOrderDebounceTimer;
  /// Watchdog: si `state.loading` queda en true más de [_loadingMaxAge]
  /// (típicamente porque un `await` HTTP nunca resolvió) lo forzamos a
  /// false. Sin esto, todos los botones que dependen de orderState.loading
  /// quedaban inservibles hasta cerrar la app. Ver bug del 30/4/26 con el
  /// botón "Enviar a Cocina" gris persistente.
  Timer? _loadingWatchdogTimer;
  static const Duration _loadingMaxAge = Duration(seconds: 45);
  StreamSubscription<bool>? _connectivitySubscription;
  /// Timer de respaldo para drenar la cola offline. El sync principal lo
  /// dispara la transición offline→online del `connectionStream`, pero ese
  /// trigger puede perderse: si el stream nunca emite (el adapter nunca
  /// "bajó", solo Supabase tuvo blips) o si una acción quedó `failed` con
  /// backoff que vence mientras la app está online e inactiva, nadie la
  /// reintenta. Este timer es la red de seguridad: cada
  /// [_periodicSyncInterval], si hay conexión y pendientes, fuerza un sync.
  Timer? _periodicSyncTimer;
  static const Duration _periodicSyncInterval = Duration(minutes: 3);
  String? _queuedRefreshOrderId;
  bool _queuedClearIfPaid = false;
  bool _refreshOrderInFlight = false;
  bool _syncInFlight = false;
  String? _taxSettingsBusinessId;
  DateTime? _lastTaxLoad;
  String? _fiscalSettingsBusinessId;
  DateTime? _lastFiscalSettingsLoad;
  // Cache del employee_id derivado del usuario autenticado de Supabase.
  // Usado como fallback de `created_by_employee_id` cuando el cajero/admin
  // agrega items sin pasar por el PIN multimesero. Una sola query por
  // sesión gracias al cache.
  String? _cachedAuthEmployeeId;
  // PRD 2 §G2/G6: la única fuente de verdad para impuestos es la tabla
  // `taxes` (cargada en `_cachedBusinessTaxes`). El motor backend ya
  // consolida todos los impuestos (incluida la propina) en `oi.tax`, así
  // que el frontend NO calcula service_fee por separado.
  //
  // `_cachedTaxRatePct` se conserva como tasa de fallback para el camino
  // optimista de `addItem`/`updateItem` cuando el menu_browser no provee
  // un `productTaxRate` explícito. Si la config no carga, queda en 0 y
  // `state.taxConfigError` bloquea pagos (PRD 1).
  double _cachedTaxRatePct = 0.0;
  String _cachedDefaultFiscalType = '';
  List<Map<String, dynamic>> _cachedBusinessTaxes = const [];
  bool _hasManualFiscalTypeSelection = false;

  // Anti doble-disparo para `addItem`. No usamos un lock global porque el alta
  // es optimista y el cajero agrega varios items rápido (no hay stepper de
  // cantidad: tocar el producto N veces ES la forma de pedir N unidades). Solo
  // descartamos un segundo disparo del MISMO producto dentro de una ventana muy
  // corta (~doble-click accidental o doble evento del touchscreen). Un toque
  // deliberado a ritmo normal (>300ms) pasa sin problema.
  static const int _addItemDebounceMs = 300;
  String? _lastAddItemKey;
  int _lastAddItemMs = 0;

  // Caché en memoria de grupos de modificadores/combo por menuItemId.
  // Cada tap a un producto consulta estos grupos ANTES de agregar el item
  // (table_order_screen._handleProductTap). Sin caché eso es un round-trip a
  // Supabase en cada tap —incluso para productos sin modificadores— y el item
  // recién aparece cuando la red responde (~200ms). Cacheando, el primer tap
  // de cada producto paga la red una vez y los siguientes son instantáneos.
  // Vive lo que vive el provider (la sesión de venta). Las definiciones de
  // modificadores se configuran antes del servicio y casi no cambian en medio,
  // así que el riesgo de servir data vieja es bajo y aceptable.
  final Map<String, List<Map<String, dynamic>>> _modifierGroupsCache = {};
  final Map<String, List<Map<String, dynamic>>> _comboGroupsCache = {};

  /// Parsed tax definitions from [_cachedBusinessTaxes].
  List<TaxDef> get _taxDefs =>
      _cachedBusinessTaxes.map(TaxDef.fromMap).toList(growable: false);

  /// Resolve rates for the current (or overridden) origin using the tax engine.
  ResolvedTaxRates _resolveRatesForOrigin([String? originOverride]) {
    final origin = parseSaleOrigin(originOverride ?? state.origin);
    return resolveTaxRates(_taxDefs, origin);
  }

  double _roundMoney(double value) => double.parse(value.toStringAsFixed(2));

  /// Devuelve el `employee_id` que se debe asignar a un item recién creado
  /// como autor (`order_items.created_by_employee_id`).
  ///
  /// Política del negocio: todos los items de una mesa pertenecen al
  /// mesero que ABRIÓ esa mesa, no a quien clickeó "agregar producto".
  /// Esto mantiene una sola identidad responsable a lo largo de toda la
  /// cadena (comanda → precuenta → factura → tooltip de auditoría), aún
  /// cuando un cajero o un mesero secundario agrega items a una mesa
  /// abierta por otro mesero.
  ///
  /// Prioridad:
  ///   1. Opener de la mesa actual vía `fn_order_opener_employee_id`.
  ///      Esta es la fuente de verdad por la regla "siempre el que abrió".
  ///   2. `activeWaiterProvider` — fallback si la orden todavía no existe
  ///      (mesa nueva) o el opener no se pudo resolver. Mantiene la
  ///      identidad del mesero con PIN activo en el device.
  ///   3. Usuario autenticado en Supabase → su fila en `employees` para
  ///      el business activo, vía `fn_current_employee_id`. Cubre el
  ///      caso del cajero/admin sin PIN.
  ///   4. `null` — el item queda sin atribución y el tooltip muestra
  ///      "Sin asignar".
  ///
  /// Las dos RPCs usan SECURITY DEFINER porque RLS sobre `employees`
  /// bloquea SELECT directo desde Flutter para cajeros sin permisos
  /// especiales. Los resultados se cachean cuando aplica:
  /// - `_cachedAuthEmployeeId`: el employee del auth user (1 query por
  ///   sesión).
  /// - El opener se resuelve cada vez porque puede cambiar entre mesas;
  ///   si esto se vuelve hot path, agregar cache por orderId.
  Future<String?> _resolveItemEmployeeId() async {
    // 1) Active waiter (PIN multimesero) siempre tiene la máxima prioridad
    //    cuando está activo en el dispositivo, ya que es la persona física
    //    que está agregando el item en este momento.
    final activeWaiter = ref.read(activeWaiterProvider);
    if (activeWaiter != null) return activeWaiter.employeeId;

    // 2) Opener de la mesa actual vía `fn_order_opener_employee_id`
    //    como fallback si no hay un activeWaiter con PIN.
    final orderId = state.order?.id;
    if (orderId != null && orderId.isNotEmpty) {
      try {
        final result = await Supabase.instance.client.rpc(
          'fn_order_opener_employee_id',
          params: {'p_order_id': orderId},
        );
        final openerId = result?.toString();
        if (openerId != null && openerId.isNotEmpty) {
          return openerId;
        }
      } catch (e) {
        debugPrint('[audit] fn_order_opener_employee_id falló: $e');
      }
    }

    if (_cachedAuthEmployeeId != null) return _cachedAuthEmployeeId;

    final authUser = Supabase.instance.client.auth.currentUser;
    if (authUser == null) return null;

    final activeBusinessId = _activeBusinessId;
    if (activeBusinessId == null || activeBusinessId.isEmpty) return null;

    try {
      final result = await Supabase.instance.client.rpc(
        'fn_current_employee_id',
        params: {'p_business_id': activeBusinessId},
      );
      final resolved = result?.toString();
      if (resolved == null || resolved.isEmpty) return null;
      _cachedAuthEmployeeId = resolved;
      return resolved;
    } catch (e) {
      debugPrint('[audit] fn_current_employee_id falló: $e');
      return null;
    }
  }

  Future<void> refreshOfflineMonitor() => _refreshOfflineMonitor();

  Future<void> _refreshOfflineMonitor({
    String? syncStatus,
    bool? syncInFlight,
  }) async {
    final businessId = _activeBusinessId;
    final pending = businessId == null || businessId.isEmpty
        ? 0
        : await _offlinePos.pendingActionsCount(businessId);
    state = state.copyWith(
      isOfflineMode: !_connectivity.isConnected,
      syncInFlight: syncInFlight ?? _syncInFlight,
      pendingOfflineActions: pending,
      syncStatus: syncStatus ?? state.syncStatus,
    );
  }

  static const _refreshOrderDebounce = Duration(milliseconds: 250);

  static const _cashierClosedMessage =
      'Debes abrir la caja antes de iniciar una venta.';

  @override
  CurrentOrderState build() {
    // Owner / multi-sucursal: cuando cambia el negocio activo, todo el
    // estado de este viewmodel pertenece al negocio anterior (state.order,
    // _tableCache, suscripciones realtime, refresh encolado, cache de
    // impuestos/fiscal, etc.). Sin este reset, el siguiente addItem,
    // openTable o refresh dispara _loadOrderDetail con un orderId que el
    // backend rechaza por scope → toast "Esta orden no está disponible en
    // este negocio". Solo el rol Owner (que puede cambiar de sucursal en
    // sesión) reproduce el bug.
    ref.listen(sessionProvider.select((s) => s.activeBusinessId), (
      previous,
      next,
    ) {
      if (previous == null || previous == next) return;
      _tableCache.clear();
      _refreshOrderDebounceTimer?.cancel();
      _refreshOrderDebounceTimer = null;
      _queuedRefreshOrderId = null;
      _queuedClearIfPaid = false;
      _refreshOrderInFlight = false;
      _hasManualFiscalTypeSelection = false;
      _taxSettingsBusinessId = null;
      _lastTaxLoad = null;
      _fiscalSettingsBusinessId = null;
      _lastFiscalSettingsLoad = null;
      _cachedTaxRatePct = 0.0;
      _cachedDefaultFiscalType = '';
      _cachedBusinessTaxes = const [];
      _realtimeChannel?.unsubscribe();
      _realtimeChannel = null;
      _subscribedOrderId = null;
      // Retail: los carritos pertenecían al negocio anterior.
      _activeRetailSlotId = null;
      ref.read(retailCartsProvider.notifier).clear();
      state = const CurrentOrderState();
    });

    unawaited(_connectivity.initialize());
    unawaited(_refreshOfflineMonitor());
    _connectivitySubscription ??= _connectivity.connectionStream.listen((
      isConnected,
    ) {
      unawaited(
        _refreshOfflineMonitor(
          syncStatus: isConnected
              ? 'Conexión restaurada. Revisando sincronización...'
              : 'Sin conexión. Trabajando en modo offline.',
        ),
      );
      if (isConnected) {
        unawaited(syncPendingOfflineActions());
      }
    });

    // Red de seguridad: drena la cola periódicamente aunque el stream de
    // reconexión no haya disparado. No-op si no hay conexión, ya hay un
    // sync en vuelo, o la cola está vacía — así no genera ruido ni red
    // innecesaria.
    _periodicSyncTimer ??= Timer.periodic(_periodicSyncInterval, (_) {
      unawaited(_runPeriodicSyncTick());
    });

    // Watchdog del flag `loading`. Cualquier transición false→true arma
    // un timer que lo fuerza a false tras `_loadingMaxAge` si nunca volvió
    // por las vías normales (catch/finally). Sin esto, un await HTTP que
    // se cuelga deja todos los botones inservibles hasta cerrar la app.
    listenSelf((previous, next) {
      final wasLoading = previous?.loading ?? false;
      if (next.loading && !wasLoading) {
        _loadingWatchdogTimer?.cancel();
        _loadingWatchdogTimer = Timer(_loadingMaxAge, () {
          if (state.loading) {
            debugPrint(
              '[SalesVM] watchdog: loading=true por más de '
              '${_loadingMaxAge.inSeconds}s sin completar — forzando false.',
            );
            state = state.copyWith(loading: false);
          }
        });
      } else if (!next.loading && wasLoading) {
        _loadingWatchdogTimer?.cancel();
        _loadingWatchdogTimer = null;
      }
    });

    ref.onDispose(() {
      _realtimeChannel?.unsubscribe();
      _realtimeChannel = null;
      _subscribedOrderId = null;
      _refreshOrderDebounceTimer?.cancel();
      _refreshOrderDebounceTimer = null;
      _loadingWatchdogTimer?.cancel();
      _loadingWatchdogTimer = null;
      _periodicSyncTimer?.cancel();
      _periodicSyncTimer = null;
      _connectivitySubscription?.cancel();
      _connectivitySubscription = null;
    });
    return const CurrentOrderState();
  }

  String? get _activeBusinessId => ref.read(sessionProvider).activeBusinessId;

  String _normalizeFiscalTypeValue(String? raw) {
    final value = raw?.trim().toUpperCase() ?? '';
    if (value.isEmpty) return '';
    if (value.length >= 3 && (value.startsWith('B') || value.startsWith('E'))) {
      return value.substring(1);
    }
    return value;
  }

  bool _matchesFiscalSequenceType(FiscalNcfSequence sequence, String type) {
    final normalized = _normalizeFiscalTypeValue(type);
    if (normalized.isEmpty) return false;
    return sequence.tipo.toUpperCase() == normalized ||
        sequence.ncfType.toUpperCase() == type.trim().toUpperCase();
  }

  String _resolveFiscalTypeForState(
    CurrentOrderState source,
    List<FiscalNcfSequence> sequences,
  ) {
    final activeSequences = sequences
        .where((sequence) => sequence.activo)
        .toList(growable: false);
    final currentType = _normalizeFiscalTypeValue(source.fiscalType);
    final defaultType = _cachedDefaultFiscalType;

    final currentMatches = activeSequences.any(
      (sequence) => _matchesFiscalSequenceType(sequence, currentType),
    );

    if (_hasManualFiscalTypeSelection && currentMatches) {
      return currentType;
    }

    if (defaultType.isNotEmpty) {
      return defaultType;
    }

    if (currentMatches) {
      return currentType;
    }

    if (activeSequences.isNotEmpty) {
      return activeSequences.first.tipo;
    }

    return '';
  }

  Future<void> _ensureBusinessFiscalSettingsLoaded() async {
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      _fiscalSettingsBusinessId = null;
      _cachedDefaultFiscalType = '';
      return;
    }

    if (_fiscalSettingsBusinessId == businessId &&
        _lastFiscalSettingsLoad != null &&
        DateTime.now().difference(_lastFiscalSettingsLoad!) <
            const Duration(seconds: 1)) {
      return;
    }

    try {
      final row = await Supabase.instance.client
          .from('fiscal_settings')
          .select('default_ncf_type')
          .eq('business_id', businessId)
          .maybeSingle();

      _cachedDefaultFiscalType = _normalizeFiscalTypeValue(
        row?['default_ncf_type']?.toString(),
      );
    } catch (_) {
      _cachedDefaultFiscalType = '';
    }

    _fiscalSettingsBusinessId = businessId;
    _lastFiscalSettingsLoad = DateTime.now();
  }

  Future<void> _ensureBusinessTaxSettingsLoaded() async {
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      // Sin negocio activo no hay configuración fiscal que cargar.
      // No es un error per se: dejamos las tasas en 0 y limpiamos error previo.
      _taxSettingsBusinessId = null;
      _cachedTaxRatePct = 0.0;
      _cachedBusinessTaxes = const [];
      _setTaxConfigError(null);
      return;
    }

    if (_taxSettingsBusinessId == businessId &&
        _lastTaxLoad != null &&
        DateTime.now().difference(_lastTaxLoad!) < const Duration(seconds: 1)) {
      return;
    }

    try {
      // PRD 2 §G2: la tabla `taxes` es la única fuente de verdad para
      // impuestos. Eliminamos la lectura de `business_settings.service_fee_*`
      // y `default_tax_rate` (deprecados; PRD 3 los borra del schema).
      try {
        final taxRows = await Supabase.instance.client
            .from('taxes')
            .select(
              'name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery,apply_on_takeout,include_in_ecf',
            )
            .eq('business_id', businessId)
            .eq('is_active', true);
        _cachedBusinessTaxes = List<Map<String, dynamic>>.from(taxRows);
      } catch (e) {
        // Si falla la carga de `taxes`, no asumimos nada: lista vacía + error.
        _cachedBusinessTaxes = const [];
        throw TaxConfigException(
          'No se pudieron cargar los impuestos del negocio: $e',
        );
      }

      // PRD 2: la propina ya no se trata como concepto separado. El motor
      // backend la consolida en `oi.tax`. `_cachedTaxRatePct` se mantiene
      // sólo como fallback para los cálculos OPTIMISTAS del frontend (preview
      // antes de que el backend responda) cuando el menu_browser no envía
      // un `productTaxRate` explícito. Tomamos el primer tax no-service-fee
      // activo del negocio como fallback razonable.
      _cachedTaxRatePct = 0.0;
      for (final tx in _cachedBusinessTaxes) {
        final def = TaxDef.fromMap(tx);
        if (!def.isActive || def.rate <= 0) continue;
        if (def.effectiveIsServiceFee) continue;
        _cachedTaxRatePct = def.rate;
        break; // primer tax no-service activo
      }

      _taxSettingsBusinessId = businessId;
      _lastTaxLoad = DateTime.now();
      _setTaxConfigError(null);
    } catch (e) {
      // Fail-loud: dejamos tasas en 0, lista vacía, y marcamos error visible.
      // No relanzamos: los flujos de venta no deben crashear; el bloqueo
      // efectivo lo hace processPayment al ver state.taxConfigError.
      _cachedTaxRatePct = 0.0;
      _cachedBusinessTaxes = const [];
      _taxSettingsBusinessId = businessId;
      _lastTaxLoad = DateTime.now();
      _setTaxConfigError(
        e is TaxConfigException ? e.message : e.toString(),
      );
    }
  }

  void _setTaxConfigError(String? message) {
    if (message == null) {
      if (state.taxConfigError != null) {
        state = state.copyWith(clearTaxConfigError: true);
      }
    } else if (state.taxConfigError != message) {
      state = state.copyWith(taxConfigError: message);
    }
  }

  /// Forzar recarga de la configuración fiscal (usado por el banner UI).
  Future<void> reloadTaxConfiguration() async {
    invalidateTaxSettings();
    await _ensureBusinessTaxSettingsLoaded();
  }

  /// Fuerza recarga de las configuraciones de impuestos.
  void invalidateTaxSettings() {
    _taxSettingsBusinessId = null;
  }

  /// Expose resolved rates for the current origin (used by UI for base extraction).
  ResolvedTaxRates resolveCurrentRates() => _resolveRatesForOrigin();

  /// Returns a per-tax breakdown for display in the order summary.
  ///
  /// PRD 2: la propina ya no es un caso especial. Itera todos los taxes
  /// activos del negocio que aplican al origin actual (incluyendo
  /// is_service_fee=true como un tax más) y devuelve una entrada por cada uno.
  ///
  /// Esto se usa SÓLO como preview/predicción cuando todavía no hay items
  /// reales en la orden. Para órdenes ya cargadas, la UI debe preferir
  /// `buildBreakdownFromTaxLines(items)` (de `order_pricing_utils.dart`),
  /// que lee los snapshots reales persistidos.
  List<({String label, double amount})> getTaxBreakdown(double subtotal) {
    final origin = parseSaleOrigin(state.origin);
    final result = <({String label, double amount})>[];

    for (final tx in _taxDefs) {
      if (!tx.isActive || tx.rate <= 0) continue;
      if (!tx.appliesTo(origin)) continue;

      final pctLabel = tx.rate.truncateToDouble() == tx.rate
          ? '${tx.rate.toInt()}%'
          : '${tx.rate}%';
      final amount = _roundMoney(subtotal * tx.rateDecimal);
      result.add((label: '${tx.name} ($pctLabel)', amount: amount));
    }

    return result;
  }

  /// Defensa client-side: filtra `tax_lines` de items takeout sacando los
  /// impuestos cuyo `applyOnTakeout=false` (tipico: Ley 10%). Cubre el caso
  /// donde el backend RPC fn_toggle_item_takeout es la version vieja que
  /// solo cambia is_takeout sin recomputar tax_lines, dejando data stale
  /// en BD. Sin esto, despues de marcar "para llevar" la UI muestra el
  /// item con Ley aplicada igual.
  ///
  /// Idempotente: items que no son takeout o donde no hay nada que filtrar
  /// pasan sin cambio (referencia identica).
  ///
  /// Solo cubre el toggle ON (de dine-in a takeout). Toggle OFF tambien
  /// tiene el mismo bug en backend pero requeria re-sintetizar la Ley, que
  /// es mas complejo — para eso conviene tener la migracion 0002 aplicada.
  List<OrderItem> _filterTaxLinesByTakeout(List<OrderItem> items) {
    if (_taxDefs.isEmpty) return items;
    // TaxDef solo identifica por nombre (no tiene id). tax_lines real y
    // optimistas (taxId='tmp_tax_NAME', taxName=NAME) ambos exponen taxName,
    // asi que matchear por nombre normalizado cubre ambos casos.
    final byName = <String, bool>{};
    for (final tx in _taxDefs) {
      byName[tx.name.toLowerCase().trim()] = tx.applyOnTakeout;
    }

    return items.map((item) {
      if (!item.isTakeout || item.taxLines.isEmpty) return item;

      final filtered = item.taxLines.where((line) {
        final applies = byName[line.taxName.toLowerCase().trim()] ?? true;
        return applies;
      }).toList(growable: false);

      if (filtered.length == item.taxLines.length) return item;

      // Recompute tax_rate y tax (suma de los amounts filtrados). subtotal
      // queda igual — summarizeItemPricing recomputa para inclusive items
      // basado en applicableInclusiveRate derivado de los filtered tax_lines,
      // y para exclusive items prefiere taxLinesSum sobre item.tax.
      final newRate = filtered.fold<double>(0, (sum, l) => sum + l.taxRate);
      final newTaxAmount = filtered.fold<double>(
        0,
        (sum, l) => sum + l.amount,
      );

      return item.copyWith(
        taxLines: filtered,
        taxRate: newRate,
        tax: newTaxAmount,
      );
    }).toList(growable: false);
  }

  CurrentOrderState _normalizeHydratedState(CurrentOrderState source) {
    final order = source.order;
    if (order == null || source.items.isEmpty) {
      // Sin items, el flag takeout del state queda en false (default).
      // No persistimos el toggle del usuario sin items que reflejarlo.
      return source.copyWith(takeout: false);
    }

    final activeItems = source.items
        .where((item) => item.status != 'void')
        .toList(growable: false);
    if (activeItems.isEmpty) {
      return source.copyWith(
        takeout: false,
        order: order.copyWith(
          subtotal: 0,
          discounts: 0,
          serviceFee: 0,
          tax: 0,
          total: 0,
        ),
      );
    }

    // Hidratar state.takeout DESDE los items. Si TODOS los items abiertos
    // (no paid/void) están marcados is_takeout=true, el toggle del state
    // queda true para que items nuevos hereden el flag automáticamente
    // (ver fix en table_order_screen.dart:_handleAddProduct). Sin esta
    // hidratación, salir de la mesa y volver reseteaba state.takeout al
    // default false aunque la orden completa fuera takeout en BD —
    // próximo item agregado caía en is_takeout=false y disparaba el 10%.
    final openItems = activeItems
        .where((i) => i.status != 'paid')
        .toList(growable: false);
    final derivedTakeout =
        openItems.isNotEmpty && openItems.every((i) => i.isTakeout);

    // 3. Respetar el snapshot fiscal persistido en cada item al rehidratar.
    // Antes se reescribian taxRate/originalTaxRate con la configuracion actual
    // del negocio, lo que hacia que productos con impuesto desactivado para
    // un origin/area reaparecieran con el precio "normal" al salir y volver.
    // La DB debe ser la fuente de verdad para items ya guardados.
    //
    // EXCEPCION: filtrado client-side de tax_lines para items takeout. Si el
    // backend RPC fn_toggle_item_takeout es la version vieja (sin migracion
    // 20260502_0002), los tax_lines en BD para items takeout siguen
    // incluyendo taxes con applyOnTakeout=false (ej. Ley 10%). Los filtramos
    // aqui para que la UI no muestre el impuesto incorrecto. La fuente real
    // de verdad sigue siendo la BD via applyOnTakeout de cada tax.
    final normalizedItems = _filterTaxLinesByTakeout(activeItems);

    // 4. Calcular pricing.
    // PRD 2: el motor backend consolida la propina dentro de `oi.tax`, así
    // que el frontend no necesita un "contexto" especial para service fee.
    // `summarizeOrderPricing` lee `item.taxLines` (PRD 2) o cae al path
    // heurístico viejo si la orden es pre-PRD-2.
    final pricingOrder = order.copyWith(serviceFee: 0);

    final orderSummary = summarizeOrderPricing(pricingOrder, normalizedItems);
    // PRD 2 (motor unificado): persistir SIEMPRE serviceFee=0 en el state
    // local. Si dejamos el `orderSummary.serviceFee` derivado (que separa
    // la propina inclusive en otra columna), `resolveOrderServiceRate` lo
    // lee como tasa efectiva en la próxima llamada y aplica una propina
    // fantasma a items exclusive (caso reproducido 2026-04-28: total
    // 568.43 vs 564.00 esperado).
    //
    // El total persistido también se recalcula sin esa columna falsa.
    final normalizedOrder = order.copyWith(
      subtotal: orderSummary.subtotal,
      discounts: orderSummary.discounts,
      serviceFee: 0,
      tax: orderSummary.tax,
      total: orderSummary.subtotal +
          orderSummary.tax +
          orderSummary.serviceFee -
          orderSummary.discounts,
    );

    final normalizedChecks = source.checks
        .map((check) {
          final checkItems = activeItems
              .where((item) => item.checkId == check.id)
              .toList(growable: false);
          if (checkItems.isEmpty) {
            return check;
          }

          final checkSummary = summarizeOrderPricing(
            check.toOrder(createdAt: order.createdAt).copyWith(serviceFee: 0),
            checkItems,
          );

          return check.copyWith(
            subtotal: checkSummary.subtotal,
            discounts: checkSummary.discounts,
            serviceFee: 0, // PRD 2: motor unificado
            tax: checkSummary.tax,
            total: checkSummary.subtotal +
                checkSummary.tax +
                checkSummary.serviceFee -
                checkSummary.discounts,
          );
        })
        .toList(growable: false);

    return source.copyWith(
      order: normalizedOrder,
      checks: normalizedChecks,
      items: normalizedItems,
      takeout: derivedTakeout,
    );
  }

  Future<void> _persistCurrentState({
    String? tableId,
    bool localOnly = false,
  }) async {
    final businessId = _activeBusinessId;
    final origin = state.origin;
    if (businessId == null ||
        businessId.isEmpty ||
        origin == null ||
        state.order == null) {
      return;
    }

    await _offlinePos.saveSnapshot(
      businessId: businessId,
      slotId: _resolvePersistSlotId(origin, tableId),
      origin: origin,
      tableId: tableId,
      state: state,
      localOnly: localOnly,
    );
  }

  /// Clave de snapshot para persistir el state actual. Retail quick usa el
  /// slotId del carrito activo (un snapshot por carrito); el resto conserva el
  /// comportamiento legacy (sessionId para mesas, origin para quick/manual).
  String _resolvePersistSlotId(String origin, String? tableId) {
    if (tableId != null) return tableId;
    if (origin == 'quick' && _activeRetailSlotId != null) {
      return _activeRetailSlotId!;
    }
    if (origin == 'table') return state.order?.sessionId ?? origin;
    return origin;
  }

  Future<bool> ensureCashSessionOpen() async {
    final cashierVm = ref.read(cashierViewModelProvider);
    try {
      // force: true bypassea el TTL de 12s del cache (`_lastCashOpenValidationAt`).
      // El cache producía falsos negativos cuando la caja se abría en otro
      // proceso/empleado y este viewmodel aún tenía `_lastSession` stale.
      final isOpen = await cashierVm.ensureCashOpenFast(force: true);
      if (!isOpen) {
        state = state.copyWith(loading: false, error: _cashierClosedMessage);
        return false;
      }
      return true;
    } catch (_) {
      state = state.copyWith(loading: false, error: _cashierClosedMessage);
      return false;
    }
  }

  Future<void> openTable(String tableId, {int peopleCount = 1}) async {
    // ⚡ Fix anti-parpadeo: reset SÍNCRONO del state ANTES de cualquier
    // await. Antes los checks de caja + business tax se ejecutaban
    // primero (cada uno con await) y durante esos ~200-400ms la UI
    // seguía mostrando la orden de la mesa anterior — el usuario veía
    // los items viejos parpadear y luego limpiarse cuando finalmente
    // llegaba el state nuevo.
    //
    // Si tenemos cache de esta mesa específica, mostramos eso (para
    // que abrir una mesa ya visitada se sienta instantáneo). Si no,
    // limpiamos completo. La data autoritativa llega en _loadOrderDetail.
    final cached = _tableCache[tableId];
    if (cached != null) {
      state = _normalizeHydratedState(
        cached.copyWith(
          loading: true,
          error: null,
          checks: const [],
          clearSelectedCheck: true,
        ),
      );
    } else {
      _hasManualFiscalTypeSelection = false;
      state = const CurrentOrderState(loading: true, origin: 'table');
    }

    // Solo los roles con permisos de caja (cajero/admin/manager) necesitan
    // una sesión de caja abierta. Los meseros pueden abrir mesas directamente.
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final hasCashierAccess = sessionCtrl.hasAnyPermission([
      'caja.apertura',
      'caja.cierre',
      'caja.movimientos_ver',
    ]);
    if (hasCashierAccess) {
      if (!await ensureCashSessionOpen()) return;
    }
    await _ensureBusinessTaxSettingsLoaded();
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;

      // Modo multimesero: si hay un activeWaiter validado en este device,
      // lo pasamos como opened_by_employee_id para trackear quién abre.
      // Si la mesa ya estaba abierta, el RPC NO sobreescribe el opened_by
      // original (es inmutable después del primer INSERT).
      final activeWaiter = ref.read(activeWaiterProvider);

      // Single round-trip: abrir mesa + cargar bundle completo (order +
      // items + checks + customer + modifiers + tax_lines). Antes eran
      // 3-4 queries en serie (openTable + getTableLive + getOrderBundle
      // + modifiers + tax_lines) tardando ~700-900ms. El RPC consolida
      // todo en ~150ms.
      final result = await ref.read(salesRepositoryProvider).openTableAndLoad(
            tableId: tableId,
            userId: userId,
            peopleCount: peopleCount,
            openedByEmployeeId: activeWaiter?.employeeId,
          );
      final orderId = result.orderId;

      // Aplicar el bundle ya parseado — _loadOrderDetail acepta un
      // preloaded para saltarse el fetch y solo correr el post-load
      // (fiscal sequences, normalización de state, etc).
      await _loadOrderDetail(
        orderId,
        origin: 'table',
        tableId: tableId,
        caller: 'openTable',
        preloadedBundle: result.bundle,
      );
    } catch (e) {
      final businessId = _activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        // 1. Snapshot previo (la mesa ya se abrió antes online u offline).
        final offlineState = await _offlinePos.loadSnapshot(
          businessId: businessId,
          slotId: tableId,
        );
        if (offlineState != null) {
          state = _normalizeHydratedState(
            offlineState.copyWith(
              loading: false,
              error: 'Modo offline: usando copia local de la mesa.',
              origin: 'table',
            ),
          );
          _tableCache[tableId] = state;
          return;
        }

        // 2. Sin snapshot previo pero estamos offline: crear draft local
        //    nuevo. `_resolveOrderIdForAction` con origin='table' usará el
        //    tableId al sincronizar para abrir la mesa real en el server.
        //    Solo cuando estamos offline — si Supabase respondió error real
        //    (server down con LAN OK), `_connectivity.isConnected` baja por
        //    el healthcheck y entramos aquí; si fue otro error transitorio
        //    propagamos al usuario.
        if (!_connectivity.isConnected) {
          final draft = await _offlinePos.createLocalDraft(
            businessId: businessId,
            origin: 'table',
            tableId: tableId,
          );
          state = _normalizeHydratedState(
            draft.copyWith(
              loading: false,
              error:
                  'Mesa abierta offline: los items se sincronizarán al recuperar conexión.',
            ),
          );
          _tableCache[tableId] = state;
          return;
        }
      }
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> openManual({bool forceRestart = false}) async =>
      _openManualOrQuick('manual', forceReset: forceRestart);
  Future<void> openQuick({bool forceRestart = false}) async =>
      _openManualOrQuick('quick', forceReset: forceRestart);

  Future<void> ensureManualOrder() async {
    // Reusar solo si la orden está abierta. Si fue paid/voided/sent y el
    // usuario vuelve al tab, se abre una nueva sesión Manual limpia.
    final current = state.order;
    if (state.origin == 'manual' &&
        current != null &&
        current.status == 'open') {
      return;
    }
    await openManual(forceRestart: true);
  }

  bool get _isRetail => ref.read(currentBusinessModelProvider).isRetail;

  Future<void> ensureQuickOrder() async {
    // Retail: la venta rápida soporta varios carritos simultáneos. En vez de
    // reabrir una única sesión quick, inicializamos/restauramos los carritos.
    if (_isRetail) {
      await _ensureRetailCartsInitialized();
      return;
    }
    // Restaurante: reusar solo si la orden está abierta. Si fue paid/voided/sent
    // y el usuario vuelve al tab, se abre una nueva sesión Quick limpia.
    final current = state.order;
    if (state.origin == 'quick' &&
        current != null &&
        current.status == 'open') {
      return;
    }
    await openQuick(forceRestart: true);
  }

  // ===========================================================================
  // RETAIL — carritos de venta rápida simultáneos (solo modo retail).
  // currentOrderProvider sigue mostrando el carrito ACTIVO; retailCartsProvider
  // mantiene la lista de pestañas. Cada carrito es una sesión quick aparte.
  // ===========================================================================

  /// Al entrar a venta rápida en retail: si ya hay carritos en memoria activa
  /// el actual; si no, intenta restaurar de disco; si tampoco, crea el primero.
  Future<void> _ensureRetailCartsInitialized() async {
    final carts = ref.read(retailCartsProvider);
    if (carts.carts.isNotEmpty) {
      final active = carts.active ?? carts.carts.first;
      // Si el state ya muestra ese carrito y su orden está cargada, no hacemos
      // nada (evita recargar al volver a entrar a la pantalla).
      if (_activeRetailSlotId == active.slotId && state.order != null) {
        ref.read(retailCartsProvider.notifier).setActive(active.slotId);
        return;
      }
      await switchRetailCart(active.slotId);
      return;
    }
    final restored = await restoreRetailCarts();
    if (restored) return;
    await newRetailCart();
  }

  /// Crea un carrito de venta rápida nuevo SIN cerrar los demás y lo activa.
  Future<void> newRetailCart() async {
    if (!_isRetail) return;
    // Persistir el carrito activo actual antes de cambiar de slot.
    await _persistCurrentState();

    await _ensureBusinessTaxSettingsLoaded();
    if (!await ensureCashSessionOpen()) return;

    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudo identificar el negocio.',
      );
      return;
    }

    if (ref.read(retailCartsProvider).carts.length >= _maxRetailCarts) {
      state = state.copyWith(
        loading: false,
        error: 'Máximo de $_maxRetailCarts ventas rápidas simultáneas.',
      );
      return;
    }

    final slotId = 'quick-${const Uuid().v4()}';
    _activeRetailSlotId = slotId;
    ref.read(retailCartsProvider.notifier).addCart(slotId: slotId);
    state = const CurrentOrderState(loading: true, origin: 'quick');

    try {
      // RPC dedicado: mesa virtual por carrito → NO anula las otras ventas
      // rápidas abiertas (a diferencia de openManualOrQuick).
      final res = await ref.read(salesRepositoryProvider).openRetailCart(
            slot: slotId,
            businessId: businessId,
            peopleCount: 1,
          );
      final orderId = res['order_id'] as String;
      ref.read(retailCartsProvider.notifier).setOrderId(slotId, orderId);
      await _loadOrderDetail(orderId, origin: 'quick', caller: 'newRetailCart');
    } catch (e) {
      if (!_connectivity.isConnected) {
        // Offline: draft local con este slot. Al sincronizar, el replay abre la
        // sesión quick real y remapea el local-order-… (igual que las mesas).
        final draft = await _offlinePos.createLocalDraft(
          businessId: businessId,
          origin: 'quick',
          slotId: slotId,
        );
        ref
            .read(retailCartsProvider.notifier)
            .setOrderId(slotId, draft.order!.id);
        state = _normalizeHydratedState(
          draft.copyWith(
            loading: false,
            error: 'Venta abierta offline: se sincronizará al reconectar.',
          ),
        );
      } else {
        state = state.copyWith(
          loading: false,
          error: 'No se pudo abrir la venta rápida: $e',
        );
      }
    }
    await _persistRetailCartsIndex();
  }

  /// Cambia el carrito activo: persiste el actual y carga la orden del carrito
  /// destino en `currentOrderProvider`.
  Future<void> switchRetailCart(String slotId) async {
    if (!_isRetail) return;
    if (_activeRetailSlotId == slotId && state.order != null) {
      ref.read(retailCartsProvider.notifier).setActive(slotId);
      return;
    }

    await _persistCurrentState();

    RetailCart? cart;
    for (final c in ref.read(retailCartsProvider).carts) {
      if (c.slotId == slotId) {
        cart = c;
        break;
      }
    }
    if (cart == null) return;

    _activeRetailSlotId = slotId;
    ref.read(retailCartsProvider.notifier).setActive(slotId);
    state = const CurrentOrderState(loading: true, origin: 'quick');

    final orderId = cart.orderId;
    if (orderId != null && !orderId.startsWith('local-order-')) {
      try {
        await _loadOrderDetail(
          orderId,
          origin: 'quick',
          caller: 'switchRetailCart',
        );
        await _persistRetailCartsIndex();
        return;
      } catch (_) {
        // cae al snapshot offline abajo
      }
    }

    final businessId = _activeBusinessId;
    if (businessId != null && businessId.isNotEmpty) {
      final snap = await _offlinePos.loadSnapshot(
        businessId: businessId,
        slotId: slotId,
      );
      if (snap != null) {
        state = _normalizeHydratedState(
          snap.copyWith(loading: false, origin: 'quick'),
        );
        await _persistRetailCartsIndex();
        return;
      }
    }
    state = state.copyWith(
      loading: false,
      error: 'No se pudo cargar esta venta.',
    );
  }

  /// Cierra una pestaña de carrito (descarta su orden si tiene). Devuelve a
  /// otro carrito o crea uno vacío si era el último.
  Future<void> closeRetailCart(String slotId) async {
    if (!_isRetail) return;
    final notifier = ref.read(retailCartsProvider.notifier);

    // Si el carrito a cerrar es el activo y tiene una orden con items, la
    // anulamos (cancelCurrentOrder ya manela online/offline). Si es otro
    // carrito, solo limpiamos su snapshot (su orden quedará abierta en server,
    // recuperable; no la tocamos para no requerir cargarla solo para anular).
    if (slotId == _activeRetailSlotId &&
        state.order != null &&
        state.items.where((i) => i.status != 'void').isNotEmpty) {
      await cancelCurrentOrder();
    } else {
      final businessId = _activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        await _offlinePos.saveSnapshot(
          businessId: businessId,
          slotId: slotId,
          origin: 'quick',
          state: const CurrentOrderState(),
          localOnly: true,
        );
      }
    }

    final next = notifier.removeCart(slotId);
    if (slotId == _activeRetailSlotId) {
      _activeRetailSlotId = null;
      if (next != null) {
        await switchRetailCart(next);
      } else {
        state = const CurrentOrderState();
        await newRetailCart();
      }
    }
    await _persistRetailCartsIndex();
  }

  /// Restaura las pestañas de carritos desde disco (tras reinicio). Devuelve
  /// true si había carritos guardados.
  Future<bool> restoreRetailCarts() async {
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return false;
    final idx = await _offlinePos.loadRetailCartsIndex(businessId: businessId);
    if (idx == null || idx.carts.isEmpty) return false;
    final carts = idx.carts
        .map((m) => RetailCart.fromMap(m))
        .toList(growable: false);
    final active = idx.activeSlotId ?? carts.first.slotId;
    ref.read(retailCartsProvider.notifier).replaceAll(carts, active);
    await switchRetailCart(active);
    return true;
  }

  Future<void> _persistRetailCartsIndex() async {
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    final s = ref.read(retailCartsProvider);
    await _offlinePos.saveRetailCartsIndex(
      businessId: businessId,
      carts: s.carts.map((c) => c.toMap()).toList(growable: false),
      activeSlotId: s.activeSlotId,
    );
  }

  /// Tras cobrar el carrito activo (retail): limpia su snapshot, quita la
  /// pestaña y pasa a otro carrito (o crea uno vacío si era el último).
  Future<void> _finalizeActiveRetailCartAfterPayment() async {
    final slotId = _activeRetailSlotId;
    final businessId = _activeBusinessId;
    if (slotId != null && businessId != null && businessId.isNotEmpty) {
      await _offlinePos.saveSnapshot(
        businessId: businessId,
        slotId: slotId,
        origin: 'quick',
        state: const CurrentOrderState(),
        localOnly: true,
      );
    }
    final next = slotId != null
        ? ref.read(retailCartsProvider.notifier).removeCart(slotId)
        : null;
    _activeRetailSlotId = null;
    if (next != null) {
      await switchRetailCart(next);
    } else {
      state = const CurrentOrderState();
      await newRetailCart();
    }
    await _persistRetailCartsIndex();
  }

  /// Abre una orden de delivery existente (ya creada por DeliveryViewModel).
  Future<void> openDeliveryOrder({
    required String tableId,
    String? deliveryType,
  }) async {
    await _ensureBusinessTaxSettingsLoaded();
    if (!await ensureCashSessionOpen()) return;
    state = state.copyWith(loading: true, error: null);
    try {
      await openTable(tableId, peopleCount: 1);
      state = state.copyWith(origin: 'delivery', deliveryType: deliveryType);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> assignManualOrderToTable({
    required String orderId,
    required String tableId,
  }) async {
    if (!await ensureCashSessionOpen()) return;

    state = state.copyWith(loading: true, error: null);
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      await ref
          .read(salesRepositoryProvider)
          .assignManualOrderToTable(
            orderId: orderId,
            tableId: tableId,
            userId: userId,
          );
      await openTable(tableId);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> assignCustomerToCurrentOrder({
    required String customerId,
    required String customerName,
    String? customerLegalName,
    String? customerTaxId,
  }) async {
    final order = state.order;
    if (order == null) return;

    try {
      await ref
          .read(salesRepositoryProvider)
          .assignCustomerToSession(
            sessionId: order.sessionId,
            customerId: customerId,
            customerName: customerName,
            businessId: _activeBusinessId,
          );
      state = state.copyWith(
        customerId: customerId,
        customerName: customerName,
        customerLegalName: customerLegalName,
        customerTaxId: customerTaxId,
      );
      // Retail: reflejar el cliente en la etiqueta de la pestaña del carrito.
      if (_isRetail && _activeRetailSlotId != null) {
        ref
            .read(retailCartsProvider.notifier)
            .setCustomerName(_activeRetailSlotId!, customerName);
        await _persistRetailCartsIndex();
      }
      await _loadOrderDetail(
        order.id,
        origin: state.origin,
        caller: 'assignCustomer',
      );
    } catch (e) {
      state = state.copyWith(error: 'Error al asignar cliente: $e');
    }
  }

  /// Asigna un cliente a una sub-cuenta (check) puntual en vez de a la
  /// sesión completa. Se usa cuando el cajero tiene una sub-cuenta
  /// seleccionada en el header: el cliente debe quedar en `order_checks`
  /// de ese check, no en `table_sessions` (general). Antes este flujo
  /// siempre caía en [assignCustomerToCurrentOrder] → assignCustomerToSession
  /// y "machacaba" todas las sub-cuentas con el mismo nombre general.
  Future<void> assignCustomerToCheck({
    required String checkId,
    required String customerId,
    required String customerName,
  }) async {
    final order = state.order;
    if (order == null) return;

    try {
      await ref
          .read(salesRepositoryProvider)
          .assignCustomerToCheck(
            checkId: checkId,
            customerId: customerId,
            customerName: customerName,
          );
      // Reflejar de inmediato en el check local para que el chip del header
      // y los tabs muestren el nombre sin esperar al reload del bundle.
      final updatedChecks = state.checks
          .map(
            (c) => c.id == checkId
                ? c.copyWith(customerId: customerId, customerName: customerName)
                : c,
          )
          .toList(growable: false);
      state = state.copyWith(checks: updatedChecks);
      await _loadOrderDetail(
        order.id,
        origin: state.origin,
        caller: 'assignCustomerToCheck',
      );
    } catch (e) {
      state = state.copyWith(
        error: 'Error al asignar cliente a la subcuenta: $e',
      );
    }
  }

  void updateFiscalType(String type) {
    _hasManualFiscalTypeSelection = true;
    state = state.copyWith(fiscalType: _normalizeFiscalTypeValue(type));
  }

  Future<void> updateCurrentSessionNote(String? note) async {
    final order = state.order;
    if (order == null) return;

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateSessionNote(
            sessionId: order.sessionId,
            note: note,
            businessId: _activeBusinessId,
          );
      state = state.copyWith(
        sessionNote: note?.trim(),
        clearSessionNote: note == null,
      );
    } catch (e) {
      state = state.copyWith(error: 'Error al actualizar nota de sesión: $e');
      rethrow;
    }
  }

  Future<void> appendVoidAuditNote({required String reason}) async {
    final order = state.order;
    if (order == null) return;

    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) return;

    final userName = ref.read(sessionProvider).userName?.trim() ?? '';
    final stamp = DateTime.now().toLocal().toIso8601String();
    final auditLine =
        '[ANULACION][$stamp] ${userName.isEmpty ? 'Usuario' : userName}: $trimmedReason';

    final current = state.sessionNote?.trim();
    final nextNote = (current == null || current.isEmpty)
        ? auditLine
        : '$current\n$auditLine';

    await updateCurrentSessionNote(nextNote);
  }

  Future<void> _openManualOrQuick(
    String origin, {
    bool forceReset = false,
  }) async {
    await _ensureBusinessTaxSettingsLoaded();
    if (!await ensureCashSessionOpen()) return;

    state = forceReset
        ? const CurrentOrderState(loading: true)
        : state.copyWith(loading: true, error: null);
    try {
      final res = await ref
          .read(salesRepositoryProvider)
          .openManualOrQuick(
            origin: origin,
            customerName: null,
            peopleCount: 1,
            businessId: _activeBusinessId,
          );
      await _loadOrderDetail(
        res['order_id'] as String,
        origin: origin,
        caller: 'openManualOrQuick:$origin',
      );
    } catch (e) {
      final businessId = _activeBusinessId;
      // PRD 2.5: ignoramos completamente el cache offline para Quick/Manual.
      // Cada sesión Quick/Manual es fresca por definición — recuperar state
      // viejo solo causa contaminación (orders zombie, items que se asignan
      // a sesiones equivocadas). Si el RPC falla, surfaceamos el error real
      // para que el operador entienda qué pasa en vez de ver una venta vieja
      // como si fuera nueva.
      //
      // Limpiamos también el slot del cache para prevenir contaminación futura.
      if (businessId != null && businessId.isNotEmpty) {
        await _offlinePos.saveSnapshot(
          businessId: businessId,
          slotId: origin,
          origin: origin,
          state: const CurrentOrderState(),
          localOnly: true,
        );
      }
      state = state.copyWith(
        loading: false,
        error: 'No se pudo abrir Venta ${origin == 'quick' ? 'Rápida' : 'Manual'}: $e',
      );
    }
  }

  Future<void> addItem({
    required String menuItemId,
    double qty = 1,
    int checkPos = 1,
    bool takeout = false,
    String? notes,
    String? productName,
    double? productPrice,
    String productTaxMode = 'exclusive',
    double? productTaxRate,
    double? productFullTaxRate,
    List<SelectedModifierInput> selectedModifiers = const [],
  }) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.agregar_item')) {
      state = state.copyWith(
        error: 'No tienes permiso para agregar productos a la orden.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null) {
      state = state.copyWith(error: 'Orden no disponible. Reintenta.');
      return;
    }

    // Anti doble-click: descarta el segundo disparo del mismo producto (con los
    // mismos modifiers) dentro de _addItemDebounceMs. Ver nota del campo.
    final addKey = '$menuItemId|$takeout|'
        '${selectedModifiers.map((m) => '${m.name}x${m.qty}').join(',')}';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastAddItemKey == addKey &&
        nowMs - _lastAddItemMs < _addItemDebounceMs) {
      return;
    }
    _lastAddItemKey = addKey;
    _lastAddItemMs = nowMs;

    // PRD 4: bloqueo defensivo. Si la orden activa ya fue cobrada o anulada,
    // el state está stale — no podemos agregar items a una orden cerrada.
    // Forzamos re-apertura según origin para que el próximo add vaya a una
    // orden fresca. Solo rechazamos en estados terminales conocidos
    // (paid/void); cualquier otro estado pasa y deja seguir el flujo normal.
    final currentStatus = state.order?.status;
    if (currentStatus == 'paid' || currentStatus == 'void') {
      final origin = state.origin;
      state = state.copyWith(
        error: 'La orden anterior ya fue cerrada. Iniciando una nueva.',
      );
      if (origin == 'quick') {
        await openQuick(forceRestart: true);
      } else if (origin == 'manual') {
        await openManual(forceRestart: true);
      }
      return;
    }

    // Si hay un check seleccionado y SIGUE ABIERTO, usar su posición. Si está
    // cerrado (ej. ya cobrado), caer al principal (C1) — agregar items a un
    // check cerrado deja items huérfanos que el cajero no puede tocar y
    // confunde el cálculo de "lo pendiente" en la mesa.
    int effectiveCheckPos = checkPos;
    if (checkPos == 1 && state.selectedCheckId != null) {
      try {
        final check = state.checks.firstWhere(
          (c) => c.id == state.selectedCheckId && !c.isClosed,
        );
        effectiveCheckPos = check.position;
      } catch (_) {
        // Check no encontrado o cerrado → item va al principal.
        // Limpiar selectedCheckId para que la UI no siga mostrándolo
        // como filtro activo cuando ya no aplica.
        state = state.copyWith(clearSelectedCheck: true);
      }
    }

    state = state.copyWith(error: null);
    final previousItems = state.items;
    final previousOrder = state.order;

    await _ensureBusinessTaxSettingsLoaded();

    // PRD 2: el motor backend asigna `tax_rate` ya consolidado (incluye
    // propina si aplica). El frontend optimista usa el rate provisto por
    // el menu_browser tal cual; si no viene, fallback a `_cachedTaxRatePct`.
    // No hay path separado para service_fee.
    final resolvedTaxRate = productTaxRate ?? _cachedTaxRatePct;
    final resolvedFullTaxRate =
        productFullTaxRate ?? productTaxRate ?? _cachedTaxRatePct;

    // Optimistic: solo si tenemos datos del producto y un order cargado
    OrderItem? optimisticItem;
    if (productName != null &&
        productPrice != null &&
        previousOrder != null &&
        qty > 0) {
      final tempId = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
      // modifiersPerUnit es el costo de modifiers por UNA unidad del item.
      // Multiplicamos despues por qty para que coincida con el trigger backend
      // fn_compute_item_totals (migration 20260509_0004).
      final modifiersPerUnit = selectedModifiers.fold<double>(
        0,
        (sum, modifier) => sum + (modifier.price * modifier.qty),
      );
      final grossAmount = qty * (productPrice + modifiersPerUnit);

      // El estimador recibe la tasa como fracción decimal (0.18 = 18%).
      final taxRateDecimal = resolvedTaxRate / 100.0;
      final fullTaxRateDecimal = resolvedFullTaxRate / 100.0;
      final optimisticAmounts = _estimateOptimisticItemAmounts(
        grossAmount: grossAmount,
        taxMode: productTaxMode,
        taxRate: taxRateDecimal,
        fullTaxRate: fullTaxRateDecimal,
        serviceRate: 0.0, // PRD 2: motor unificado, sin path separado
        includeServiceInInclusivePrice: false,
      );

      // Sintetiza tax_lines para que el panel de totales muestre el desglose
      // completo (ITBIS + 10% De Ley + cualquier otro tax activo) desde el
      // primer render. Sin esto, solo aparece ITBIS via la heuristica vieja
      // y "10% De Ley" pop-in cuando llega la respuesta del backend (~1-2s
      // despues), causando un salto del total. Replicamos el filtrado del
      // RPC fn_resolve_order_item_tax_profile (origin + takeout).
      final originForTaxes = parseSaleOrigin(state.origin);
      final synthTimestamp = DateTime.now();
      final taxBase = optimisticAmounts.subtotal;
      final synthTaxLines = <OrderItemTaxLine>[];
      for (var i = 0; i < _taxDefs.length; i++) {
        final taxDef = _taxDefs[i];
        if (!taxDef.isActive || taxDef.rate <= 0) continue;
        final appliesToOrigin = switch (originForTaxes) {
          SaleOrigin.zone => taxDef.applyOnZone,
          SaleOrigin.manual => taxDef.applyOnManual,
          SaleOrigin.quick => taxDef.applyOnQuick,
          SaleOrigin.delivery => taxDef.applyOnDelivery,
          SaleOrigin.unknown => true,
        };
        if (!appliesToOrigin) continue;
        if (takeout && !taxDef.applyOnTakeout) continue;
        final amount = double.parse(
          (taxBase * taxDef.rate / 100.0).toStringAsFixed(2),
        );
        if (amount <= 0.004) continue;
        synthTaxLines.add(
          OrderItemTaxLine(
            id: 'tmp_tl_${synthTimestamp.microsecondsSinceEpoch}_$i',
            orderItemId: tempId,
            taxId: 'tmp_tax_${taxDef.name}',
            taxName: taxDef.name,
            taxRate: taxDef.rate,
            amount: amount,
            createdAt: synthTimestamp,
          ),
        );
      }

      // Item optimista: mostramos de inmediato el mesero activo (PIN
      // multimesero) si lo hay. La resolución completa del employee_id para
      // persistir se hace aparte vía _resolveItemEmployeeId().
      final activeWaiter = ref.read(activeWaiterProvider);
      optimisticItem = OrderItem(
        id: tempId,
        orderId: orderId,
        productId: menuItemId,
        productName: productName,
        sku: null,
        quantity: qty,
        unitPrice: productPrice,
        subtotal: optimisticAmounts.subtotal,
        discounts: 0,
        tax: optimisticAmounts.tax,
        total: optimisticAmounts.total,
        checkId: null,
        isTakeout: takeout,
        status: 'draft',
        notes: notes,
        taxMode: productTaxMode,
        taxRate: resolvedTaxRate,
        originalTaxRate: resolvedFullTaxRate,
        createdAt: DateTime.now(),
        createdByEmployeeId: activeWaiter?.employeeId,
        createdByEmployeeName: activeWaiter?.displayName,
        modifiers: selectedModifiers
            .map(
              (modifier) => OrderItemModifier(
                id: 'tmp_mod_${DateTime.now().microsecondsSinceEpoch}_${modifier.name}',
                itemId: tempId,
                name: modifier.name,
                qty: modifier.qty,
                price: modifier.price,
              ),
            )
            .toList(growable: false),
        taxLines: synthTaxLines,
      );

      final optimisticItems = [...state.items, optimisticItem];
      final updatedSummary = summarizeOrderPricing(
        previousOrder.copyWith(serviceFee: 0),
        optimisticItems,
      );
      final updatedOrder = previousOrder.copyWith(
        subtotal: updatedSummary.subtotal,
        tax: updatedSummary.tax,
        serviceFee: 0,
        total: updatedSummary.subtotal +
            updatedSummary.tax -
            updatedSummary.discounts,
      );

      state = state.copyWith(
        items: [...state.items, optimisticItem],
        order: updatedOrder,
      );
    }

    try {
      final itemId = await ref
          .read(salesRepositoryProvider)
          .addItemFromMenu(
            orderId: orderId,
            menuItemId: menuItemId,
            quantity: qty,
            checkPosition: effectiveCheckPos,
            isTakeout: takeout,
            notes: notes,
          );

      // Audit trail del item: ver `_resolveItemEmployeeId` arriba.
      //
      // 1) Modo multimesero: si hay `activeWaiter` (el mesero metió PIN al
      //    entrar a la mesa), usamos su employeeId.
      // 2) Fallback: cuando un admin/cajero agrega items sin pasar por el
      //    flow de PIN (`activeWaiter == null`), resolvemos su employee_id
      //    desde el usuario autenticado de Supabase. Sin esto, todos los
      //    items que mete el cajero quedaban como "Sin asignar".
      if (itemId.isNotEmpty) {
        final employeeId = await _resolveItemEmployeeId();
        if (employeeId != null) {
          try {
            await Supabase.instance.client
                .from('order_items')
                .update({'created_by_employee_id': employeeId})
                .eq('id', itemId);
          } catch (e) {
            debugPrint('[audit] no se pudo set created_by_employee_id: $e');
            // No abortamos el flujo — el item igual quedó creado.
          }
        }
      }

      if (selectedModifiers.isNotEmpty) {
        await ref
            .read(salesRepositoryProvider)
            .addOrderItemModifiers(
              itemId: itemId,
              modifiers: selectedModifiers
                  .map((modifier) => modifier.toMap())
                  .toList(growable: false),
            );
      }

      // Bypassear el debounce para que la respuesta sea instantánea
      await _loadOrderDetail(orderId, caller: 'addItem');
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');

      if (isOffline &&
          optimisticItem != null &&
          businessId != null &&
          businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'add_item',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': optimisticItem.id,
            'menu_item_id': menuItemId,
            'qty': qty,
            'check_pos': effectiveCheckPos,
            'takeout': takeout,
            'notes': notes,
            'product_name': productName,
            'product_price': productPrice,
            // Snapshot de modifiers seleccionados. Al sincronizar el replay
            // los re-aplica vía addOrderItemModifiers contra el item ya
            // creado en el server. Antes esto se perdía y los extras nunca
            // llegaban al server (bug del audit offline §sync).
            'selected_modifiers': selectedModifiers
                .map((m) => m.toMap())
                .toList(growable: false),
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Producto agregado en local. Pendiente de sincronizar.',
        );
        return;
      }

      // Revertir si hicimos optimismo
      if (optimisticItem != null) {
        state = state.copyWith(
          items: previousItems,
          order: previousOrder,
          error: 'Error al agregar: $e',
        );
      } else {
        state = state.copyWith(error: 'Error al agregar producto: $e');
      }
    }
  }

  /// Agrega una OFERTA vendible (tile "deal" del catálogo). Inserta [buyQty]
  /// líneas separadas del producto (1 c/u) — NO una sola línea de cantidad N —
  /// porque el motor BOGO descuenta por línea. Tras agregarlas, recarga la orden
  /// y el motor auto-aplica el descuento (ej. 4x3 → cobra 3). Va por el repo
  /// directo a propósito, saltando el anti-doble-clic de addItem.
  Future<void> addOfferDeal({
    required String menuItemId,
    required int lineQty,
    required double discount,
    required String name,
    required double originalPrice,
    String? promotionId,
    String productTaxMode = 'exclusive',
    double? productTaxRate,
    int checkPos = 1,
  }) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.agregar_item')) {
      state = state.copyWith(
        error: 'No tienes permiso para agregar productos a la orden.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null) {
      state = state.copyWith(error: 'Orden no disponible. Reintenta.');
      return;
    }
    final currentStatus = state.order?.status;
    if (currentStatus == 'paid' || currentStatus == 'void') {
      final origin = state.origin;
      state = state.copyWith(
        error: 'La orden anterior ya fue cerrada. Iniciando una nueva.',
      );
      if (origin == 'quick') {
        await openQuick(forceRestart: true);
      } else if (origin == 'manual') {
        await openManual(forceRestart: true);
      }
      return;
    }

    // Respetar el check seleccionado si sigue abierto (igual que addItem).
    int effectiveCheckPos = checkPos;
    if (checkPos == 1 && state.selectedCheckId != null) {
      try {
        final check = state.checks.firstWhere(
          (c) => c.id == state.selectedCheckId && !c.isClosed,
        );
        effectiveCheckPos = check.position;
      } catch (_) {
        state = state.copyWith(clearSelectedCheck: true);
      }
    }

    final qty = (lineQty < 1 ? 1 : lineQty).toDouble();
    state = state.copyWith(error: null);
    final previousItems = state.items;
    final previousOrder = state.order;

    await _ensureBusinessTaxSettingsLoaded();
    final resolvedTaxRate = productTaxRate ?? _cachedTaxRatePct;

    // OPTIMISTA: subtotal NETO (bruto - descuento) + marcador [DEAL:], igual que
    // lo guarda el backend, para que summarizeItemPricing aplique el override de
    // oferta y se vea "Subtotal/Descuento/Total" correcto al INSTANTE.
    final dealMarker = '[DEAL:${promotionId ?? ''}]';
    OrderItem? optimisticItem;
    if (previousOrder != null) {
      final tempId = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
      final grossAmount =
          (qty * originalPrice - discount).clamp(0, double.infinity).toDouble();
      final taxRateDecimal = resolvedTaxRate / 100.0;
      final optimisticAmounts = _estimateOptimisticItemAmounts(
        grossAmount: grossAmount,
        taxMode: productTaxMode,
        taxRate: taxRateDecimal,
        fullTaxRate: taxRateDecimal,
        serviceRate: 0.0,
        includeServiceInInclusivePrice: false,
      );

      final originForTaxes = parseSaleOrigin(state.origin);
      final synthTimestamp = DateTime.now();
      final taxBase = optimisticAmounts.subtotal;
      final synthTaxLines = <OrderItemTaxLine>[];
      for (var i = 0; i < _taxDefs.length; i++) {
        final taxDef = _taxDefs[i];
        if (!taxDef.isActive || taxDef.rate <= 0) continue;
        final appliesToOrigin = switch (originForTaxes) {
          SaleOrigin.zone => taxDef.applyOnZone,
          SaleOrigin.manual => taxDef.applyOnManual,
          SaleOrigin.quick => taxDef.applyOnQuick,
          SaleOrigin.delivery => taxDef.applyOnDelivery,
          SaleOrigin.unknown => true,
        };
        if (!appliesToOrigin) continue;
        final amount = double.parse(
          (taxBase * taxDef.rate / 100.0).toStringAsFixed(2),
        );
        if (amount <= 0.004) continue;
        synthTaxLines.add(
          OrderItemTaxLine(
            id: 'tmp_tl_${synthTimestamp.microsecondsSinceEpoch}_$i',
            orderItemId: tempId,
            taxId: 'tmp_tax_${taxDef.name}',
            taxName: taxDef.name,
            taxRate: taxDef.rate,
            amount: amount,
            createdAt: synthTimestamp,
          ),
        );
      }

      final activeWaiter = ref.read(activeWaiterProvider);
      optimisticItem = OrderItem(
        id: tempId,
        orderId: orderId,
        productId: menuItemId,
        productName: name,
        sku: null,
        quantity: qty,
        unitPrice: originalPrice,
        subtotal: optimisticAmounts.subtotal,
        discounts: discount,
        tax: optimisticAmounts.tax,
        total: optimisticAmounts.total,
        checkId: null,
        isTakeout: false,
        status: 'draft',
        notes: dealMarker,
        taxMode: productTaxMode,
        taxRate: resolvedTaxRate,
        originalTaxRate: resolvedTaxRate,
        createdAt: DateTime.now(),
        createdByEmployeeId: activeWaiter?.employeeId,
        createdByEmployeeName: activeWaiter?.displayName,
        modifiers: const [],
        taxLines: synthTaxLines,
      );

      final optimisticItems = [...state.items, optimisticItem];
      final updatedSummary = summarizeOrderPricing(
        previousOrder.copyWith(serviceFee: 0),
        optimisticItems,
      );
      final updatedOrder = previousOrder.copyWith(
        subtotal: updatedSummary.subtotal,
        tax: updatedSummary.tax,
        serviceFee: 0,
        total: updatedSummary.subtotal +
            updatedSummary.tax -
            updatedSummary.discounts,
      );
      state = state.copyWith(items: optimisticItems, order: updatedOrder);
    }

    // UN solo viaje: fn_add_offer_deal inserta la línea a precio original con el
    // descuento del deal.
    try {
      await ref.read(salesRepositoryProvider).addOfferDealItem(
            orderId: orderId,
            menuItemId: menuItemId,
            quantity: qty,
            discount: discount,
            name: name,
            promotionId: promotionId,
            checkPosition: effectiveCheckPos,
          );
      await _loadOrderDetail(orderId, caller: 'addOfferDeal');
    } catch (e) {
      if (optimisticItem != null) {
        state = state.copyWith(
          items: previousItems,
          order: previousOrder,
          error: 'No se pudo agregar la oferta: $e',
        );
      } else {
        state = state.copyWith(error: 'No se pudo agregar la oferta: $e');
      }
    }
  }

  ({double subtotal, double tax, double total}) _estimateOptimisticItemAmounts({
    required double grossAmount,
    required String taxMode,
    required double taxRate,
    double? fullTaxRate, // Tasa usada para "desglosar" el precio inclusivo
    required double serviceRate,
    bool includeServiceInInclusivePrice = false,
  }) {
    final normalizedTaxRate = taxRate.clamp(0, 5).toDouble();
    final normalizedFullTaxRate = (fullTaxRate ?? taxRate)
        .clamp(0, 5)
        .toDouble();
    final normalizedServiceRate = serviceRate.clamp(0, 5).toDouble();

    if (taxMode == 'inclusive' && normalizedFullTaxRate > 0) {
      // normalizedFullTaxRate ya representa la tasa TOTAL incluida en el precio
      // (ej. ITBIS + ley). Volver a sumar serviceRate aquí extraía de más la base
      // y producía montos optimistas de 499.99/0.01 fuera de reconciliación.
      final divisor = 1 + normalizedFullTaxRate;

      final subtotal = _roundMoney(grossAmount / divisor);

      // El impuesto real se calcula sobre la base extraída, usando la tasa aplicable.
      final tax = subtotal * normalizedTaxRate;

      // Si la propina de ley está incluida en el precio, se muestra separada pero
      // no se vuelve a agregar al divisor. El total debe reconciliar con grossAmount
      // cuando todas las tasas siguen activas.
      final total =
          subtotal +
          tax +
          (includeServiceInInclusivePrice
              ? (subtotal * normalizedServiceRate)
              : 0);

      return (
        subtotal: double.parse(subtotal.toStringAsFixed(2)),
        tax: double.parse(tax.toStringAsFixed(2)),
        total: double.parse(total.toStringAsFixed(2)),
      );
    }

    final tax = grossAmount * normalizedTaxRate;
    final total = grossAmount + tax;
    return (
      subtotal: double.parse(grossAmount.toStringAsFixed(2)),
      tax: double.parse(tax.toStringAsFixed(2)),
      total: double.parse(total.toStringAsFixed(2)),
    );
  }

  Future<void> toggleTakeout(bool value) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    final previousTakeout = state.takeout;
    state = state.copyWith(takeout: value, error: null);

    try {
      await ref
          .read(salesRepositoryProvider)
          .markOrderTakeout(orderId: orderId, takeout: value);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'mark_order_takeout',
            'origin': state.origin,
            'order_id': orderId,
            'takeout': value,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          takeout: value,
          error: 'Takeout actualizado en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(
        takeout: previousTakeout,
        error: 'Error al actualizar takeout: $e',
      );
    }
  }

  Future<void> deleteItem(String itemId, {String? reason}) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    // 1. Snapshot for rollback
    final previousItems = state.items;
    final previousOrder = state.order;

    // 2. Optimistic Local Update
    final updatedItems = state.items.where((i) => i.id != itemId).toList();

    final updatedSummary = summarizeOrderPricing(state.order, updatedItems);

    final updatedOrder = state.order?.copyWith(
      total: updatedSummary.total,
      subtotal: updatedSummary.subtotal,
      tax: updatedSummary.tax,
      serviceFee: updatedSummary.serviceFee,
    );

    state = state.copyWith(
      items: updatedItems,
      order: updatedOrder,
      error: null,
    );

    try {
      await ref.read(salesRepositoryProvider).deleteItem(itemId: itemId);

      // Fase 1 Toast redesign: si el item borrado era el último de un
      // sub-check, cerrar ese check automáticamente. El principal (C1) y los
      // checks con items restantes se quedan como estaban.
      final deletedCheckId = targetItem?.checkId;
      if (deletedCheckId != null && deletedCheckId.isNotEmpty) {
        await ref
            .read(salesRepositoryProvider)
            .closeEmptyCheckIfApplicable(deletedCheckId);
      }

      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'delete_item',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Producto eliminado en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(
        items: previousItems,
        order: previousOrder,
        error: 'Error al eliminar: $e',
      );
    }
  }

  Future<void> updateItemQuantity(String itemId, double quantity) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.editar_item')) {
      state = state.copyWith(
        error: 'No tienes permiso para editar líneas de orden.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    // Optimistic update: apply new quantity locally before server call
    final previousItems = state.items;
    final previousOrder = state.order;
    if (targetItem != null) {
      // PRD 2: el item.tax ya viene consolidado del motor backend (incluye
      // propina si aplicaba). El frontend optimista derive la tasa total
      // del propio item y no agrega service fee separado.
      final taxRate = targetItem.subtotal > 0
          ? (targetItem.tax / targetItem.subtotal)
          : 0.0;
      final optimisticAmounts = _estimateOptimisticItemAmounts(
        grossAmount: targetItem.unitPrice * quantity,
        taxMode: targetItem.taxMode,
        taxRate: taxRate,
        serviceRate: 0.0,
        includeServiceInInclusivePrice: false,
      );
      final optimisticItems = state.items
          .map(
            (item) => item.id != itemId
                ? item
                : item.copyWith(
                    quantity: quantity,
                    subtotal: optimisticAmounts.subtotal,
                    tax: optimisticAmounts.tax,
                    total: optimisticAmounts.total,
                  ),
          )
          .toList(growable: false);
      final updatedSummary = summarizeOrderPricing(
        state.order,
        optimisticItems,
      );
      state = state.copyWith(
        items: optimisticItems,
        order: state.order?.copyWith(
          subtotal: updatedSummary.subtotal,
          tax: updatedSummary.tax,
          serviceFee: updatedSummary.serviceFee,
          total: updatedSummary.total,
        ),
        error: null,
      );
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateItemQuantity(itemId: itemId, quantity: quantity);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        final updatedItems = state.items
            .map((item) {
              if (item.id != itemId) return item;
              // PRD 2: el motor backend consolida toda la fiscalidad en
              // `item.tax`. Optimismo offline deriva la tasa total del item
              // sin agregar service fee separado.
              final taxRate = item.subtotal > 0
                  ? (item.tax / item.subtotal)
                  : 0.0;
              final optimisticAmounts = _estimateOptimisticItemAmounts(
                grossAmount: item.unitPrice * quantity,
                taxMode: item.taxMode,
                taxRate: taxRate,
                serviceRate: 0.0,
                includeServiceInInclusivePrice: false,
              );
              return item.copyWith(
                quantity: quantity,
                subtotal: optimisticAmounts.subtotal,
                tax: optimisticAmounts.tax,
                total: optimisticAmounts.total,
              );
            })
            .toList(growable: false);

        final updatedSummary = summarizeOrderPricing(state.order, updatedItems);

        state = state.copyWith(
          items: updatedItems,
          order: state.order?.copyWith(
            subtotal: updatedSummary.subtotal,
            tax: updatedSummary.tax,
            serviceFee: updatedSummary.serviceFee,
            total: updatedSummary.total,
          ),
        );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'update_item_quantity',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'quantity': quantity,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Cantidad actualizada en local. Pendiente de sincronizar.',
        );
        return;
      }

      // Rollback optimistic update on online error
      state = state.copyWith(
        items: previousItems,
        order: previousOrder,
        error: 'Error al actualizar cantidad: $e',
      );
    }
  }

  Future<void> updateItemNotes(String itemId, String notes) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.editar_item')) {
      state = state.copyWith(
        error: 'No tienes permiso para editar líneas de orden.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateItemNotes(itemId: itemId, notes: notes);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        state = state.copyWith(
          items: state.items
              .map((item) {
                return item.id == itemId ? item.copyWith(notes: notes) : item;
              })
              .toList(growable: false),
        );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'update_item_notes',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'notes': notes,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error: 'Notas actualizadas en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(error: 'Error al actualizar notas: $e');
    }
  }

  Future<void> toggleItemTakeout(String itemId, bool isTakeout) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .toggleItemTakeout(itemId: itemId, isTakeout: isTakeout);
      // Defensa client-side antes del refresh: actualizar is_takeout local y
      // filtrar tax_lines del item para que el cajero NO vea Ley en items
      // takeout aunque el backend RPC sea viejo (no recomputa tax_lines).
      // El refresh asincrono va a traer la verdad del server despues, pero
      // este update inmediato evita el "flash" donde el item sigue cobrando
      // 10% por ~250ms hasta que llegue la respuesta.
      final patchedItems = state.items
          .map((item) =>
              item.id == itemId ? item.copyWith(isTakeout: isTakeout) : item)
          .toList(growable: false);
      state = state.copyWith(items: _filterTaxLinesByTakeout(patchedItems));
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        state = state.copyWith(
          items: state.items
              .map((item) {
                return item.id == itemId
                    ? item.copyWith(isTakeout: isTakeout)
                    : item;
              })
              .toList(growable: false),
        );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'toggle_item_takeout',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'is_takeout': isTakeout,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error:
              'Takeout del item actualizado en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(error: 'Error al cambiar takeout del item: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getMenuItemComboGroups(
    String menuItemId,
  ) async {
    final cached = _comboGroupsCache[menuItemId];
    if (cached != null) return cached;
    final groups = await ref
        .read(salesRepositoryProvider)
        .getComboGroupsForMenuItem(menuItemId);
    _comboGroupsCache[menuItemId] = groups;
    return groups;
  }

  Future<List<Map<String, dynamic>>> getMenuItemModifierGroups(
    String menuItemId,
  ) async {
    final cached = _modifierGroupsCache[menuItemId];
    if (cached != null) return cached;
    final groups = await ref
        .read(salesRepositoryProvider)
        .getModifierGroupsForMenuItem(menuItemId);
    _modifierGroupsCache[menuItemId] = groups;
    return groups;
  }

  Future<void> replaceItemModifiers({
    required String itemId,
    required List<SelectedModifierInput> selectedModifiers,
  }) async {
    try {
      await ref
          .read(salesRepositoryProvider)
          .replaceOrderItemModifiers(
            itemId: itemId,
            modifiers: selectedModifiers
                .map((modifier) => modifier.toMap())
                .toList(growable: false),
          );
      refreshOrder();
    } catch (e) {
      state = state.copyWith(error: 'Error actualizando modificadores: $e');
      rethrow;
    }
  }

  Future<void> updateItem(String itemId, OrderItem updatedItem) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.editar_item')) {
      state = state.copyWith(
        error: 'No tienes permiso para editar líneas de orden.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null) return;

    // Los items optimistas usan ids `tmp_<microsegundos>` que no son UUID
    // validos en server. Si el modal se abrio con un item recien agregado
    // antes de que `_loadOrderDetail` corriera, el itemId capturado en el
    // closure del modal seguira siendo tmp_. Refrescamos para que el state
    // tenga ids reales y resolvemos por product_id al item recien creado.
    String resolvedId = itemId;
    if (resolvedId.startsWith('tmp_')) {
      await refreshOrder();
      final productId = updatedItem.productId;
      final matches = state.items.where((i) {
        if (productId != null && productId.isNotEmpty) {
          return i.productId == productId;
        }
        return i.productName == updatedItem.productName;
      }).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      OrderItem? realCandidate;
      for (final candidate in matches) {
        if (!candidate.id.startsWith('tmp_')) {
          realCandidate = candidate;
          break;
        }
      }
      if (realCandidate == null) {
        state = state.copyWith(
          error:
              'El producto aun se esta sincronizando. Espera un momento e intenta de nuevo.',
        );
        return;
      }
      resolvedId = realCandidate.id;
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .updateItemDetails(
            itemId: resolvedId,
            productName: updatedItem.productName,
            quantity: updatedItem.quantity,
            isTakeout: updatedItem.isTakeout,
            discounts: updatedItem.discounts,
            notes: updatedItem.notes?.trim().isEmpty ?? true
                ? null
                : updatedItem.notes?.trim(),
          );
      refreshOrder();
    } catch (e) {
      state = state.copyWith(error: 'Error al actualizar item: $e');
      rethrow;
    }
  }

  Future<void> applyDiscountPercentToItems({
    required List<String> itemIds,
    required double percent,
  }) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.descuento_aplicar')) {
      state = state.copyWith(
        error: 'No tienes permiso para aplicar descuentos.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null || itemIds.isEmpty) return;

    final clampedPercent = percent.clamp(0, 100).toDouble();
    final targetItems = state.items
        .where(
          (i) =>
              itemIds.contains(i.id) &&
              i.status != 'paid' &&
              i.status != 'void',
        )
        .toList(growable: false);
    if (targetItems.isEmpty) return;

    state = state.copyWith(loading: true, error: null);
    try {
      final discountByItemId = <String, double>{};

      await Future.wait(
        targetItems.map((item) {
          final base = (item.subtotal + item.tax)
              .clamp(0, double.infinity)
              .toDouble();
          final discount = (base * (clampedPercent / 100))
              .clamp(0, base)
              .toDouble();
          discountByItemId[item.id] = discount;
          final notesWithoutCourtesy = _stripCourtesyFromNotes(item.notes);
          return ref
              .read(salesRepositoryProvider)
              .updateItemDiscountAndNotes(
                itemId: item.id,
                discounts: discount,
                notes: notesWithoutCourtesy.isEmpty
                    ? null
                    : notesWithoutCourtesy,
              );
        }),
      );

      state = state.copyWith(
        loading: false,
        items: state.items
            .map(
              (item) => discountByItemId.containsKey(item.id)
                  ? item.copyWith(discounts: discountByItemId[item.id])
                  : item,
            )
            .toList(growable: false),
      );

      refreshOrder();
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error aplicando descuento: $e',
      );
      rethrow;
    }
  }

  Future<void> applyCourtesyToItems({
    required List<String> itemIds,
    required String reason,
  }) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.descuento_aplicar')) {
      state = state.copyWith(
        error: 'No tienes permiso para aplicar cortesías.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null || itemIds.isEmpty) return;

    final selectedItems = state.items
        .where(
          (i) =>
              itemIds.contains(i.id) &&
              i.status != 'paid' &&
              i.status != 'void',
        )
        .toList(growable: false);
    if (selectedItems.isEmpty) return;

    // Si un producto se marca como cortesía en principal/subcuenta,
    // aplicamos la cortesía a todas sus líneas en la orden.
    final selectedProductKeys = selectedItems
        .map(_courtesyProductKey)
        .whereType<String>()
        .toSet();

    final freshOpenItems = await ref
        .read(salesRepositoryProvider)
        .getOrderItems(
          orderId,
          includeModifiers: true,
          onlyOpen: true,
          businessId: _activeBusinessId,
        );

    final targetItems = freshOpenItems
        .where(
          (item) => selectedProductKeys.contains(_courtesyProductKey(item)),
        )
        .toList(growable: false);
    if (targetItems.isEmpty) return;

    final cleanedReason = reason.trim();
    state = state.copyWith(loading: true, error: null);
    try {
      await Future.wait(
        targetItems.map((item) {
          final base = _courtesyLineAmount(item);
          final notes = _buildCourtesyNotes(
            originalNotes: item.notes,
            reason: cleanedReason,
          );
          return ref
              .read(salesRepositoryProvider)
              .updateItemDiscountAndNotes(
                itemId: item.id,
                discounts: base,
                notes: notes,
              );
        }),
      );
      refreshOrder();
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error aplicando cortesía: $e',
      );
      rethrow;
    }
  }

  Future<void> moveItemToCheck(String itemId, int pos) async {
    final orderId = state.order?.id;
    if (orderId == null) return;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }

    try {
      await ref
          .read(salesRepositoryProvider)
          .moveItemToCheck(itemId: itemId, checkPosition: pos);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline =
          !_connectivity.isConnected || orderId.startsWith('local-order-');
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'move_item_to_check',
            'origin': state.origin,
            'order_id': orderId,
            'item_id': itemId,
            'check_pos': pos,
            'product_id': targetItem?.productId,
            'product_name': targetItem?.productName,
            'notes': targetItem?.notes,
            'is_takeout': targetItem?.isTakeout,
          },
        );
        await _persistCurrentState(localOnly: true);
        state = state.copyWith(
          error:
              'Movimiento a subcuenta guardado en local. Pendiente de sincronizar.',
        );
        return;
      }

      state = state.copyWith(error: 'Error moviendo item a subcuenta: $e');
    }
  }

  /// Remueve localmente un check (subcuenta) y sus items, ajustando totales.
  void removeCheckLocally(String checkId) {
    final currentOrder = state.order;
    if (currentOrder == null) return;

    final removedItems = state.items
        .where((i) => i.checkId == checkId)
        .toList();
    if (removedItems.isEmpty) return;

    final remainingItems = state.items
        .where((i) => i.checkId != checkId)
        .toList();

    final remSubtotal = remainingItems.fold<double>(
      0,
      (s, i) => s + i.subtotal,
    );
    final remDiscounts = remainingItems.fold<double>(
      0,
      (s, i) => s + i.discounts,
    );
    final remTax = remainingItems.fold<double>(0, (s, i) => s + i.tax);
    final remTotal = remainingItems.fold<double>(0, (s, i) => s + i.total);

    final newOrder = currentOrder.copyWith(
      subtotal: remSubtotal,
      discounts: remDiscounts,
      tax: remTax,
      total: remTotal,
    );

    final remainingChecks = state.checks.where((c) => c.id != checkId).toList();

    state = state.copyWith(
      items: remainingItems,
      order: newOrder,
      checks: remainingChecks,
      clearSelectedCheck: state.selectedCheckId == checkId,
    );

    // actualiza cache si mesa activa
    if (state.origin == 'table') {
      final activeTableEntry = _tableCache.entries.firstWhere(
        (e) => e.value.order?.id == currentOrder.id,
        orElse: () =>
            MapEntry<String, CurrentOrderState>('', const CurrentOrderState()),
      );
      if (activeTableEntry.key.isNotEmpty) {
        _tableCache[activeTableEntry.key] = state;
      }
    }
  }

  Future<void> closeOrderPaid() async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.mesas.liberar')) {
      state = state.copyWith(
        error: 'No tienes permiso para cerrar y liberar la mesa.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null) return;
    await ref
        .read(salesRepositoryProvider)
        .closeOrder(orderId: orderId, status: 'paid');

    // Refresh cashier data in the background
    try {
      final cashierVM = ref.read(cashierViewModelProvider.notifier);
      unawaited(cashierVM.refreshSilently());
    } catch (e) {
      // Cashier refresh is not critical for the sales flow.
      debugPrint('Note: Could not refresh cashier: $e');
    }

    _hasManualFiscalTypeSelection = false;
    state = const CurrentOrderState();
  }

  Future<void> cancelCurrentOrder({String? reason}) async {
    final orderId = state.order?.id;
    if (orderId == null) {
      _hasManualFiscalTypeSelection = false;
      state = const CurrentOrderState();
      return;
    }
    final trimmedReason = reason?.trim();
    final businessId = _activeBusinessId;

    // Helper local: detecta errores de red transitorios para diferenciarlos
    // de errores de negocio (orden ya cerrada, RLS, validación RPC, etc.).
    // Si es de red → encolamos void_order y resetamos UI; si no → propaga
    // para que el caller muestre el error real al cajero.
    bool isNetworkError(Object e) {
      final msg = e.toString().toLowerCase();
      return msg.contains('socketexception') ||
          msg.contains('clientexception') ||
          msg.contains('timeoutexception') ||
          msg.contains('handshakeexception') ||
          msg.contains('failed host lookup') ||
          msg.contains('connection refused') ||
          msg.contains('connection closed') ||
          msg.contains('connection reset') ||
          msg.contains('network is unreachable');
    }

    Future<void> enqueueVoidOffline() async {
      if (businessId == null || businessId.isEmpty) return;
      // Si la orden aún es local (nunca llegó al server) no tiene sentido
      // encolar — al cajero ya no le importa esa orden, simplemente
      // descartamos. El espejo local del void se aplica abajo con el
      // reset del state.
      if (orderId.startsWith('local-order-')) return;
      await _offlinePos.enqueueAction(
        businessId: businessId,
        action: <String, dynamic>{
          'type': 'void_order',
          'order_id': orderId,
          if (trimmedReason != null && trimmedReason.isNotEmpty) ...{
            'reason': trimmedReason,
            // Actor + timestamp del momento de la anulación, para que el
            // replay persista una nota de auditoría fiel (no la del sync).
            'void_by': ref.read(sessionProvider).userName,
            'voided_at': DateTime.now().toIso8601String(),
          },
        },
      );
    }

    // Caso 1: ya estamos offline declarado. No intentamos online, encolamos
    // directamente. (La audit note igual NO se persiste en server — ver
    // limitación en el case 'void_order' del _replayAction.)
    if (!_connectivity.isConnected) {
      await enqueueVoidOffline();
      _hasManualFiscalTypeSelection = false;
      state = const CurrentOrderState();
      return;
    }

    // Caso 2: online declarado. Intentamos persistir audit note + close. Si
    // cualquiera falla por red mid-call, encolamos void_order como fallback
    // y resetamos UI igual.
    try {
      if (trimmedReason != null && trimmedReason.isNotEmpty) {
        try {
          await appendVoidAuditNote(reason: trimmedReason);
        } catch (e) {
          if (!isNetworkError(e)) rethrow;
          // Network falló en audit note: seguimos al closeOrder (que
          // probablemente también falle) y encolamos abajo. No
          // duplicamos enqueue acá.
          debugPrint(
            'cancelCurrentOrder: audit note falló por red, '
            'continuamos al closeOrder. $e',
          );
        }
      }
      await ref
          .read(salesRepositoryProvider)
          .closeOrder(orderId: orderId, status: 'void');
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      debugPrint(
        'cancelCurrentOrder: closeOrder online falló por red, encolando '
        'void_order para sync posterior. $e',
      );
      await enqueueVoidOffline();
    }

    _hasManualFiscalTypeSelection = false;
    state = const CurrentOrderState();
  }

  /// Confirma la orden enviándola a cocina. Retorna el [KitchenSendResult]
  /// para que la UI pueda mostrar snackbar amigable cuando alguna área
  /// escala al worker. Retorna `null` si no había orden o si la orden
  /// fue al path local (offline / orden local sin sincronizar).
  Future<KitchenSendResult?> confirmOrder({String? tableName, String? waiterName}) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('ventas.orden.enviar_cocina')) {
      state = state.copyWith(
        error: 'No tienes permiso para enviar órdenes a cocina.',
      );
      return null;
    }
    final orderId = state.order?.id;
    if (orderId == null) return null;
    // No ponemos loading: true aquí para evitar el parpadeo de la pantalla completa.
    // El usuario verá el item aparecer inmediatamente cuando _loadOrderDetail termine.
    // state = state.copyWith(loading: true);
    try {
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) {
        throw Exception(
          'No se pudo resolver el negocio activo para imprimir la comanda.',
        );
      }

      if (!_connectivity.isConnected || orderId.startsWith('local-order-')) {
        await ref
            .read(printingServiceProvider)
            .sendLocalOrderToKitchen(
              businessId: businessId,
              localState: state,
              tableName:
                  tableName ?? (state.origin == 'table' ? 'MESA' : 'LOCAL'),
              waiterName: waiterName ?? session.userName,
              businessName: session.activeBusinessName,
            );
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'send_to_kitchen',
            'origin': state.origin,
            'order_id': orderId,
          },
        );

        // Espejo local del RPC fn_confirm_order_to_kitchen: marca los
        // items en estado draft/open como pending para que la UI los
        // muestre bajo "ENVIADOS A COCINA". Sin esto, el cajero ve el
        // ticket imprimirse pero los items quedan visualmente en "POR
        // CONFIRMAR" — bug reportado tras ver Pizza ✓ + Agua ✗ aunque
        // ambos salieron en la comanda.
        //
        // Los items ya en pending/preparing/ready/served no se tocan
        // (idempotente). Al sync, el replay del action 'send_to_kitchen'
        // dispara el RPC real que persiste estos statuses en server.
        final updatedItems = state.items.map((item) {
          if (item.status == 'draft' || item.status == 'open') {
            return item.copyWith(status: 'pending');
          }
          return item;
        }).toList(growable: false);

        state = state.copyWith(
          items: updatedItems,
          loading: false,
          error: 'Comanda impresa/localmente. Pendiente de sincronizar.',
        );
        await _persistCurrentState(localOnly: true);
        return null;
      }

      final result = await ref
          .read(printingServiceProvider)
          .sendOrderToKitchen(
            orderId: orderId,
            businessId: businessId,
            fallbackTableName: tableName,
            fallbackWaiterName: waiterName ?? session.userName,
          );
      refreshOrder();
      return result;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      rethrow;
    }
  }

  Future<void> reprintKitchenTicket({
    required String orderId,
    List<OrderItem>? items,
  }) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('kds.reimprimir_comanda')) {
      state = state.copyWith(
        error: 'No tienes permiso para reimprimir comandas.',
      );
      return;
    }
    final businessId = _activeBusinessId;
    if (businessId == null) return;

    try {
      if (items != null && items.isNotEmpty) {
        await ref
            .read(printingServiceProvider)
            .reprintItems(
              orderId: orderId,
              businessId: businessId,
              items: items,
            );
      }
    } catch (e) {
      state = state.copyWith(error: 'Error al reimprimir: $e');
    }
  }

  Future<void> refreshOrder({bool clearIfPaid = false}) async {
    final orderId = state.order?.id;
    if (orderId == null) return;
    _scheduleOrderRefresh(orderId, clearIfPaid: clearIfPaid);
  }

  /// Tick del timer de respaldo. Barato: sale temprano si no hay conexión,
  /// ya hay un sync corriendo, no hay business activo o la cola no tiene
  /// pendientes. Solo entonces dispara el sync real.
  Future<void> _runPeriodicSyncTick() async {
    if (_syncInFlight) return;
    if (!_connectivity.isConnected) return;
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    try {
      final pending = await _offlinePos.pendingActionsCount(businessId);
      if (pending <= 0) return;
    } catch (_) {
      return;
    }
    await syncPendingOfflineActions();
  }

  Future<void> syncPendingOfflineActions({bool force = false}) async {
    if (_syncInFlight) return;
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;

    // Si el caller forzo el sync (boton "Sync ahora" del banner), refrescar
    // el estado de reachability AHORA en vez de esperar al proximo poll de
    // 30s. El caso comun: Supabase tuvo blips → _reachable quedo en false
    // → el wifi esta perfecto pero el banner sigue "Sync pausada" hasta el
    // proximo poll. Con esto el boton hace lo que el cajero espera.
    if (force && !_connectivity.isConnected) {
      await _connectivity.forceReachabilityCheck();
    }

    if (!_connectivity.isConnected) {
      await _refreshOfflineMonitor(
        syncStatus: _connectivity.isAdapterUp
            ? 'Servidor no responde. Intentando reconectar...'
            : 'Sin conexion. Sync pausada.',
        syncInFlight: false,
      );
      return;
    }

    _syncInFlight = true;
    await _refreshOfflineMonitor(
      syncStatus: 'Sincronizando operaciones offline...',
      syncInFlight: true,
    );
    try {
      final result = await _offlinePos.syncPendingActions(
        businessId: businessId,
        salesRepository: ref.read(salesRepositoryProvider),
        printingService: ref.read(printingServiceProvider),
        inventoryRepository: ref.read(inventoryRepositoryProvider),
        cashierRepository: ref.read(cashierRepositoryProvider),
        force: force,
      );

      // Publicamos el resultado al provider central para que el badge
      // del topbar refresque su count y el shell muestre la notificación
      // post-sync con detalle (pagos completados, NCFs emitidos, etc.).
      ref.read(offlineQueueStatusProvider.notifier).publishSyncResult(result);

      // F3b-3c: si este dispositivo es el Hub Local, drena también su op-log
      // a Supabase (las ops que recibió de otras cajas mientras no había red).
      // En los dispositivos que NO son Hub el op-log está vacío → no-op. Gated
      // por kHubModeEnabled; best-effort (no rompe el sync de la cola propia).
      if (kHubModeEnabled) {
        try {
          await _offlinePos.syncHubOpLog(
            businessId: businessId,
            salesRepository: ref.read(salesRepositoryProvider),
            printingService: ref.read(printingServiceProvider),
            inventoryRepository: ref.read(inventoryRepositoryProvider),
            cashierRepository: ref.read(cashierRepositoryProvider),
          );
        } catch (e) {
          debugPrint('[SalesVM] syncHubOpLog (drenado del Hub) falló: $e');
        }
      }

      if (result.completed > 0 &&
          state.order != null &&
          state.order!.id.startsWith('local-order-') &&
          result.lastMappedOrderId != null) {
        await _loadOrderDetail(
          result.lastMappedOrderId!,
          origin: state.origin,
          caller: 'syncOffline:mapped',
        );
      } else if (state.order != null &&
          !state.order!.id.startsWith('local-order-')) {
        await _loadOrderDetail(
          state.order!.id,
          origin: state.origin,
          caller: 'syncOffline:existing',
        );
      }

      final syncMessage = !result.didWork
          ? (result.pending > 0
                ? 'Sync pendiente. Operaciones en espera.'
                : 'Todo sincronizado.')
          : result.hasFailures
          ? 'Sync offline parcial: ${result.completed} ok, ${result.failed} con error.'
          : result.pending > 0
          ? 'Sync offline en progreso. Pendientes: ${result.pending}.'
          : 'Sync offline completada (${result.completed}).';

      state = state.copyWith(
        error: result.hasFailures ? syncMessage : state.error,
      );
      await _refreshOfflineMonitor(
        syncStatus: syncMessage,
        syncInFlight: false,
      );
      if (!result.hasFailures && result.pending == 0) {
        state = state.copyWith(lastSyncAt: DateTime.now());
      }
    } catch (e, st) {
      // Diagnóstico: el banner solo muestra "Error sincronizando offline."; el
      // detalle real se perdía. Lo emitimos a consola para poder rastrear qué
      // operación de la cola falla (NCF, RLS, constraint, red, etc.).
      debugPrint('[SalesVM] syncOffline FALLÓ: $e\n$st');
      state = state.copyWith(error: 'Error sincronizando offline: $e');
      await _refreshOfflineMonitor(
        syncStatus: 'Error sincronizando offline.',
        syncInFlight: false,
      );
    } finally {
      _syncInFlight = false;
      await _refreshOfflineMonitor(syncInFlight: false);
    }
  }

  void _scheduleOrderRefresh(String orderId, {bool clearIfPaid = false}) {
    _queuedRefreshOrderId = orderId;
    _queuedClearIfPaid = _queuedClearIfPaid || clearIfPaid;

    _refreshOrderDebounceTimer?.cancel();
    _refreshOrderDebounceTimer = Timer(_refreshOrderDebounce, () {
      unawaited(_flushQueuedOrderRefresh());
    });
  }

  Future<void> _flushQueuedOrderRefresh() async {
    if (_refreshOrderInFlight) return;
    if (_queuedRefreshOrderId == null) return;
    _refreshOrderInFlight = true;

    try {
      while (_queuedRefreshOrderId != null) {
        final orderId = _queuedRefreshOrderId!;
        final clearIfPaid = _queuedClearIfPaid;

        _queuedRefreshOrderId = null;
        _queuedClearIfPaid = false;

        await _loadOrderDetail(orderId, caller: 'scheduledRefresh');
        if (clearIfPaid && (state.order?.isPaid ?? false)) {
          _hasManualFiscalTypeSelection = false;
          // Retail multi-carrito: en vez de dejar el state vacío, cerramos la
          // pestaña pagada y pasamos a otro carrito (o creamos uno vacío).
          if (_isRetail && _activeRetailSlotId != null) {
            final activeCart = ref.read(retailCartsProvider).active;
            if (activeCart?.orderId == state.order?.id) {
              await _finalizeActiveRetailCartAfterPayment();
            } else {
              // Evento tardío de un pago de OTRO carrito (ya finalizado): no
              // toques el activo; recárgalo para no dejar el state mostrando
              // la orden vieja pagada.
              await switchRetailCart(_activeRetailSlotId!);
            }
          } else {
            state = const CurrentOrderState();
          }
        }
      }
    } finally {
      _refreshOrderInFlight = false;
      if (_queuedRefreshOrderId != null) {
        unawaited(_flushQueuedOrderRefresh());
      }
    }
  }

  void selectCheck(String? checkId) {
    state = state.copyWith(
      selectedCheckId: checkId,
      clearSelectedCheck: checkId == null,
    );
  }

  Future<void> _loadOrderDetail(
    String orderId, {
    String? origin,
    String? tableId,
    // Identifica el camino que disparó el load. Solo se usa en el log
    // de "orden no disponible" para poder diagnosticar bugs intermitentes
    // (state.order stale, _tableCache contaminado, debounce que dispara
    // un id ya inexistente, etc.) sin tener que pedirle al usuario que
    // reproduzca con un breakpoint puesto.
    String caller = 'unknown',
    // Si el caller ya tiene el bundle parseado (ej: openTable usando
    // fn_open_table_and_load), pásalo para evitar el round-trip extra
    // a fn_get_order_bundle.
    ({
      Order? order,
      List<OrderItem> items,
      List<OrderCheck> checks,
      String? customerId,
      String? customerName,
      String? note,
    })? preloadedBundle,
  }) async {
    final previousOrderId = state.order?.id;
    final previousOrigin = state.origin;
    final tableCacheHit = tableId != null && _tableCache.containsKey(tableId);
    if (state.order?.id != orderId) {
      _hasManualFiscalTypeSelection = false;
    }

    _refreshOrderDebounceTimer?.cancel();
    await _ensureBusinessTaxSettingsLoaded();
    await _ensureBusinessFiscalSettingsLoaded();
    final repo = ref.read(salesRepositoryProvider);
    Order? order;
    List<OrderItem> items = const [];
    List<OrderCheck> checks = const [];
    String? loadError;
    String? customerId;
    String? customerName;
    String? sessionNote;

    var loadedByBundle = false;

    if (preloadedBundle != null) {
      // Fast path: usamos el bundle que ya vino del RPC consolidado
      order = preloadedBundle.order;
      items = preloadedBundle.items;
      checks = preloadedBundle.checks;
      customerId = preloadedBundle.customerId;
      customerName = preloadedBundle.customerName;
      sessionNote = preloadedBundle.note;
      loadedByBundle = order != null;
    } else {
      try {
        final bundle = await repo.getOrderBundle(
          orderId,
          businessId: _activeBusinessId,
        );
        order = bundle.order;
        items = bundle.items;
        checks = bundle.checks;
        customerId = bundle.customerId;
        customerName = bundle.customerName;
        sessionNote = bundle.note;

        loadedByBundle = order != null;
      } catch (e) {
        loadError = e.toString();
      }
    }

    if (!loadedByBundle) {
      final orderFuture = repo.getOrder(orderId, businessId: _activeBusinessId);
      final itemsFuture = repo.getOrderItems(
        orderId,
        includeModifiers: false,
        limit: 500,
        onlyOpen: true,
        businessId: _activeBusinessId,
      );
      final checksFuture = repo.getOrderChecks(
        orderId,
        businessId: _activeBusinessId,
      );
      // Marcar las futures como manejadas para que un rechazo temprano no se
      // reporte como "Error FATAL no controlado" antes de llegar a su await.
      // El error sigue disponible cuando se haga el await más abajo.
      orderFuture.ignore();
      itemsFuture.ignore();
      checksFuture.ignore();
      Future<({String? customerId, String? customerName, String? note})>?
      customerFuture;

      try {
        order = await orderFuture;
        if (order != null) {
          customerFuture = repo.getSessionCustomer(
            order.sessionId,
            businessId: _activeBusinessId,
          );
        }
        checks = await checksFuture;
      } catch (e) {
        loadError ??= e.toString();
      }

      try {
        items = await itemsFuture;
      } catch (e) {
        loadError ??= e.toString();
      }

      if (customerFuture != null) {
        try {
          final customer = await customerFuture;
          customerId = customer.customerId;
          customerName = customer.customerName;
          sessionNote = customer.note;
        } catch (_) {}
      }
    }

    if (order == null && items.isEmpty) {
      // Tails de IDs para que la captura del usuario sea autodiagnosticable
      // sin tener que pedirle logs. order=…<8> · business=…<8>.
      String tail(String? value) {
        if (value == null || value.isEmpty) return 'null';
        return value.length >= 8
            ? value.substring(value.length - 8)
            : value;
      }

      final activeBusinessId = _activeBusinessId;
      final diag = 'order=…${tail(orderId)} · business=…${tail(activeBusinessId)}';

      debugPrint("===== _loadOrderDetail ERROR =====");
      debugPrint("caller: $caller");
      debugPrint("orderId: $orderId");
      debugPrint("activeBusinessId: $activeBusinessId");
      debugPrint("loadedByBundle: $loadedByBundle");
      debugPrint("loadError: $loadError");
      debugPrint("requestedOrigin: $origin");
      debugPrint("previousOrigin: $previousOrigin");
      debugPrint("previousOrderId: $previousOrderId");
      debugPrint("tableId: $tableId");
      debugPrint("tableCacheHit: $tableCacheHit");
      debugPrint("==================================");

      // Recovery: si el orderId no es accesible en el negocio actual, limpiar
      // el state para que un próximo openTable no arrastre la orden stale
      // entre sucursales. Sin esto, el viewmodel reintenta cargar el mismo
      // orderId out-of-scope cada vez que el usuario interactúa.
      _tableCache.remove(tableId);
      final baseMessage =
          loadError ??
          'Esta orden no está disponible en este negocio.\n'
              'Vuelve a la pantalla de mesas e intenta de nuevo.';
      state = state.copyWith(
        loading: false,
        clearOrder: true,
        items: const <OrderItem>[],
        checks: const <OrderCheck>[],
        clearSelectedCheck: true,
        clearCustomer: true,
        clearSessionNote: true,
        error: '$baseMessage\n$diag',
      );
      return;
    }

    // Verificar si el check seleccionado todavía existe
    String? newSelectedCheckId = state.selectedCheckId;
    if (newSelectedCheckId != null) {
      final exists = checks.any(
        (c) => c.id == newSelectedCheckId && !c.isClosed,
      );
      if (!exists) {
        newSelectedCheckId = null;
      }
    }

    // Fetch fiscal sequences if not loaded for this business
    List<FiscalNcfSequence> fiscalSequences = state.fiscalSequences;
    final activeBusinessId = _activeBusinessId;
    final shouldReloadFiscalSequences =
        activeBusinessId != null &&
        (fiscalSequences.isEmpty ||
            fiscalSequences.any(
              (sequence) => sequence.businessId != activeBusinessId,
            ));
    String? fiscalSequencesLoadError;
    bool clearFiscalSequencesLoadError = false;
    if (shouldReloadFiscalSequences) {
      try {
        fiscalSequences = await ref
            .read(fiscalServiceProvider)
            .getSequences(activeBusinessId);
        clearFiscalSequencesLoadError = true;
      } catch (e) {
        debugPrint('Error loading fiscal sequences: $e');
        fiscalSequencesLoadError = e.toString();
      }
    }

    final resolvedFiscalType = _resolveFiscalTypeForState(
      state,
      fiscalSequences,
    );

    state = _normalizeHydratedState(
      state.copyWith(
        loading: false,
        order: order ?? state.order,
        items: items,
        checks: checks,
        origin: origin ?? state.origin,
        error: items.isEmpty ? (loadError ?? state.error) : null,
        selectedCheckId: newSelectedCheckId,
        clearSelectedCheck:
            newSelectedCheckId == null && state.selectedCheckId != null,
        customerId: customerId,
        customerName: customerName,
        clearCustomer: customerId == null && customerName == null,
        sessionNote: sessionNote,
        clearSessionNote: sessionNote == null,
        fiscalType: resolvedFiscalType,
        fiscalDefaultType: _cachedDefaultFiscalType,
        fiscalSequences: fiscalSequences,
        fiscalSequencesLoadError: fiscalSequencesLoadError,
        clearFiscalSequencesLoadError: clearFiscalSequencesLoadError,
      ),
    );

    // Cachear última versión por mesa para apertura optimista
    if (origin == 'table' && tableId != null) {
      _tableCache[tableId] = state;
    }

    // Fix anti-glitch: si mientras corría este load, realtime fired
    // (típico al agregar item — el INSERT en order_items dispara
    // refreshOrder() que encola otro load), descartamos esa cola. Ya
    // tenemos la verdad del server; un segundo fetch idéntico solo
    // causa re-render visible que el usuario percibe como "el item
    // salió y volvió y entró".
    _queuedRefreshOrderId = null;
    _queuedClearIfPaid = false;
    _refreshOrderDebounceTimer?.cancel();

    final promotionsChanged = await _applyAutomaticPromotionsIfNeeded();
    if (promotionsChanged) {
      refreshOrder();
      return;
    }

    await _persistCurrentState(tableId: tableId);
    _subscribeToOrderUpdates(orderId);
  }

  RealtimeChannel? _realtimeChannel;
  String? _subscribedOrderId;

  void _subscribeToOrderUpdates(String orderId) {
    if (_subscribedOrderId == orderId && _realtimeChannel != null) {
      return;
    }

    if (_realtimeChannel != null) {
      _realtimeChannel!.unsubscribe();
    }

    final client = Supabase.instance.client;
    _realtimeChannel = client.channel('order_view_$orderId');
    _subscribedOrderId = orderId;

    _realtimeChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_items',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: orderId,
          ),
          callback: (payload) {
            // Refresh order on any item change
            refreshOrder();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_checks',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: orderId,
          ),
          callback: (payload) {
            // Refresh on check changes (splits, payments, closing)
            refreshOrder();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: orderId,
          ),
          callback: (payload) {
            // Refresh on order status change (e.g. paid/closed)
            // Check if order is closed/paid to clear state or navigate back could be logic here
            refreshOrder(clearIfPaid: true);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'payments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: orderId,
          ),
          callback: (payload) {
            refreshOrder();
          },
        )
        .subscribe();
  }

  String? _courtesyProductKey(OrderItem item) {
    final productId = item.productId?.trim();
    if (productId != null && productId.isNotEmpty) return 'id:$productId';

    final name = item.productName.trim().toLowerCase();
    if (name.isEmpty) return null;
    final sku = (item.sku ?? '').trim().toLowerCase();
    final price = item.unitPrice.toStringAsFixed(2);
    return 'name:$name|sku:$sku|price:$price';
  }

  double _courtesyLineAmount(OrderItem item) {
    // El descuento de cortesía representa "lo que el cliente NO paga" y
    // jamás debe exceder el gross efectivo de la línea. Si excede, el
    // trigger backend grabará item.total = subtotal + tax - discount
    // negativo, y la factura mostrará -RD$X en vez de RD$0.
    //
    // Fuente de verdad del gross:
    //   inclusive → item.subtotal + item.tax  (subtotal está NETO,
    //               extraído por el trigger; sumarlos da el gross
    //               que el cliente ve en el menú).
    //   exclusive → item.subtotal + item.tax  (subtotal es base sin
    //               tax; sumarle tax da el gross final).
    // En ambos casos: subtotal + tax == gross real. Usamos esto cuando
    // los valores estén persistidos (item ya pasó por fn_compute_item_totals).
    if (item.subtotal > 0 || item.tax > 0) {
      final base = item.subtotal + item.tax;
      return double.parse(base.toStringAsFixed(2));
    }

    // Fallback para items en draft sin totals persistidos. Estimamos
    // según el modo de impuestos.
    final modifiersPerUnit = item.modifiers.fold<double>(
      0,
      (sum, modifier) => sum + (modifier.price * modifier.qty),
    );

    if (item.taxMode == 'inclusive') {
      // unitPrice ya incluye tax baked; el gross es directamente
      // qty * (unitPrice + modifiers).
      final gross = item.quantity * (item.unitPrice + modifiersPerUnit);
      return double.parse(gross.toStringAsFixed(2));
    }

    // Exclusive draft: estimamos tax sobre la base.
    final estimatedSubtotal = item.quantity * (item.unitPrice + modifiersPerUnit);
    final taxRate = item.tax > 0 ? 0.18 : 0.0;
    final estimatedTax = estimatedSubtotal * taxRate;

    final total = (estimatedSubtotal + estimatedTax)
        .clamp(0, double.infinity)
        .toDouble();
    return double.parse(total.toStringAsFixed(2));
  }

  bool _hasCourtesyNote(String? rawNotes) {
    if (rawNotes == null || rawNotes.trim().isEmpty) return false;
    return rawNotes
        .split('\n')
        .map((line) => line.trim())
        .any((line) => line.startsWith(_courtesyPrefix) && line.endsWith(']'));
  }

  /// True si la línea es una OFERTA vendida desde el tile (marcador [DEAL:]).
  /// El motor de auto-ofertas la ignora (ya viene al precio final).
  bool _isDealNote(String? rawNotes) {
    if (rawNotes == null || rawNotes.trim().isEmpty) return false;
    return rawNotes
        .split('\n')
        .map((line) => line.trim())
        .any((line) => line.startsWith(_dealPrefix) && line.endsWith(']'));
  }

  String? _extractAutoPromoId(String? rawNotes) {
    if (rawNotes == null || rawNotes.trim().isEmpty) return null;
    for (final line in rawNotes.split('\n').map((line) => line.trim())) {
      if (line.startsWith(_promoPrefix) && line.endsWith(']')) {
        return line.substring(_promoPrefix.length, line.length - 1).trim();
      }
    }
    return null;
  }

  String _stripManagedNotes(String? rawNotes) {
    if (rawNotes == null || rawNotes.trim().isEmpty) return '';

    final lines = rawNotes
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where(
          (line) =>
              !(line.startsWith(_courtesyPrefix) && line.endsWith(']')) &&
              !(line.startsWith(_promoPrefix) && line.endsWith(']')) &&
              !(line.startsWith(_dealPrefix) && line.endsWith(']')),
        )
        .toList(growable: false);

    return lines.join('\n');
  }

  String _stripCourtesyFromNotes(String? rawNotes) {
    if (rawNotes == null || rawNotes.trim().isEmpty) return '';

    final lines = rawNotes
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where(
          (line) => !(line.startsWith(_courtesyPrefix) && line.endsWith(']')),
        )
        .toList(growable: false);

    return lines.join('\n');
  }

  String? _buildCourtesyNotes({
    required String? originalNotes,
    required String reason,
  }) {
    final baseNotes = _stripManagedNotes(originalNotes);
    final parts = <String>[];
    if (baseNotes.isNotEmpty) {
      parts.add(baseNotes);
    }
    if (reason.isNotEmpty) {
      parts.add('$_courtesyPrefix$reason]');
    }
    if (parts.isEmpty) return null;
    return parts.join('\n');
  }

  String? _buildAutoPromoNotes({
    required String? originalNotes,
    required String promoId,
  }) {
    final baseNotes = _stripManagedNotes(originalNotes);
    final parts = <String>[];
    if (baseNotes.isNotEmpty) {
      parts.add(baseNotes);
    }
    parts.add('$_promoPrefix$promoId]');
    return parts.join('\n');
  }

  Future<bool> _applyAutomaticPromotionsIfNeeded() async {
    final order = state.order;
    final businessId = _activeBusinessId;
    if (order == null || businessId == null || businessId.isEmpty) {
      return false;
    }

    final now = DateTime.now();
    final weekday = now.weekday % 7;
    final openItems = state.items
        .where((item) => item.status != 'paid' && item.status != 'void')
        .toList(growable: false);
    if (openItems.isEmpty) return false;

    final promosRaw = await Supabase.instance.client
        .from('promotions')
        .select(
          'id,name,promo_type,discount_type,discount_value,min_purchase,target_scope,applies_to,target_ids,days_of_week,auto_apply,is_active,start_date,end_date,buy_quantity,pay_quantity,reward_quantity,priority,stackable',
        )
        .eq('business_id', businessId)
        .eq('is_active', true)
        .eq('auto_apply', true)
        .order('priority', ascending: false)
        .order('created_at', ascending: false);

    final promos = List<Map<String, dynamic>>.from(promosRaw)
        .where((promo) {
          final start = DateTime.tryParse(
            promo['start_date']?.toString() ?? '',
          );
          final end = DateTime.tryParse(promo['end_date']?.toString() ?? '');
          final days =
              (promo['days_of_week'] as List?)
                  ?.map(
                    (value) => value is num
                        ? value.toInt()
                        : int.tryParse(value.toString()),
                  )
                  .whereType<int>()
                  .toList() ??
              const <int>[];
          final inDateRange =
              (start == null || !now.isBefore(start)) &&
              (end == null || !now.isAfter(end.add(const Duration(days: 1))));
          final inWeekday = days.isEmpty || days.contains(weekday);
          return inDateRange && inWeekday;
        })
        .toList(growable: false);

    if (promos.isEmpty) {
      final managedItems = openItems
          .where((item) => _extractAutoPromoId(item.notes) != null)
          .toList(growable: false);
      if (managedItems.isEmpty) return false;

      await Future.wait(
        managedItems.map(
          (item) => ref
              .read(salesRepositoryProvider)
              .updateItemDiscountAndNotes(
                itemId: item.id,
                discounts: 0,
                notes: _stripManagedNotes(item.notes).isEmpty
                    ? null
                    : _stripManagedNotes(item.notes),
                writePromotion: true,
                promotionId: null,
              ),
        ),
      );
      return true;
    }

    final eligibleBaseItems = openItems
        .where((item) {
          if (_hasCourtesyNote(item.notes)) return false;
          if (_isDealNote(item.notes)) return false;
          final existingPromoId = _extractAutoPromoId(item.notes);
          if (existingPromoId != null) return true;
          return item.discounts <= 0.009;
        })
        .toList(growable: false);

    if (eligibleBaseItems.isEmpty) return false;

    final updates =
        <({String itemId, double discount, String? notes, String promotionId})>[];
    final touchedItemIds = <String>{};

    List<OrderItem> itemsForPromo(Map<String, dynamic> promo) {
      final scope =
          promo['target_scope']?.toString() ??
          promo['applies_to']?.toString() ??
          'all';
      final targetIds =
          (promo['target_ids'] as List?)
              ?.map((value) => value?.toString() ?? '')
              .where((value) => value.isNotEmpty)
              .toSet() ??
          <String>{};
      return eligibleBaseItems
          .where((item) {
            if (touchedItemIds.contains(item.id)) return false;
            if (scope == 'product') {
              final productId = item.productId?.trim();
              return productId != null &&
                  productId.isNotEmpty &&
                  targetIds.contains(productId);
            }
            return true;
          })
          .toList(growable: false);
    }

    double grossAmount(OrderItem item) => _courtesyLineAmount(item);

    for (final promo in promos) {
      final promoId = promo['id']?.toString() ?? '';
      if (promoId.isEmpty) continue;
      final promoType =
          promo['promo_type']?.toString() ??
          promo['discount_type']?.toString() ??
          'percentage';
      final minPurchase = (promo['min_purchase'] as num?)?.toDouble() ?? 0.0;
      final targetItems = itemsForPromo(promo);
      if (targetItems.isEmpty) continue;

      final grossTotal = targetItems.fold<double>(
        0,
        (sum, item) => sum + grossAmount(item),
      );
      if (grossTotal + 0.001 < minPurchase) continue;

      if (promoType == 'bogo') {
        final buyQty = (promo['buy_quantity'] as num?)?.toInt() ?? 2;
        final payQty = (promo['pay_quantity'] as num?)?.toInt() ?? 1;
        final freeQty = (buyQty - payQty) > 0
            ? (buyQty - payQty)
            : ((promo['reward_quantity'] as num?)?.toInt() ?? 1);
        if (buyQty <= 1 || freeQty <= 0) continue;

        final sorted = [...targetItems]
          ..sort((a, b) => grossAmount(a).compareTo(grossAmount(b)));
        final groups = sorted.length ~/ buyQty;
        final freeItemsCount = groups * freeQty;
        for (var i = 0; i < freeItemsCount && i < sorted.length; i++) {
          final item = sorted[i];
          final discount = grossAmount(
            item,
          ).clamp(0, double.infinity).toDouble();
          updates.add((
            itemId: item.id,
            discount: double.parse(discount.toStringAsFixed(2)),
            notes: _buildAutoPromoNotes(
              originalNotes: item.notes,
              promoId: promoId,
            ),
            promotionId: promoId,
          ));
          touchedItemIds.add(item.id);
        }
        continue;
      }

      for (final item in targetItems) {
        final gross = grossAmount(item);
        final discountValue =
            (promo['discount_value'] as num?)?.toDouble() ?? 0.0;
        double discount = 0;
        if (promoType == 'fixed') {
          discount = discountValue.clamp(0, gross).toDouble();
        } else if (promoType == 'percentage') {
          discount = (gross * (discountValue.clamp(0, 100) / 100.0))
              .clamp(0, gross)
              .toDouble();
        } else if (promoType == 'bundle_price') {
          discount = (gross - discountValue).clamp(0, gross).toDouble();
        }
        if (discount <= 0.009) continue;
        updates.add((
          itemId: item.id,
          discount: double.parse(discount.toStringAsFixed(2)),
          notes: _buildAutoPromoNotes(
            originalNotes: item.notes,
            promoId: promoId,
          ),
          promotionId: promoId,
        ));
        touchedItemIds.add(item.id);
      }
    }

    final staleManagedItems = openItems
        .where((item) {
          final promoId = _extractAutoPromoId(item.notes);
          return promoId != null &&
              !updates.any((update) => update.itemId == item.id);
        })
        .toList(growable: false);

    if (updates.isEmpty && staleManagedItems.isEmpty) return false;

    var changed = false;
    for (final update in updates) {
      final current = openItems.firstWhere((item) => item.id == update.itemId);
      final currentPromoId = _extractAutoPromoId(current.notes);
      final expectedPromoId = _extractAutoPromoId(update.notes);
      final normalizedCurrentNotes = _stripManagedNotes(current.notes);
      final normalizedNewNotes = _stripManagedNotes(update.notes);
      final sameDiscount = (current.discounts - update.discount).abs() <= 0.009;
      final samePromo =
          currentPromoId == expectedPromoId &&
          normalizedCurrentNotes == normalizedNewNotes;
      if (sameDiscount && samePromo) continue;

      await ref
          .read(salesRepositoryProvider)
          .updateItemDiscountAndNotes(
            itemId: update.itemId,
            discounts: update.discount,
            notes: update.notes,
            writePromotion: true,
            promotionId: update.promotionId,
          );
      changed = true;
    }

    for (final item in staleManagedItems) {
      await ref
          .read(salesRepositoryProvider)
          .updateItemDiscountAndNotes(
            itemId: item.id,
            discounts: 0,
            notes: _stripManagedNotes(item.notes).isEmpty
                ? null
                : _stripManagedNotes(item.notes),
            writePromotion: true,
            promotionId: null,
          );
      changed = true;
    }

    return changed;
  }
}
