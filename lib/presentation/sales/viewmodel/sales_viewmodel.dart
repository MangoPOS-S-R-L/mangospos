import 'dart:async';

import 'package:mangopos/core/network/resilient_http_client.dart';
import 'package:mangopos/core/performance/performance_diagnostics.dart';
import 'package:mangopos/core/storage/storage_service.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/core/multimesero/active_waiter_provider.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/order_item_snapshot.dart';
import 'package:mangopos/core/offline/offline_catalog_service.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/offline/offline_queue_status_provider.dart';
import 'package:mangopos/core/offline/hub/hub_mode.dart' show kHubModeEnabled;
import 'package:mangopos/core/offline/hub/hub_config.dart' show TerminalMode;
import 'package:mangopos/core/offline/hub/hub_client.dart' show HubClient;
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart'
    show hubModeProvider;
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/core/tax/tax_engine.dart';
import 'package:mangopos/core/tax/tax_exceptions.dart';
import 'package:mangopos/data/utils/bogo_promo_allocator.dart';
import 'package:mangopos/data/utils/loyalty_reward_utils.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/core/multimesero/operator_permissions.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'retail_carts_provider.dart';
import 'menu_browser_viewmodel.dart' show MenuProduct;
import 'sales_by_zone_viewmodel.dart' show byZoneVmProvider;
import '../state/sales_state.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/models/order_item_tax_line.dart';
import '../../cashier/viewmodel/cashier_viewmodel.dart'
    show cashierViewModelProvider, cashierRepositoryProvider;
import '../../inventory/viewmodel/inventory_viewmodel.dart'
    show inventoryRepositoryProvider;
import '../../../services/fiscal/fiscal_service.dart';
import '../../../data/models/fiscal_models.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:mangopos/core/utils/display_name_utils.dart';

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

  /// Modificador de catálogo (modifiers.id) que originó esta línea. Es la
  /// identidad que el inventario usa para descontar sus insumos
  /// (modifier_ingredients): sin ella solo queda el nombre en texto, que no
  /// sirve para descontar. NULL en los componentes de combo (esos van por
  /// [menuItemId]) y en cualquier modifier armado a mano.
  final String? modifierId;

  const SelectedModifierInput({
    required this.name,
    this.qty = 1,
    this.price = 0,
    this.menuItemId,
    this.modifierId,
  });

  Map<String, dynamic> toMap() => {
    'name': name,
    'qty': qty,
    'price': price,
    if (menuItemId != null) 'menu_item_id': menuItemId,
    if (modifierId != null) 'modifier_id': modifierId,
  };
}

/// Sentinel (m2b): en modo Hub cortocircuitamos la llamada a Supabase de las
/// mutaciones de ítem y saltamos directo al encolado (que enruta la op al Hub),
/// para no perder segundos intentando el WAN. Se lanza tras el update optimista
/// y `_shouldTreatAsOffline` lo reconoce como "encolar".
class _HubModeShortCircuit implements Exception {
  const _HubModeShortCircuit();
}

/// Cambio rechazado sobre una línea de la ronda de cocina: la comanda local
/// la está imprimiendo, o ya salió a cocina mientras el modal seguía abierto.
/// El texto va tal cual al cajero (el modal lo muestra y no se cierra).
class _KitchenRoundEditBlocked implements Exception {
  const _KitchenRoundEditBlocked(this.message);
  final String message;
  @override
  String toString() => message;
}

/// El servidor no anuló una venta en una anulación automática
/// (fn_void_order_if_unpaid): ya estaba cerrada ('already_closed') o tiene
/// cobros ('has_payments').
class _OrderNotVoidable implements Exception {
  const _OrderNotVoidable(this.result);
  final String result;
  @override
  String toString() => 'La venta no se anuló: $result';
}

/// Cliente de la orden (sesión) elegido con el botón "Cliente".
class _OrderCustomer {
  const _OrderCustomer({
    required this.id,
    required this.name,
    this.legalName,
    this.taxId,
  });

  final String id;
  final String name;
  final String? legalName;
  final String? taxId;
}

/// Cliente ya aplicado en pantalla que el servidor todavía no confirma (ver
/// `SalesViewModel._pendingCustomers`).
class _PendingOrderCustomer {
  _PendingOrderCustomer(this.customer) : at = DateTime.now();

  final _OrderCustomer customer;
  final DateTime at;
  bool savedOnServer = false;
  bool pushing = false;
}

/// Respuesta del servidor sobre la sesión de una venta rápida/manual que se
/// quiere retomar (ver `_confirmVirtualSaleSession`).
enum _VirtualSaleSession {
  confirmed,
  rejected,
  unreachable,
  unknown,

  /// Sesión de esta pantalla cerrada, con altas de la venta aún por subir
  /// desde este equipo: decide la carga (ver _confirmVirtualSaleSession).
  revivable,
}

typedef _PreloadedOrderBundle = ({
  Order? order,
  List<OrderItem> items,
  List<OrderCheck> checks,
  String? customerId,
  String? customerName,
  String? note,
});

class _OrderMutationContext {
  _OrderMutationContext({
    required this.orderId,
    required this.businessId,
    required this.origin,
    required this.tableId,
    required this.slotId,
    required this.selectionToken,
    required this.pinEmployeeId,
    required this.pinEmployeeName,
    required this.actorEmployeeId,
    required this.userId,
    required this.snapshot,
  });

  final String orderId;
  final String? businessId;
  final String? origin;
  final String? tableId;
  final String? slotId;
  final int selectionToken;
  // Mesero con PIN confiable al tocar: autor del ítem en la misma alta.
  final String? pinEmployeeId;
  final String? pinEmployeeName;
  // Quién opera (PIN o empleado del usuario autenticado): solo para retiros,
  // nunca como autor de un ítem.
  final String? actorEmployeeId;
  // Usuario autenticado al tocar: si otro entra mientras la acción sigue en
  // vuelo, su empleado no se anota en lo que hizo el anterior.
  final String? userId;
  CurrentOrderState snapshot;
}

class SalesViewModel extends Notifier<CurrentOrderState> {
  static const _courtesyPrefix = '[CORTESIA:';
  static const _promoPrefix = '[PROMO_AUTO:';
  // Línea vendida como OFERTA (tile del catálogo): ya viene al precio final, el
  // motor de auto-ofertas debe IGNORARLA para no volver a descontarla.
  static const _dealPrefix = '[DEAL:';
  final Map<String, CurrentOrderState> _tableCache = {};
  // Token de la apertura de mesa vigente: la hidratación cache-first desde
  // disco (async) solo aplica si su token sigue siendo el actual — abrir la
  // mesa A y saltar rápido a la B no debe pintar el snapshot de A.
  int _openTableToken = 0;
  // Mesa actualmente cargada en el state (origin == 'table'). Es la clave
  // canónica del snapshot offline de la mesa: TODAS las lecturas
  // (fallback de openTable, hidratación cache-first, overlay del salón)
  // buscan el snapshot por tableId, así que las escrituras de
  // _persistCurrentState deben usar la MISMA clave. Antes, las mutaciones
  // offline persistían bajo sessionId → un slot que nadie leía, y al
  // reentrar a la mesa sin red la cuenta aparecía como al abrirla
  // (vacía si todo se agregó en esa sesión).
  String? _activeTableId;
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
  String? _queuedRefreshOrderId;
  bool _queuedClearIfPaid = false;
  bool _refreshOrderInFlight = false;
  // Guarda anti-parpadeo al BORRAR: ids de items eliminados optimistamente
  // cuyo borrado el server aún no confirmó. Mientras estén aquí, cualquier
  // recarga (refreshOrder/Realtime) los FILTRA → no reaparecen. Se limpian
  // cuando una recarga ya no los trae (server confirmó) o al cambiar de orden.
  final Set<String> _pendingDeletedItemIds = {};
  // Guarda anti-parpadeo al CAMBIAR CANTIDAD: itemId → qty esperada del cambio
  // optimista en vuelo. Mientras el server no confirme esa qty, una recarga
  // stale (qty vieja) NO revierte la línea — se mantiene la optimista.
  final Map<String, double> _pendingItemQty = {};
  final Map<String, int> _itemQuantityMutationVersions = {};
  // Líneas (draft/open) de una comanda en envío, por negocio: desde que
  // confirmOrder captura la ronda, también durante el intento por la nube
  // que puede caer a la LAN. Mientras dure no se les cambia la cantidad ni
  // se borran: lo impreso y la cuenta divergirían, la línea quedaría «por
  // confirmar» y el siguiente «Enviar» la reimprimiría entera (o cocina
  // prepararía algo que ya no se cobra).
  // [renamedIds]: línea temporal (`tmp_`) cuyo alta en línea terminó durante
  // la impresión → su id real, que también queda bloqueado.
  final List<
    ({String businessId, Set<String> itemIds, Map<String, String> renamedIds})
  >
  _localKitchenPrints = [];
  static const _localKitchenPrintBusyMessage =
      'Espera a que termine de enviarse la comanda para cambiar este '
      'producto.';
  static const _kitchenRoundAlreadySentMessage =
      'Este producto ya salió a cocina. Ábrelo de nuevo para cambiar la '
      'cantidad.';
  // Guarda anti-parpadeo al AGREGAR: ids temporales (`tmp_`) de items agregados
  // optimistamente cuyo INSERT aún no confirma el server. Mientras estén aquí,
  // una recarga stale (que corre ANTES de que el INSERT haga commit — típico
  // del eco Realtime de una acción previa) NO descarta el item optimista; se
  // mantiene en la lista. Sin esto, el item recién tocado "sale y vuelve".
  final Set<String> _inFlightAddTmpIds = {};
  // Mapeo `tmp_` → id real (lo devuelve `addItemFromMenu`). Permite SOLTAR el
  // optimista solo cuando el server YA trae su contraparte real, evitando un
  // duplicado (tmp + real) en la recarga post-commit.
  final Map<String, String> _tmpToRealItemId = {};
  // Generación monótona de cargas de orden. Cada `_loadOrderDetail` toma un
  // número al entrar y, justo antes de escribir el state, verifica que siga
  // siendo la carga vigente; si ya arrancó una más nueva, descarta su resultado
  // en vez de pisar el state. Raíz del bug "el item agregado desaparece pero al
  // salir y reentrar a la mesa está": dos `_loadOrderDetail` solapados hacían
  // last-write-wins, y un reload stale en vuelo (eco Realtime que empezó a leer
  // la BD ANTES del commit del INSERT) aterrizaba de último y borraba el item
  // recién agregado de la lista —aunque en la BD sí quedó—. El más nuevo lee la
  // data más fresca y gana; cualquier carga vieja en vuelo sale sin escribir.
  int _loadGeneration = 0;
  // La carga de detalle que tomó la generación vigente. Quien necesita datos
  // del servidor y vio su carga reemplazada por otra de la misma cuenta espera
  // esta en vez de leer lo pintado (ver reloadOrderNow).
  ({int generation, String orderId, Future<void> done})? _latestOrderLoad;
  // Generación de la última carga que escribió en pantalla lo que respondió
  // el servidor.
  int _freshLoadGeneration = 0;
  // Tope de lo que reloadOrderNow espera, además de su propia carga, a las
  // que la reemplazan.
  static const _reloadFollowBudget = Duration(seconds: 10);
  // Overrides fiscales por sub-cuenta elegidos por el cajero en el header
  // (tipo de comprobante y cliente/RNC del check). Se REAPLICAN tras cada
  // recarga porque el bundle de la BD viva puede no devolver `requested_ncf_type`
  // / `customer_rnc` (divergencia), lo que hacía revertir la selección a B02 al
  // recargar (p. ej. al asignar cliente). `containsKey` = el cajero lo fijó;
  // valor null en NCF = volver al default del business. Se podan al cambiar de
  // orden o cuando el check ya no existe. La BD sigue siendo la fuente durable.
  final Map<String, String?> _checkNcfOverride = {};
  final Map<String, ({String? id, String? name, String? rnc})>
  _checkCustomerOverride = {};
  // Cliente de la orden que el cajero ya eligió pero el servidor aún no
  // confirma (sin red, orden local o RPC en vuelo), por order_id. Se reaplica
  // tras cada recarga hasta que el bundle lo traiga: antes una recarga stale
  // (o la falta de red) lo borraba y la comanda/factura salían sin nombre.
  // Al sincronizar, sigue a la orden cuando el `local-order-…` se remapea.
  final Map<String, _PendingOrderCustomer> _pendingCustomers = {};
  // Cliente elegido cuando la venta rápida/manual todavía no tenía orden
  // (abriéndose, o la anterior cerrándose tras el cobro). Se aplica a la venta
  // nueva en cuanto abre, solo si es del mismo negocio.
  ({String origin, String? businessId, _OrderCustomer customer, DateTime at})?
  _nextOrderCustomer;
  // Venta rápida/manual ya cobrada que sigue en pantalla mientras se abre la
  // siguiente. Un cliente elegido en esa ventana es para la venta nueva.
  String? _closingOrderId;
  // Apertura de venta rápida/manual en curso. ensureManualOrder/
  // ensureQuickOrder se unen a ella en vez de arrancar otra: cada apertura en
  // el servidor crea una venta nueva, y la que se reemplazaba a medio camino
  // quedaba abierta y vacía, ocupando un carril.
  ({String origin, int token, Future<void> future})? _virtualOpenInFlight;
  bool _syncInFlight = false;
  // Pedido force ("Sincronizar ahora", reintentar dead, cobro de una venta
  // local) que llegó con una pasada en curso: corre otra pasada forzada al
  // terminar esa, y quien lo pidió espera ESA pasada (antes regresaba de
  // inmediato sin sincronizar nada).
  Completer<void>? _forcedSyncRerun;
  String? _taxSettingsBusinessId;
  DateTime? _lastTaxLoad;
  String? _fiscalSettingsBusinessId;
  DateTime? _lastFiscalSettingsLoad;
  // Cache del employee_id derivado del usuario autenticado de Supabase.
  // Usado como fallback de `created_by_employee_id` cuando el cajero/admin
  // agrega items sin pasar por el PIN multimesero. Se guarda POR usuario y
  // negocio: la llave evita que, tras cambiar de sucursal o de usuario, un
  // ítem o un retiro salga a nombre del empleado anterior, incluso si una
  // consulta en vuelo responde después del cambio.
  String? _cachedAuthEmployeeKey;
  String? _cachedAuthEmployeeId;
  // Tope de cada consulta de atribución (dueño de la mesa, empleado del
  // usuario, sello del autor): con la red conectada pero mala no debe frenar
  // los extras ni la recarga del alta.
  static const Duration _attributionTimeout = Duration(seconds: 4);
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

  /// ActiveWaiter "confiable" para atribución de identidad (opener de
  /// mesa, created_by de items). Solo cuenta si:
  ///   - el device opera con rol `mesero` — único flujo donde el salón
  ///     pide PIN multimesero al abrir/entrar a cada mesa, así que el
  ///     state está recién validado; y
  ///   - el PIN pertenece al negocio activo.
  /// Sin este gate, un PIN validado horas antes en el mismo device se
  /// "pegaba" a mesas abiertas por otro usuario (cajero/admin u otro
  /// mesero tras relogin) y la precuenta/factura salía con el mesero
  /// equivocado.
  ActiveWaiter? _trustedActiveWaiter() {
    final waiter = ref.read(activeWaiterProvider);
    if (waiter == null) return null;
    final session = ref.read(sessionProvider);
    if (session.activeRole != PosRole.mesero) return null;
    final businessId = _activeBusinessId;
    if (businessId == null ||
        businessId.isEmpty ||
        waiter.businessId != businessId) {
      return null;
    }
    return waiter;
  }

  /// Quién abre una venta sin red, capturado AL ABRIRLA: el mesero del PIN
  /// o, sin PIN, la cuenta que la abre (lo mismo que el servidor guarda en
  /// línea). Lo anota el borrador local para el replay y para el «MESERO:»
  /// impreso sin red; así no sale quien esté logueado a la hora de imprimir.
  ({String? employeeId, String? name}) _localDraftOpener() {
    final waiter = _trustedActiveWaiter();
    if (waiter != null) {
      return (
        employeeId: waiter.employeeId,
        name: preferredDisplayName(fullName: waiter.displayName),
      );
    }
    final account = ref.read(sessionProvider).userName?.trim() ?? '';
    return (
      employeeId: null,
      name: account.isEmpty ? null : preferredDisplayName(fullName: account),
    );
  }

  /// Respaldo del «MESERO:» de la comanda cuando la pantalla no lo resolvió
  /// y los ítems no traen autor: quién abrió la venta sin red, anotado al
  /// abrirla. NUNCA el usuario logueado: quien envía o cobra no es quien
  /// abrió la mesa, y ese respaldo sacaba comandas a su nombre.
  Future<String?> _localOpenerName(String businessId, String orderId) async =>
      (await _offlinePos.localOrderOpener(
        businessId: businessId,
        orderId: orderId,
      ))?.name;

  /// Devuelve el `employee_id` que se debe asignar a un item recién creado
  /// como autor (`order_items.created_by_employee_id`).
  ///
  /// Política del negocio (decisión 2026-07-15): el item pertenece a QUIEN
  /// LO AGREGA (el mesero con PIN activo en el device), aunque la mesa la
  /// haya abierto otro mesero. La identidad de la MESA es aparte: el
  /// "MESERO:" de comanda/precuenta/factura sale del opener inmutable
  /// (`table_sessions.opened_by_employee_id` vía `fn_order_opener_name`)
  /// y NO cambia porque otro PIN entre a agregar productos o a imprimir.
  ///
  /// Prioridad:
  ///   1. [pinEmployeeId] — el mesero con PIN confiable capturado al tocar
  ///      es quien está físicamente agregando el item.
  ///   2. Opener de la mesa vía `fn_order_opener_employee_id` (sin la RPC,
  ///      `table_sessions.opened_by_employee_id`) — fallback cuando no hay
  ///      PIN activo (multimesero off / roles sin PIN). Va ANTES del
  ///      usuario conectado: el «MESERO:» de la comanda sale del autor de
  ///      los ítems, y acreditarle al cajero un ítem de la mesa de un mesero
  ///      lo imprimiría como mesero. No aplica a Venta Rápida/Manual: el
  ///      equipo retoma su venta aunque cambie el cajero, y una venta offline
  ///      la abre en el servidor el equipo que sincroniza; su «dueño» no es
  ///      quien digita.
  ///   3. Usuario autenticado en Supabase → su fila en `employees` para
  ///      el negocio capturado, vía `fn_current_employee_id`. Cubre el
  ///      caso del cajero/admin sin PIN.
  ///   4. `null` — el item queda sin atribución (los reportes lo acreditan
  ///      al mesero que abrió la mesa con PIN) y el tooltip muestra
  ///      "Sin asignar".
  ///
  /// Resuelve SIEMPRE sobre la orden, el negocio y el usuario capturados al
  /// tocar, no sobre la cuenta que esté en pantalla. Si la consulta del
  /// dueño de la mesa falla o pasa del tope, sigue al paso 3 (decisión del
  /// dueño, fase 4: sin saber quién abrió, el ítem va al empleado del
  /// usuario conectado, como antes).
  ///
  /// Las dos RPCs usan SECURITY DEFINER porque RLS sobre `employees`
  /// bloquea SELECT directo desde Flutter para cajeros sin permisos
  /// especiales. Los resultados se cachean cuando aplica:
  /// - `_cachedAuthEmployeeId`: el employee del auth user (1 query por
  ///   usuario y negocio).
  /// - El opener se resuelve cada vez porque puede cambiar entre mesas;
  ///   si esto se vuelve hot path, agregar cache por orderId.
  Future<String?> _resolveItemEmployeeId({
    required String orderId,
    required String? origin,
    required String? businessId,
    required String? userId,
    required String? pinEmployeeId,
  }) async {
    // 1) PIN multimesero capturado al tocar: es quien agrega el item.
    if (pinEmployeeId != null && pinEmployeeId.isNotEmpty) {
      return pinEmployeeId;
    }

    // 2) Roles que no piden PIN (cajero, administrador, supervisor): entran
    // con su propio usuario, así que el item es de ese usuario aunque la mesa
    // la haya abierto otro mesero (decisión del dueño, 2026-10-10). Si sin
    // red no se conoce su empleado, queda sin autor: nunca a nombre de otro.
    if (ref.read(sessionProvider).activeRole != PosRole.mesero) {
      return _resolveAuthEmployeeId(businessId: businessId, userId: userId);
    }

    // 3) Mesero sin PIN: opener de la mesa de la orden CAPTURADA.
    final virtualSale = origin == 'quick' || origin == 'manual';
    if (!virtualSale &&
        orderId.isNotEmpty &&
        !orderId.startsWith('local-order-')) {
      try {
        final openerId = await ref
            .read(salesRepositoryProvider)
            .fetchOrderOpenerEmployeeId(orderId)
            .timeout(_attributionTimeout);
        if (openerId != null && openerId.isNotEmpty) {
          // El autor es el dueño, pero la caché del empleado de este usuario
          // queda lista (sin usarlo como autor): un retiro sin red debe
          // registrar a quien lo hace. Antes la llenaba esta misma alta.
          unawaited(
            _resolveAuthEmployeeId(businessId: businessId, userId: userId),
          );
          return openerId;
        }
      } catch (e) {
        debugPrint('[audit] dueño de la mesa no resuelto: $e');
      }
    }

    return _resolveAuthEmployeeId(businessId: businessId, userId: userId);
  }

  String _authEmployeeKey(String businessId) =>
      '${ref.read(sessionProvider).userId ?? ''}|$businessId';

  /// Empleado del usuario autenticado ya conocido para [businessId] (sin
  /// red). Solo responde si la caché es de este mismo usuario y negocio.
  String? _cachedAuthEmployeeIdFor(String? businessId) {
    if (businessId == null || businessId.isEmpty) return null;
    return _cachedAuthEmployeeKey == _authEmployeeKey(businessId)
        ? _cachedAuthEmployeeId
        : null;
  }

  void _clearAuthEmployeeCache() {
    _cachedAuthEmployeeKey = null;
    _cachedAuthEmployeeId = null;
  }

  /// El `employee_id` del usuario autenticado en Supabase para [businessId]
  /// (cajero/admin sin PIN), cacheado por usuario y negocio. Con [userId],
  /// devuelve null si en el equipo ya entró otro usuario (antes o durante la
  /// consulta): su empleado no es quien hizo la acción.
  Future<String?> _resolveAuthEmployeeId({
    required String? businessId,
    String? userId,
  }) async {
    if (businessId == null || businessId.isEmpty) return null;
    if (userId != null && ref.read(sessionProvider).userId != userId) {
      return null;
    }
    final cached = _cachedAuthEmployeeIdFor(businessId);
    if (cached != null) return cached;
    final key = _authEmployeeKey(businessId);

    try {
      final resolved = await ref
          .read(salesRepositoryProvider)
          .fetchCurrentEmployeeId(businessId)
          .timeout(_attributionTimeout);
      if (resolved == null || resolved.isEmpty) return null;
      // La consulta corrió con el usuario de ESE momento: si cambió mientras
      // tanto, el resultado no sirve ni para la caché ni como autor.
      if (_authEmployeeKey(businessId) != key) return null;
      _cachedAuthEmployeeKey = key;
      _cachedAuthEmployeeId = resolved;
      return resolved;
    } catch (e) {
      debugPrint('[audit] fn_current_employee_id falló: $e');
      return null;
    }
  }

  /// Sella el autor de un ítem recién guardado SIN PIN: el dueño de la mesa
  /// de la orden CAPTURADA (aunque el cajero ya haya cambiado de cuenta) o,
  /// si no hay dueño o no se pudo saber, el empleado del usuario autenticado
  /// de ese negocio.
  /// Cada consulta lleva tope y nunca lanza: el ítem y sus extras ya quedaron
  /// guardados y un fallo aquí no debe encolar ni revertir nada.
  Future<void> _stampItemAuthor(
    _OrderMutationContext mutation,
    String itemId,
  ) async {
    try {
      final employeeId = await _resolveItemEmployeeId(
        orderId: mutation.orderId,
        origin: mutation.origin,
        businessId: mutation.businessId,
        userId: mutation.userId,
        pinEmployeeId: null,
      );
      if (employeeId == null) return;
      await ref
          .read(salesRepositoryProvider)
          .setItemCreatedByEmployee(itemId: itemId, employeeId: employeeId)
          .timeout(_attributionTimeout);
    } catch (e) {
      debugPrint('[audit] no se pudo set created_by_employee_id: $e');
      // No abortamos el flujo — el item igual quedó creado.
    }
  }

  /// Anota quién quitó un producto ya enviado a cocina y por qué (lo borró
  /// o le bajó la cantidad): el servidor registra el cambio, pero no sabe el
  /// motivo ni el operador con PIN. Quien lo hizo es el mesero con PIN activo
  /// o el usuario de la tablet; NO quien abrió la mesa. Nunca lanza.
  Future<void> noteItemRemoval(
    String itemId, {
    String? reason,
    String? reasonCode,
    bool? isWaste,
  }) async {
    try {
      final businessId = _activeBusinessId;
      final employeeId =
          _trustedActiveWaiter()?.employeeId ??
          await _resolveAuthEmployeeId(
            businessId: businessId,
            userId: ref.read(sessionProvider).userId,
          );
      await ref
          .read(salesRepositoryProvider)
          .noteItemRemoval(
            itemId: itemId,
            reason: reason,
            employeeId: employeeId,
            reasonCode: reasonCode,
            isWaste: isWaste,
          );
    } catch (e) {
      debugPrint('[removals] noteItemRemoval: $e');
    }
  }

  /// Igual que [noteItemRemoval], con el negocio, el usuario y el PIN
  /// capturados al tocar: el borrado espera al servidor y en ese lapso pudo
  /// cambiar la sucursal o el usuario del equipo.
  Future<void> _noteItemRemovalFor(
    _OrderMutationContext mutation,
    String itemId, {
    String? reason,
    String? reasonCode,
    bool? isWaste,
  }) async {
    try {
      final employeeId =
          mutation.actorEmployeeId ??
          await _resolveAuthEmployeeId(
            businessId: mutation.businessId,
            userId: mutation.userId,
          );
      await ref
          .read(salesRepositoryProvider)
          .noteItemRemoval(
            itemId: itemId,
            reason: reason,
            employeeId: employeeId,
            reasonCode: reasonCode,
            isWaste: isWaste,
          );
    } catch (e) {
      debugPrint('[removals] noteItemRemoval: $e');
    }
  }

  /// Invalida la caché del empleado autenticado al cambiar de negocio o de
  /// usuario. La llave (usuario|negocio) ya impide usar un empleado ajeno;
  /// esto es protección extra. `build()` los registra siempre; queda visible
  /// para que las pruebas que reemplazan `build()` ejerciten estos mismos
  /// listeners.
  @visibleForTesting
  void listenAuthEmployeeIdentity() {
    ref.listen(sessionProvider.select((s) => s.activeBusinessId), (
      previous,
      next,
    ) {
      if (previous != next) _clearAuthEmployeeCache();
    });
    // Otro usuario en el mismo equipo (cierre de sesión y entrada de otro):
    // su empleado es otro.
    ref.listen(sessionProvider.select((s) => s.userId), (previous, next) {
      if (previous != next) _clearAuthEmployeeCache();
    });
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
    if (_activeBusinessId != businessId) return;
    // Mientras se sube una venta para cobrarla, el banner dice eso (y no los
    // mensajes genéricos de la pasada que corre debajo).
    final promoting = isPromotingLocalOrder;
    state = state.copyWith(
      isOfflineMode: !_connectivity.isConnected,
      syncInFlight: promoting || (syncInFlight ?? _syncInFlight),
      pendingOfflineActions: pending,
      syncStatus: promoting
          ? _promotingSyncStatus
          : (syncStatus ?? state.syncStatus),
    );
  }

  // Debounce de la recarga de orden. Una acción (agregar/quitar/cantidad)
  // dispara el refresh explícito + los ecos de Realtime (order_items, orders).
  // Una ventana de 400ms colapsa esa ráfaga en UNA sola recarga del bundle en
  // vez de 2-3 → menos re-render del carrito = menos lag. El update optimista
  // ya hace que la acción se sienta instantánea, así que la reconciliación
  // puede esperar 400ms sin que el cajero lo note.
  static const _refreshOrderDebounce = Duration(milliseconds: 400);

  // Tope de ítems de la lectura de respaldo de `_loadOrderDetail` (el bundle
  // no tiene tope). Llegar a él marca el respaldo como incompleto.
  static const _fallbackItemsLimit = 500;

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
      ++_loadGeneration;
      ++_openTableToken;
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
      // La mesa activa, el cliente elegido para la venta siguiente y la venta
      // en cierre también son del negocio anterior.
      _activeTableId = null;
      _nextOrderCustomer = null;
      _closingOrderId = null;
      // Retail: los carritos pertenecían al negocio anterior.
      _activeRetailSlotId = null;
      ref.read(retailCartsProvider.notifier).clear();
      state = const CurrentOrderState();
    });
    listenAuthEmployeeIdentity();

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
        // Pasada automática (silenciosa: solo contadores), pero recarga la
        // venta activa aunque no suba nada: sin red, Realtime pudo perder
        // cambios hechos en otra caja.
        unawaited(syncPendingOfflineActions(reloadActiveOrder: true));
      }
    });

    // Ya no hay timer de respaldo propio (antes cada 3 min, sin revisar si
    // había algo listo y mostrando el aviso de "en espera"): el uplink del
    // shell (offlineSalesUplinkProvider) revisa cada 5 s y solo corre una
    // pasada si hay acciones listas, y HubHostUplink drena el op-log del Hub
    // cada 4 s.

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

    // Offline con el valor ya cargado de ESTE negocio: conservarlo (la
    // config fiscal es estable). Antes se intentaba el fetch en cada carga
    // y sin internet el catch pisaba el tipo por defecto con ''.
    if (_preferLocalOperations && _fiscalSettingsBusinessId == businessId) {
      return;
    }
    // Sin red y sin valor en memoria (arranque en frío offline): la última
    // copia en disco, en vez de esperar el timeout para quedar en ''.
    final diskKey = 'fiscal_default_ncf_type_$businessId';
    if (_preferLocalOperations) {
      try {
        final storage = await StorageService.getInstance();
        _cachedDefaultFiscalType = (await storage.read(diskKey)) ?? '';
      } catch (_) {
        _cachedDefaultFiscalType = '';
      }
      _fiscalSettingsBusinessId = businessId;
      _lastFiscalSettingsLoad = DateTime.now();
      return;
    }

    try {
      final row = await Supabase.instance.client
          .from('fiscal_settings')
          .select('default_ncf_type')
          .eq('business_id', businessId)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));

      final fresh = _normalizeFiscalTypeValue(
        row?['default_ncf_type']?.toString(),
      );
      // Solo se escribe a disco cuando cambia: esto corre en cada carga de
      // orden y en Windows cada escritura de prefs reescribe el archivo.
      if (fresh != _cachedDefaultFiscalType ||
          _fiscalSettingsBusinessId != businessId) {
        unawaited(
          StorageService.getInstance()
              .then((storage) => storage.write(diskKey, fresh))
              .catchError((_) => false),
        );
      }
      _cachedDefaultFiscalType = fresh;
    } catch (_) {
      // Conservar el último valor bueno si es del mismo negocio; solo
      // resetear cuando nunca se ha cargado nada para este negocio.
      if (_fiscalSettingsBusinessId != businessId) {
        _cachedDefaultFiscalType = '';
      }
    }

    _fiscalSettingsBusinessId = businessId;
    _lastFiscalSettingsLoad = DateTime.now();
  }

  // "Para llevar por defecto" por modo (business_settings). Cacheado por
  // businessId. Cuando el flag del modo está ON, las órdenes nuevas de ese
  // modo arrancan con takeout=true (no aplica a mesas).
  bool _defaultTakeoutQuick = false;
  bool _defaultTakeoutManual = false;
  bool _defaultTakeoutDelivery = false;
  String? _defaultTakeoutLoadedFor;

  Future<void> _ensureDefaultTakeoutLoaded() async {
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    if (_defaultTakeoutLoadedFor == businessId) return;
    // Sin red no hay nada que consultar: defaults en false y se reintenta
    // cuando vuelva la conexión (loadedFor no se marca). Evita un fetch
    // colgado por cada carga de orden offline. `_preferLocalOperations`
    // cubre también el rato en que el detector aún no admite la caída.
    if (_preferLocalOperations) return;
    try {
      final row = await Supabase.instance.client
          .from('business_settings')
          .select(
            'default_takeout_quick,default_takeout_manual,default_takeout_delivery',
          )
          .eq('business_id', businessId)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      _defaultTakeoutQuick = row?['default_takeout_quick'] == true;
      _defaultTakeoutManual = row?['default_takeout_manual'] == true;
      _defaultTakeoutDelivery = row?['default_takeout_delivery'] == true;
      _defaultTakeoutLoadedFor = businessId;
    } catch (_) {
      // best-effort: si falla, el default queda en false (sin para llevar).
    }
  }

  /// Devuelve si las órdenes nuevas de este `origin` deben arrancar "para
  /// llevar" según la config. Las mesas (dine-in) siempre false.
  bool _defaultTakeoutFor(String? origin) {
    switch (origin) {
      case 'quick':
        return _defaultTakeoutQuick;
      case 'manual':
        return _defaultTakeoutManual;
      case 'delivery':
        return _defaultTakeoutDelivery;
      default:
        return false;
    }
  }

  /// Default de "para llevar" para un ítem NUEVO: según el ORIGEN de la orden
  /// (mesa → consumo en mesa = false; delivery/rápida/manual → su default). NO
  /// se hereda de `state.takeout` ni de otros ítems: marcar ítems sueltos
  /// "para llevar" ya NO contagia a los productos que se agreguen después. El
  /// cajero marca cada ítem con toggleItemTakeout cuando aplique.
  bool defaultTakeoutForNewItem() => _defaultTakeoutFor(state.origin);

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

    // Sin red (o recién fallada por red): se conservan los últimos impuestos
    // buenos de ESTE negocio, de memoria o de disco (la config fiscal es
    // estable y el servidor recalcula al sincronizar). Antes se intentaba el
    // fetch en CADA apertura de mesa y en CADA ítem (el TTL es de 1s) y, al
    // fallar, se vaciaban los impuestos y se marcaba `taxConfigError`, que
    // BLOQUEA el cobro: sin internet no se podía cobrar en toda la caída.
    final retryNotBefore = _taxNetworkRetryNotBefore;
    final inNetworkBackoff =
        retryNotBefore != null && DateTime.now().isBefore(retryNotBefore);
    if ((!_connectivity.isConnected || inNetworkBackoff) &&
        await _restoreTaxesWithoutNetwork(businessId)) {
      return;
    }
    if (!_connectivity.isConnected || inNetworkBackoff) {
      _setTaxConfigError(
        'Este equipo no tiene una copia de los impuestos del negocio. '
        'Conecta una vez para prepararlo antes de cobrar.',
      );
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
              'id,name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery,apply_on_takeout,include_in_ecf',
            )
            .eq('business_id', businessId)
            .eq('is_active', true)
            // Cota para la ventana "conectado pero malo": sin esto un fetch
            // colgado trababa la apertura de mesa (corre en el Future.wait
            // previo al RPC de apertura).
            .timeout(const Duration(seconds: 8));
        _cachedBusinessTaxes = List<Map<String, dynamic>>.from(taxRows);
        _taxNetworkRetryNotBefore = null;
        unawaited(
          PosLookupOfflineCache().saveBusinessTaxes(
            businessId,
            _cachedBusinessTaxes,
          ),
        );
      } catch (e) {
        if (OfflinePosService.isTransportError(e)) {
          _taxNetworkRetryNotBefore = DateTime.now().add(
            const Duration(seconds: 20),
          );
          unawaited(_connectivity.forceReachabilityCheck());
          if (await _restoreTaxesWithoutNetwork(businessId)) return;
        }
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
      _setTaxConfigError(e is TaxConfigException ? e.message : e.toString());
    }
  }

  /// Tras un fallo de RED no se reintenta la consulta de impuestos hasta esta
  /// hora: el loader corre en cada ítem y cada apertura de mesa, y mientras el
  /// detector aún no admite la caída cada intento esperaba su timeout.
  DateTime? _taxNetworkRetryNotBefore;

  // Una lectura real ya falló por red: no encadenar otro timeout para cada
  // producto mientras el healthcheck todavía está confirmando el corte.
  bool get _preferLocalOperations =>
      !_connectivity.isConnected ||
      (_taxNetworkRetryNotBefore != null &&
          DateTime.now().isBefore(_taxNetworkRetryNotBefore!));

  void _recordTransportFailure() {
    _taxNetworkRetryNotBefore = DateTime.now().add(const Duration(seconds: 20));
    unawaited(_connectivity.forceReachabilityCheck());
  }

  /// Impuestos sin tocar la red: los de memoria si son de este negocio, o la
  /// última copia en disco. `false` si no hay ninguna (primer uso sin red).
  Future<bool> _restoreTaxesWithoutNetwork(String businessId) async {
    if (_taxSettingsBusinessId == businessId &&
        _lastTaxLoad != null &&
        state.taxConfigError == null) {
      return true;
    }
    final rows = await PosLookupOfflineCache().loadBusinessTaxes(businessId);
    if (rows == null || _activeBusinessId != businessId) return false;
    _cachedBusinessTaxes = rows;
    _cachedTaxRatePct = 0.0;
    for (final tx in _cachedBusinessTaxes) {
      final def = TaxDef.fromMap(tx);
      if (!def.isActive || def.rate <= 0) continue;
      if (def.effectiveIsServiceFee) continue;
      _cachedTaxRatePct = def.rate;
      break;
    }
    _taxSettingsBusinessId = businessId;
    _lastTaxLoad = DateTime.now();
    _setTaxConfigError(null);
    return true;
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
      // Quitado a mano para esta orden desde el bloque de impuestos.
      if (tx.id.isNotEmpty && state.excludedTaxIds.contains(tx.id)) continue;

      final pctLabel = tx.rate.truncateToDouble() == tx.rate
          ? '${tx.rate.toInt()}%'
          : '${tx.rate}%';
      final amount = _roundMoney(subtotal * tx.rateDecimal);
      result.add((label: '${tx.name} ($pctLabel)', amount: amount));
    }

    return result;
  }

  // ── Quitar impuestos de una orden puntual ────────────────────────────────
  //
  // Estilo Square: el cajero abre el bloque de impuestos del carrito y
  // desmarca los que no quiere cobrar. La verdad la escribe el backend
  // (`fn_set_order_excluded_taxes`), que recalcula tasa y desglose de CADA
  // item; acá solo se refleja el estado para que la UI no parpadee.
  //
  // A propósito NO se filtran los `tax_lines` que ya vinieron del servidor:
  // si el RPC falló, la app tiene que mostrar lo que realmente se va a
  // cobrar, no lo que el cajero quiso. Una sola fuente de verdad.

  /// Impuestos del negocio que aplican al origen de venta actual. Es lo que
  /// lista el modal; los que no aplican a este origen ni siquiera se cobran,
  /// así que no tiene sentido ofrecerlos para quitar.
  List<TaxDef> availableTaxesForOrigin() {
    final origin = parseSaleOrigin(state.origin);
    return _taxDefs
        .where((tx) => tx.isActive && tx.rate > 0 && tx.appliesTo(origin))
        .where((tx) => tx.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Lee las exclusiones vigentes de la orden y las mete en el state.
  ///
  /// Se llama al ABRIR el modal, no en `_loadOrderDetail`: abrir mesa es el
  /// camino caliente que ya se optimizó y no vale gastarle un round-trip a
  /// cada apertura por una función que casi nunca se usa. Mientras el modal
  /// no se abra, el desglose que ve el cajero sale de los `tax_lines` reales
  /// del servidor, que ya vienen con la exclusión aplicada.
  Future<void> loadExcludedTaxes() async {
    final orderId = state.order?.id;
    if (orderId == null || orderId.startsWith('local-order-')) return;
    if (!_connectivity.isConnected) return;
    try {
      final rows = await Supabase.instance.client
          .from('order_excluded_taxes')
          .select('tax_id')
          .eq('order_id', orderId)
          .timeout(const Duration(seconds: 6));
      final ids = <String>{
        for (final row in rows)
          if (row['tax_id'] != null) row['tax_id'].toString(),
      };
      if (state.order?.id != orderId) return; // cambió de orden mientras tanto
      state = state.copyWith(excludedTaxIds: ids);
    } catch (e) {
      debugPrint('No se pudieron leer los impuestos excluidos: $e');
    }
  }

  /// Fija el conjunto COMPLETO de impuestos excluidos de la orden.
  ///
  /// Se manda el estado final de los checkboxes (no un toggle) para que dos
  /// cajas tocando la misma orden converjan al último envío en vez de
  /// acumular toggles cruzados.
  ///
  /// Devuelve null si salió bien, o el mensaje de error para mostrar.
  Future<String?> setExcludedTaxes(Set<String> taxIds) async {
    final orderId = state.order?.id;
    if (orderId == null || orderId.startsWith('local-order-')) {
      return 'Guarda la orden antes de cambiar los impuestos.';
    }
    // El motor de impuestos vive entero en el servidor: sin conexión no hay
    // forma de recalcular sin duplicar la fórmula fiscal en el cliente, que
    // es justo como nacen las divergencias de centavos.
    if (!_connectivity.isConnected) {
      return 'Se necesita conexión para cambiar los impuestos de la orden.';
    }

    final previous = state.excludedTaxIds;
    state = state.copyWith(excludedTaxIds: taxIds);
    try {
      // `excluded_by` responde «quién quitó este impuesto»: es quien HIZO la
      // acción (el mesero del PIN o el empleado del usuario conectado), como
      // en los retiros. Nunca el dueño de la mesa.
      final employeeId =
          _trustedActiveWaiter()?.employeeId ??
          await _resolveAuthEmployeeId(
            businessId: _activeBusinessId,
            userId: ref.read(sessionProvider).userId,
          );
      await Supabase.instance.client.rpc(
        'fn_set_order_excluded_taxes',
        params: {
          'p_order_id': orderId,
          'p_tax_ids': taxIds.toList(growable: false),
          'p_employee_id': employeeId,
        },
      );
      // El RPC ya reescribió tasas, tax_lines y totales: hay que releer para
      // que el carrito muestre los números del servidor y no la predicción.
      await reloadOrderNow();
      return null;
    } catch (e) {
      state = state.copyWith(excludedTaxIds: previous);
      debugPrint('fn_set_order_excluded_taxes falló: $e');
      return _humanizeExcludedTaxError(e);
    }
  }

  String _humanizeExcludedTaxError(Object e) {
    final raw = e.toString();
    if (raw.contains('comprobante fiscal')) {
      return 'Esta orden ya tiene comprobante fiscal emitido; sus impuestos '
          'no se pueden cambiar.';
    }
    if (raw.contains('No se pueden cambiar los impuestos')) {
      return 'La orden ya está cobrada o anulada.';
    }
    if (raw.contains('fn_set_order_excluded_taxes') ||
        raw.contains('PGRST202')) {
      return 'Falta aplicar la migración de impuestos por orden en la base '
          'de datos.';
    }
    return 'No se pudieron cambiar los impuestos: $raw';
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

    return items
        .map((item) {
          if (!item.isTakeout || item.taxLines.isEmpty) return item;

          final filtered = item.taxLines
              .where((line) {
                final applies =
                    byName[line.taxName.toLowerCase().trim()] ?? true;
                return applies;
              })
              .toList(growable: false);

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
        })
        .toList(growable: false);
  }

  CurrentOrderState _normalizeHydratedState(CurrentOrderState source) {
    final order = source.order;
    if (order == null || source.items.isEmpty) {
      // Sin items: el flag takeout arranca según la config "para llevar
      // por defecto" del modo (rápida/manual/delivery). Mesas → false.
      return source.copyWith(takeout: _defaultTakeoutFor(source.origin));
    }

    final activeItems = source.items
        .where((item) => item.status != 'void')
        .toList(growable: false);
    if (activeItems.isEmpty) {
      return source.copyWith(
        takeout: _defaultTakeoutFor(source.origin),
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
      total:
          orderSummary.subtotal +
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
            total:
                checkSummary.subtotal +
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
    final snapshot = state;
    final orderId = snapshot.order!.id;

    // Para mesas, la clave del snapshot es SIEMPRE el tableId (es la que
    // leen el fallback offline de openTable, la hidratación cache-first y
    // el overlay del salón). Si el caller no lo pasó (mutaciones de ítem),
    // usamos la mesa activa del viewmodel.
    final effectiveTableId =
        tableId ??
        (origin == 'table' || origin == 'delivery' ? _activeTableId : null);

    await _offlinePos.saveSnapshot(
      businessId: businessId,
      slotId: _resolvePersistSlotId(origin, effectiveTableId),
      origin: origin,
      tableId: effectiveTableId,
      state: snapshot,
      localOnly: localOnly,
    );

    // Mantener fresco también el cache en memoria de la mesa: antes solo se
    // actualizaba al abrir/cargar, así que salir y volver a la mesa tras una
    // mutación offline pintaba el estado viejo.
    if (origin == 'table' && effectiveTableId != null) {
      if (await _offlinePos.isOrderClosedLocally(
        businessId: businessId,
        orderId: orderId,
      )) {
        return;
      }
      if (state.order?.id == orderId) {
        _tableCache[effectiveTableId] = snapshot;
      }
    }
  }

  /// [businessId]: el del cobro, capturado al abrirlo; sin él, el activo.
  /// Con otra sucursal ya en pantalla solo se escribe la marca.
  Future<void> markPaidOrderLocally(String orderId, {String? businessId}) async {
    final targetBusinessId = businessId ?? _activeBusinessId;
    if (targetBusinessId == null || targetBusinessId.isEmpty) return;
    await _offlinePos.markOrderClosedLocally(
      businessId: targetBusinessId,
      orderId: orderId,
    );
    if (_activeBusinessId != targetBusinessId) return;
    _tableCache.removeWhere((_, cached) => cached.order?.id == orderId);
    if (state.order?.id == orderId) {
      ++_openTableToken;
      state = const CurrentOrderState();
    }
  }

  /// Clave de snapshot para persistir el state actual. Retail quick usa el
  /// slotId del carrito activo (un snapshot por carrito); mesas usan el
  /// tableId; quick/manual usan el origin.
  String _resolvePersistSlotId(String origin, String? tableId) {
    if (tableId != null) return tableId;
    if (origin == 'quick' && _activeRetailSlotId != null) {
      return _activeRetailSlotId!;
    }
    // Mesa sin tableId resoluble (no debería pasar): conservamos el
    // comportamiento legacy para no tirar el snapshot.
    if (origin == 'table') return state.order?.sessionId ?? origin;
    return origin;
  }

  Future<bool> ensureCashSessionOpen() async {
    final cashierVm = ref.read(cashierViewModelProvider);
    try {
      // PERF: primero la respuesta cacheada (TTL 12s). Solo si dice CERRADO
      // revalidamos con force:true — se conserva el fix de falsos negativos
      // (la caja se abría en otro proceso/empleado y este viewmodel tenía
      // `_lastSession` stale) sin pagar un viaje de red por cada apertura
      // de mesa cuando la caja ya está abierta. El falso positivo inverso
      // (caja cerrada en otro device hace <12s) es el mismo tradeoff que ya
      // documenta el camino offline de `ensureCashOpenFast`.
      var isOpen = await cashierVm.ensureCashOpenFast();
      if (!isOpen) {
        isOpen = await cashierVm.ensureCashOpenFast(force: true);
      }
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

  /// True SOLO si este terminal es una CAJA CLIENTE del Hub (LAN-first): sus
  /// mutaciones se enrutan al Hub por LAN en vez de directo a Supabase.
  ///
  /// El equipo Hub (host) NO entra aquí: tiene internet (es la puerta de
  /// enlace), así que opera NORMAL contra Supabase → órdenes y comprobantes
  /// reales al instante. Solo si el host pierde internet cae al respaldo
  /// (op-log) por el `catch` de H0 (`_shouldTreatAsOffline`). Esto arregla el
  /// "comprobante no carga al abrir la mesa" en la caja principal.
  bool get _isHubMode {
    return ref.read(hubModeProvider) == TerminalMode.hubClient;
  }

  /// Fix #1 (F3 hardening): cuando ESTE equipo es el Hub host, espeja una
  /// mutación YA aplicada a Supabase al op-log local para que las cajas cliente
  /// la VEAN por la LAN (`/hub/salon`, `/hub/order`). Antes el host, estando
  /// online, saltaba el op-log → las mesas que abría eran invisibles para los
  /// clientes. Inerte salvo en modo hubHost — un negocio en modo cloud NUNCA lo
  /// es, así que no afecta el flujo normal. Fire-and-forget: no bloquea ni
  /// puede romper la mutación del cajero (`publishHostOp` es best-effort).
  void _mirrorHostMutationToHub(Map<String, dynamic> op) {
    if (ref.read(hubModeProvider) != TerminalMode.hubHost) return;
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    unawaited(
      _offlinePos.publishHostOp(businessId, {
        ...op,
        'item_snapshot': ?_snapshotForItem(op['item_id']?.toString()),
      }),
    );
  }

  Map<String, dynamic>? _snapshotForItem(String? itemId) {
    for (final item in state.items) {
      if (item.id == itemId) return OrderItemSnapshot.encode(item);
    }
    return null;
  }

  /// Abre una mesa en modo Hub: resume el borrador local si ya existe en este
  /// equipo, si no crea uno nuevo y notifica al Hub con la op `open_table`
  /// (que mapea order↔table para el salón y el uplink). Reusa el camino offline
  /// (`local-order-…`) → las mutaciones de ítem se enrutan al Hub por el
  /// uploader de OfflinePosService.
  Future<void> _openTableViaHub(
    String tableId,
    int peopleCount,
    int openToken,
  ) async {
    final businessId = _activeBusinessId;
    bool stillSelected() =>
        openToken == _openTableToken && _activeBusinessId == businessId;
    if (businessId == null || businessId.isEmpty) {
      state = state.copyWith(loading: false, error: 'Sin negocio activo.');
      return;
    }
    try {
      // Paso 2 (proxy real-time): intentar abrir la mesa REAL a través del Hub
      // (que tiene internet). Devuelve el bundle completo con datos fiscales,
      // así el comprobante carga bien. Si el Hub no responde (offline), caemos
      // al respaldo local (borrador + op-log) de abajo.
      final hubUrl = ref.read(hubModeProvider.notifier).reachableHubUrl;
      if (hubUrl != null) {
        try {
          final result = await ref
              .read(salesRepositoryProvider)
              .openTableAndLoadViaHub(
                hubBaseUrl: hubUrl,
                tableId: tableId,
                userId: Supabase.instance.client.auth.currentUser?.id,
                peopleCount: peopleCount,
                openedByEmployeeId: _trustedActiveWaiter()?.employeeId,
              );
          if (!stillSelected()) return;
          if (await _offlinePos.isOrderClosedLocally(
            businessId: businessId,
            orderId: result.orderId,
          )) {
            throw StateError('El Hub devolvió una orden ya cobrada.');
          }
          if (!stillSelected()) return;
          await _loadOrderDetail(
            result.orderId,
            selectionToken: openToken,
            origin: 'table',
            tableId: tableId,
            caller: 'openTableViaHub',
            preloadedBundle: result.bundle,
          );
          return;
        } catch (e) {
          if (!stillSelected()) return;
          // Hub offline / sin respuesta → respaldo local (abajo).
          debugPrint('[openTableViaHub] proxy falló, uso respaldo local: $e');
        }
      }

      final existing = await _offlinePos.loadSnapshot(
        businessId: businessId,
        slotId: tableId,
      );
      final hubOrder = await _fetchHubOrder(businessId, tableId);
      if (!stillSelected()) return;
      final pendingHere = existing == null
          ? false
          : (await _offlinePos.unsettledActions(
              businessId,
            )).any((op) => op['order_id'] == existing.order?.id);
      // A cached order must not hide another terminal's acknowledged changes.
      // Keep local state only when its edits have not reached the Hub yet.
      final existingClosed =
          existing?.order?.id != null &&
          await _offlinePos.isOrderClosedLocally(
            businessId: businessId,
            orderId: existing!.order!.id,
          );
      if (!stillSelected()) return;
      if (existing != null &&
          !existingClosed &&
          (hubOrder == null || pendingHere)) {
        state = _normalizeHydratedState(
          existing.copyWith(loading: false, origin: 'table', error: null),
        );
        _tableCache[tableId] = state;
        unawaited(_hydrateFiscalSequencesOffline());
        return;
      }
      // 2. ¿El HUB ya tiene una orden abierta en esta mesa (la abrió OTRA
      //    caja)? → reconstruirla y resumirla para verla/cobrarla. Persistimos
      //    un snapshot local con el MISMO order_id del Hub para que las
      //    mutaciones (agregar ítem / cobrar) referencien esa misma orden.
      final hubOrderId =
          hubOrder?['order_id']?.toString() ?? hubOrder?['id']?.toString();
      final hubOrderClosed =
          hubOrderId != null &&
          await _offlinePos.isOrderClosedLocally(
            businessId: businessId,
            orderId: hubOrderId,
          );
      if (!stillSelected()) return;
      if (hubOrder != null &&
          !hubOrderClosed &&
          ((hubOrder['items'] as List?)?.isNotEmpty ?? false)) {
        final hydrated = stateFromHubOrder(hubOrder);
        await _offlinePos.saveSnapshot(
          businessId: businessId,
          slotId: tableId,
          origin: 'table',
          tableId: tableId,
          state: hydrated,
          localOnly: true,
        );
        if (!stillSelected()) return;
        state = _normalizeHydratedState(hydrated);
        _tableCache[tableId] = state;
        unawaited(_hydrateFiscalSequencesOffline());
        return;
      }
      // 3. Mesa nueva → borrador local + notificar al Hub.
      final draft = await _offlinePos.createLocalDraft(
        businessId: businessId,
        origin: 'table',
        tableId: tableId,
        opener: _localDraftOpener(),
      );
      if (!stillSelected()) return;
      final orderId = draft.order?.id;
      if (orderId != null) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'open_table',
            'origin': 'table',
            'order_id': orderId,
            'table_id': tableId,
          },
        );
      }
      if (!stillSelected()) return;
      state = _normalizeHydratedState(
        draft.copyWith(
          loading: false,
          origin: 'table',
          error: 'Mesa abierta en la red local (Hub).',
        ),
      );
      _tableCache[tableId] = state;
      unawaited(_hydrateFiscalSequencesOffline());
    } catch (e) {
      if (!stillSelected()) return;
      state = state.copyWith(
        loading: false,
        error: 'No se pudo abrir la mesa en el Hub: $e',
      );
    }
  }

  /// H4 m2: obtiene el detalle de la orden que el Hub tiene para [tableId]. El
  /// equipo Hub proyecta desde su op-log local; una caja cliente lo pide al Hub
  /// alcanzable (`GET /hub/order`). Null si no hay orden o no aplica.
  Future<Map<String, dynamic>?> _fetchHubOrder(
    String businessId,
    String tableId,
  ) async {
    final mode = ref.read(hubModeProvider);
    if (mode == TerminalMode.hubHost) {
      return _offlinePos.localHubOrder(businessId, tableId: tableId);
    }
    if (mode == TerminalMode.hubClient) {
      final url = ref.read(hubModeProvider.notifier).reachableHubUrl;
      if (url == null) return null;
      return HubClient().getOrder(
        url,
        businessId: businessId,
        tableId: tableId,
      );
    }
    return null;
  }

  /// Conserva el desglose capturado de cada item, sin volver a valorarlo con
  /// precios actuales ni descartar modificadores e impuestos al cruzar la LAN.
  @visibleForTesting
  static CurrentOrderState stateFromHubOrder(Map<String, dynamic> hub) {
    final orderId = hub['order_id']?.toString() ?? 'local-order-hub';
    final total = (hub['total'] as num?)?.toDouble() ?? 0;
    final itemsJson = (hub['items'] as List?) ?? const [];
    final items = itemsJson
        .map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          final legacySubtotal =
              ((m['qty'] ?? m['quantity'] ?? 1) as num) *
              ((m['unit_price'] ?? 0) as num);
          return OrderItemSnapshot.decode({
            ...m,
            'order_id': orderId,
            'subtotal': m['subtotal'] ?? legacySubtotal,
            'total': m['total'] ?? legacySubtotal,
            'is_takeout': m['is_takeout'] == true || m['takeout'] == true,
          });
        })
        .toList(growable: false);
    final order = Order(
      id: orderId,
      sessionId: 'hub-session',
      status: 'open',
      subtotal: (hub['subtotal'] as num?)?.toDouble() ?? total,
      discounts: (hub['discounts'] as num?)?.toDouble() ?? 0,
      serviceFee: 0,
      tax: (hub['tax'] as num?)?.toDouble() ?? 0,
      total: total,
      createdAt: DateTime.now(),
    );
    return CurrentOrderState(
      loading: false,
      order: order,
      items: items,
      checks: const [],
      takeout: false,
      origin: 'table',
      error: 'Mesa cargada desde la red local (Hub).',
    );
  }

  Future<void> openTable(String tableId, {int peopleCount = 1}) {
    final diagnostics = PerformanceDiagnostics.instance;
    if (!diagnostics.isRunning) {
      return _openTableImpl(tableId, peopleCount: peopleCount);
    }
    return diagnostics
        .measure('apertura_mesa_total', () async {
          await _openTableImpl(tableId, peopleCount: peopleCount);
          return state.order != null;
        }, accepted: (opened) => opened)
        .then<void>((_) {});
  }

  Future<void> _openTableImpl(String tableId, {int peopleCount = 1}) async {
    ++_loadGeneration;
    final businessIdAtOpen = _activeBusinessId;
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
    final myOpenToken = ++_openTableToken;
    _activeTableId = tableId;
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
      // Pintado cache-first (mismo patrón que el salón): sin cache en
      // memoria (arranque frío), pinta el snapshot en disco de la mesa
      // mientras el RPC responde. No autoritativo: _loadOrderDetail lo
      // pisa al llegar la respuesta fresca.
      unawaited(_hydrateTableFromDiskSnapshot(tableId, myOpenToken));
    }

    // Solo los roles con permisos de caja (cajero/admin/manager) necesitan
    // una sesión de caja abierta. Los meseros pueden abrir mesas directamente.
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final hasCashierAccess = sessionCtrl.hasAnyPermission([
      'caja.apertura',
      'caja.cierre',
      'caja.movimientos_ver',
    ]);
    // PERF: validación de caja e impuestos viajan en PARALELO (antes eran
    // 2 awaits en serie = 2 viajes de red antes de disparar el RPC de
    // apertura). _ensureBusinessTaxSettingsLoaded nunca lanza (fail-loud
    // vía state.taxConfigError), así que Future.wait no corta la caja.
    var cashOk = true;
    await Future.wait([
      if (hasCashierAccess) ensureCashSessionOpen().then((ok) => cashOk = ok),
      _ensureBusinessTaxSettingsLoaded(),
    ]);
    if (!cashOk ||
        myOpenToken != _openTableToken ||
        _activeBusinessId != businessIdAtOpen) {
      return;
    }

    // Modo Hub (LAN-first): NO abrimos la mesa en Supabase. La abrimos como
    // borrador local y notificamos al Hub (op `open_table`, que mapea
    // order↔table). Las mutaciones de ítem se enrutan al Hub por el uploader
    // (reusa el camino offline). Inerte si kHubModeEnabled=false.
    if (_isHubMode) {
      await _openTableViaHub(tableId, peopleCount, myOpenToken);
      return;
    }

    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;

      // Modo multimesero: si hay un activeWaiter validado en este device,
      // lo pasamos como opened_by_employee_id para trackear quién abre.
      // Si la mesa ya estaba abierta, el RPC NO sobreescribe el opened_by
      // original (es inmutable después del primer INSERT).
      final activeWaiter = _trustedActiveWaiter();

      // Offline declarado: NI intentamos el RPC. Sin esto, con "wifi sin
      // internet" (router sin WAN) la llamada colgaba sin timeout y la mesa
      // nunca abría — el spinner se quedaba pegado. El TimeoutException cae
      // al catch de abajo, que clasifica como transporte y abre el camino
      // offline (snapshot previo o borrador local).
      if (!_connectivity.isConnected) {
        throw TimeoutException(
          'Sin conexión: abriendo la mesa en modo offline.',
        );
      }

      // Single round-trip: abrir mesa + cargar bundle completo (order +
      // items + checks + customer + modifiers + tax_lines). Antes eran
      // 3-4 queries en serie (openTable + getTableLive + getOrderBundle
      // + modifiers + tax_lines) tardando ~700-900ms. El RPC consolida
      // todo en ~150ms.
      //
      // timeout(12s): cubre la ventana "conectado pero malo" (el probe de
      // conectividad va 1-2 sondeos atrás). Sin él, un RPC colgado dejaba
      // la mesa sin abrir indefinidamente; con él degrada al camino offline.
      final result = await ref
          .read(salesRepositoryProvider)
          .openTableAndLoad(
            tableId: tableId,
            userId: userId,
            peopleCount: peopleCount,
            openedByEmployeeId: activeWaiter?.employeeId,
          )
          .timeout(const Duration(seconds: 12));
      final orderId = result.orderId;
      if (myOpenToken != _openTableToken ||
          _activeBusinessId != businessIdAtOpen) {
        return;
      }

      // Aplicar el bundle ya parseado — _loadOrderDetail acepta un
      // preloaded para saltarse el fetch y solo correr el post-load
      // (fiscal sequences, normalización de state, etc).
      await _loadOrderDetail(
        orderId,
        selectionToken: myOpenToken,
        origin: 'table',
        tableId: tableId,
        caller: 'openTable',
        preloadedBundle: result.bundle,
      );

      // Fix #1: si soy el Hub host, publico la apertura al op-log para que las
      // cajas cliente vean esta mesa por la LAN (mapea order↔table).
      _mirrorHostMutationToHub({
        'type': 'open_table',
        'order_id': orderId,
        'table_id': tableId,
      });
    } catch (e) {
      if (myOpenToken != _openTableToken ||
          _activeBusinessId != businessIdAtOpen) {
        return;
      }
      final businessId = _activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        // 1. Snapshot previo (la mesa ya se abrió antes online u offline).
        final offlineState = await _offlinePos.loadSnapshot(
          businessId: businessId,
          slotId: tableId,
        );
        if (myOpenToken != _openTableToken ||
            _activeBusinessId != businessIdAtOpen) {
          return;
        }
        if (offlineState != null &&
            offlineState.order?.id != null &&
            !await _offlinePos.isOrderClosedLocally(
              businessId: businessId,
              orderId: offlineState.order!.id,
            )) {
          if (myOpenToken != _openTableToken ||
              _activeBusinessId != businessIdAtOpen) {
            return;
          }
          state = _normalizeHydratedState(
            offlineState.copyWith(
              loading: false,
              error: 'Modo offline: usando copia local de la mesa.',
              origin: 'table',
            ),
          );
          _tableCache[tableId] = state;
          unawaited(_hydrateFiscalSequencesOffline());
          return;
        }

        // 2. Sin snapshot previo pero la apertura falló por falta de red:
        //    crear draft local nuevo. `_resolveOrderIdForAction` con
        //    origin='table' usará el tableId al sincronizar para abrir la mesa
        //    real en el server. Entramos aquí si estamos offline por el flag
        //    O si el error es de transporte aunque `isConnected` siga en true
        //    (ventana "conectado pero malo"). Un error de NEGOCIO del RPC
        //    (mesa ya ocupada, permisos, validación) NO crea draft: se
        //    propaga al usuario más abajo.
        if (_shouldTreatAsOffline(e)) {
          final draft = await _offlinePos.createLocalDraft(
            businessId: businessId,
            origin: 'table',
            tableId: tableId,
            opener: _localDraftOpener(),
          );
          if (myOpenToken != _openTableToken ||
              _activeBusinessId != businessIdAtOpen) {
            return;
          }
          state = _normalizeHydratedState(
            draft.copyWith(
              loading: false,
              error:
                  'Mesa abierta offline: los items se sincronizarán al recuperar conexión.',
            ),
          );
          _tableCache[tableId] = state;
          unawaited(_hydrateFiscalSequencesOffline());
          return;
        }
      }
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Hidrata las secuencias NCF cuando la orden se cargó por el camino
  /// OFFLINE (snapshot previo o borrador local): ahí `_loadOrderDetail` no
  /// corre, `state.fiscalSequences` quedaba vacío y el modal de cobro
  /// bloqueaba con "no hay secuencias fiscales activas" aunque el negocio
  /// las tenga. `FiscalService.getSequences` cae al cache en disco sin red.
  /// Best-effort y anti-stale: si el usuario cambió de orden mientras se
  /// leía el cache, no escribe nada.
  Future<void> _hydrateFiscalSequencesOffline() async {
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    if (state.fiscalSequences.isNotEmpty) return;
    final orderIdAtStart = state.order?.id;
    try {
      final seqs = await ref
          .read(fiscalServiceProvider)
          .getSequences(businessId);
      if (seqs.isEmpty) return;
      if (state.order?.id != orderIdAtStart) return;
      state = state.copyWith(
        fiscalSequences: seqs,
        fiscalType: _resolveFiscalTypeForState(state, seqs),
        fiscalDefaultType: _cachedDefaultFiscalType,
        clearFiscalSequencesLoadError: true,
      );
    } catch (e) {
      debugPrint('[offline] no se pudieron hidratar secuencias NCF: $e');
    }
  }

  /// Pintado cache-first al abrir mesa (mismo patrón que el salón): pinta el
  /// snapshot en disco de la mesa (el que persiste `_persistCurrentState`
  /// tras cada carga) mientras `openTableAndLoad` responde, para que abrir
  /// una mesa se sienta instantáneo también en arranque frío (sin
  /// [_tableCache]). SOLO pinta si el snapshot pertenece a la sesión VIVA
  /// que muestra el salón, o a un borrador local de este device — el
  /// snapshot de una sesión anterior ya cobrada nunca se muestra. No es
  /// autoritativo: la respuesta fresca de `_loadOrderDetail` lo pisa; el
  /// [token] invalida la hidratación si el usuario abrió otra mesa mientras
  /// leíamos el disco. Best-effort: ante cualquier fallo no pinta nada.
  Future<void> _hydrateTableFromDiskSnapshot(String tableId, int token) async {
    try {
      final businessId = _activeBusinessId;
      if (businessId == null || businessId.isEmpty) return;

      // Sesión viva según el salón. Sin fila o mesa libre → la apertura
      // creará una sesión nueva (orden vacía): no hay nada que pintar.
      // 'hub' → mesa de OTRA caja: el snapshot local no es su fuente.
      final salonSessionId = _liveSalonSessionId(tableId);
      if (salonSessionId == null || salonSessionId == 'hub') return;

      final snap = await _offlinePos.loadSnapshot(
        businessId: businessId,
        slotId: tableId,
      );
      final snapOrder = snap?.order;
      if (snap == null || snapOrder == null) return;
      final isLocalDraft =
          salonSessionId == 'local-draft' ||
          snapOrder.id.startsWith('local-order-');
      if (!isLocalDraft && snapOrder.sessionId != salonSessionId) return;

      // Aplica solo si ESTA apertura sigue vigente y nada pintó todavía
      // (ni la respuesta fresca ni un error de caja). Sin awaits entre la
      // comprobación y la escritura.
      if (token != _openTableToken ||
          !state.loading ||
          state.order != null ||
          state.origin != 'table') {
        return;
      }
      state = _normalizeHydratedState(
        snap.copyWith(
          loading: true,
          error: null,
          checks: const [],
          clearSelectedCheck: true,
          origin: 'table',
        ),
      );
    } catch (_) {}
  }

  /// SessionId de la mesa según el estado ya cargado del salón (memoria,
  /// sin red). Devuelve null si el salón no tiene datos de esa mesa.
  String? _liveSalonSessionId(String tableId) {
    final byZone = ref.read(byZoneVmProvider);
    for (final rows in byZone.statusByZone.values) {
      for (final row in rows) {
        if (row.tableId == tableId) return row.sessionId;
      }
    }
    return null;
  }

  /// Decide si una mutación que acaba de fallar debe tratarse como offline
  /// (encolar la acción / crear un borrador local) en vez de propagar el error
  /// y perder el trabajo del usuario. Cubre tres casos:
  ///   1. El flag de conectividad ya está en offline.
  ///   2. La orden ya es un borrador local (`local-order-…`), así que toda
  ///      mutación posterior es inherentemente offline.
  ///   3. El error es de TRANSPORTE (red) aunque `isConnected` siga en `true`
  ///      — la ventana "conectado pero malo": el healthcheck va 1-2 sondeos
  ///      atrás y el RPC realmente falló por red. Antes, este caso NO encolaba
  ///      y el ítem/mesa se perdía (bug reportado en redes malas).
  /// Un error de NEGOCIO del RPC (RAISE, constraint, validación) no entra aquí
  /// y se muestra al usuario. Como efecto colateral del caso 3, se dispara una
  /// revalidación de conectividad para que el resto de la app reaccione ya sin
  /// esperar el próximo poll.
  bool _shouldTreatAsOffline(Object error, {String? orderId}) {
    // m2b: cortocircuito de modo Hub → siempre encolar (la op va al Hub).
    if (error is _HubModeShortCircuit) return true;
    if (!_connectivity.isConnected) return true;
    if (orderId != null && orderId.startsWith('local-order-')) return true;
    if (OfflinePosService.isTransportError(error)) {
      _recordTransportFailure();
      return true;
    }
    return false;
  }

  Future<void> openManual({bool forceRestart = false}) =>
      _startVirtualOpen('manual', forceReset: forceRestart);
  Future<void> openQuick({bool forceRestart = false}) =>
      _startVirtualOpen('quick', forceReset: forceRestart);

  /// Arranca la apertura de venta rápida/manual y la registra como la que
  /// está en curso (ver [_virtualOpenInFlight]).
  Future<void> _startVirtualOpen(String origin, {required bool forceReset}) {
    // Retail: la venta rápida vive en carritos, cada uno con su mesa virtual.
    // Un carrito cobrado o anulado (addItem/addOfferDeal lo detectan y piden
    // una venta nueva) se retira y se pasa a otro carrito o a uno nuevo. Antes
    // caía en la venta rápida general y la orden nueva quedaba guardada bajo
    // el carrito viejo.
    if (origin == 'quick' && _isRetail) {
      return _reopenRetailQuickSale(forceReset: forceReset);
    }
    final opening = _openManualOrQuick(origin, forceReset: forceReset);
    // _openManualOrQuick toma su token antes de su primer await.
    final inFlight = (origin: origin, token: _openTableToken, future: opening);
    _virtualOpenInFlight = inFlight;
    return opening.whenComplete(() {
      if (identical(_virtualOpenInFlight, inFlight)) {
        _virtualOpenInFlight = null;
      }
    });
  }

  Future<void> _reopenRetailQuickSale({required bool forceReset}) async {
    if (forceReset && _activeRetailSlotId != null) {
      await _finalizeActiveRetailCartAfterPayment();
      return;
    }
    await _ensureRetailCartsInitialized();
  }

  /// Apertura de [origin] que sigue en curso para la selección vigente, o
  /// null. Ver [_virtualOpenInFlight].
  Future<void>? _pendingVirtualOpen(String origin) {
    final opening = _virtualOpenInFlight;
    if (opening == null ||
        opening.origin != origin ||
        opening.token != _openTableToken) {
      return null;
    }
    return opening.future;
  }

  Future<void> ensureManualOrder() async {
    // Retomar también cuentas enviadas y con abonos; una cuenta cobrada o
    // anulada requiere una venta nueva al volver a esta pantalla.
    final current = state.order;
    if (state.origin == 'manual' && _isReusableOpenOrder(current)) {
      return;
    }
    final pending = _pendingVirtualOpen('manual');
    if (pending != null) return pending;
    await openManual();
  }

  /// Venta rápida/manual que se puede seguir usando al volver a su pantalla.
  ///
  /// La abierta sin internet (`local-order-…`) nace con status `draft` y lo
  /// conserva hasta sincronizar: antes solo se aceptaba `open`, así que volver
  /// a la pantalla la reemplazaba por una vacía y la venta en curso
  /// "desaparecía". La que se acaba de cobrar ([markOrderClosing]) nunca se
  /// reusa.
  bool _isReusableOpenOrder(Order? order) {
    if (order == null || order.id == _closingOrderId) return false;
    if (order.closedAt != null ||
        order.status == 'paid' ||
        order.status == 'void') {
      return false;
    }
    if (const {
      'open',
      'sent',
      'preparing',
      'ready',
      'served',
      'partially_paid',
    }.contains(order.status)) {
      return true;
    }
    return order.id.startsWith('local-order-') && order.status == 'draft';
  }

  /// Cuenta cerrada (cobrada, anulada o cancelada) según el servidor.
  static bool _isClosedOrder(Order? order) =>
      order != null &&
      (order.closedAt != null ||
          order.isPaid ||
          order.isCancelled ||
          order.status == 'void');

  bool get _isRetail => ref.read(currentBusinessModelProvider).isRetail;

  Future<void> ensureQuickOrder() async {
    // Retail: la venta rápida soporta varios carritos simultáneos. En vez de
    // reabrir una única sesión quick, inicializamos/restauramos los carritos.
    if (_isRetail) {
      await _ensureRetailCartsInitialized();
      return;
    }
    // Restaurante: reusar la venta en pantalla si sigue abierta. Si no, la
    // apertura retoma la venta de este equipo por su id (respaldo local) o,
    // si ya se cobró o anuló, abre una nueva. Ver _openManualOrQuick.
    final current = state.order;
    if (state.origin == 'quick' && _isReusableOpenOrder(current)) {
      return;
    }
    final pending = _pendingVirtualOpen('quick');
    if (pending != null) return pending;
    await openQuick();
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
      // nada (evita recargar al volver a entrar a la pantalla). Solo si lo
      // que está en pantalla es venta rápida: al volver de Venta Manual el
      // slot activo sigue siendo el del carrito, y la venta rápida mostraba
      // (y cobraba) la cuenta manual.
      if (_activeRetailSlotId == active.slotId &&
          state.order != null &&
          state.origin == 'quick') {
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
    ++_loadGeneration;
    final openToken = ++_openTableToken;
    final businessId = _activeBusinessId;
    bool stillSelected() =>
        openToken == _openTableToken && _activeBusinessId == businessId;
    // Persistir el carrito activo actual antes de cambiar de slot.
    await _persistCurrentState();
    if (!stillSelected()) return;

    await _ensureBusinessTaxSettingsLoaded();
    if (!stillSelected()) return;
    if (!await ensureCashSessionOpen()) return;
    if (!stillSelected()) return;

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
    _activeTableId = null;
    ref.read(retailCartsProvider.notifier).addCart(slotId: slotId);
    state = const CurrentOrderState(loading: true, origin: 'quick');

    try {
      await _persistRetailCartsIndex();
      if (!stillSelected()) return;
      if (_preferLocalOperations) {
        throw TimeoutException('Sin conexión: se abre el carrito local');
      }
      // RPC dedicado: una mesa virtual por carrito conserva cada venta
      // simultánea bajo su propia identidad.
      final res = await ref
          .read(salesRepositoryProvider)
          .openRetailCart(slot: slotId, businessId: businessId, peopleCount: 1);
      final orderId = res['order_id'] as String;
      if (_activeBusinessId != businessId) return;
      ref.read(retailCartsProvider.notifier).setOrderId(slotId, orderId);
      await _persistRetailCartsIndex();
      if (_activeRetailSlotId != slotId || !stillSelected()) {
        return;
      }
      await _loadOrderDetail(
        orderId,
        selectionToken: openToken,
        origin: 'quick',
        caller: 'newRetailCart',
      );
    } catch (e) {
      if (_activeRetailSlotId != slotId || !stillSelected()) {
        return;
      }
      if (_shouldTreatAsOffline(e)) {
        // Offline: draft local con este slot. Al sincronizar, el replay abre la
        // sesión quick real y remapea el local-order-… (igual que las mesas).
        final draft = await _offlinePos.createLocalDraft(
          businessId: businessId,
          origin: 'quick',
          slotId: slotId,
          opener: _localDraftOpener(),
        );
        if (_activeRetailSlotId != slotId || !stillSelected()) return;
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
    if (_activeRetailSlotId == slotId &&
        state.order != null &&
        state.origin == 'quick') {
      ref.read(retailCartsProvider.notifier).setActive(slotId);
      return;
    }

    ++_loadGeneration;
    final openToken = ++_openTableToken;
    final businessId = _activeBusinessId;
    bool stillSelected() =>
        openToken == _openTableToken && _activeBusinessId == businessId;
    await _persistCurrentState();
    if (!stillSelected()) return;

    RetailCart? cart;
    for (final c in ref.read(retailCartsProvider).carts) {
      if (c.slotId == slotId) {
        cart = c;
        break;
      }
    }
    if (cart == null) return;

    _activeRetailSlotId = slotId;
    _activeTableId = null;
    ref.read(retailCartsProvider.notifier).setActive(slotId);
    state = const CurrentOrderState(loading: true, origin: 'quick');
    final saved = businessId == null
        ? null
        : await _offlinePos.loadSnapshot(
            businessId: businessId,
            slotId: slotId,
          );
    if (_activeRetailSlotId != slotId || !stillSelected()) {
      return;
    }
    // Pintar el respaldo antes de la red: una recarga fallida no borra el
    // carrito, y el servidor parcial no pisa cambios aún en cola.
    if (saved?.order != null) {
      state = _normalizeHydratedState(
        saved!.copyWith(loading: false, origin: 'quick'),
      );
      ref
          .read(retailCartsProvider.notifier)
          .setOrderId(slotId, saved.order!.id);
      if (_preferLocalOperations ||
          await _offlinePos.hasUnsettledOrderActions(
            businessId: businessId!,
            orderId: saved.order!.id,
          )) {
        await _persistRetailCartsIndex();
        unawaited(_hydrateFiscalSequencesOffline());
        return;
      }
    }

    if (!stillSelected()) return;
    final orderId = saved?.order?.id ?? cart.orderId;
    if (orderId != null && !orderId.startsWith('local-order-')) {
      try {
        await _loadOrderDetail(
          orderId,
          selectionToken: openToken,
          origin: 'quick',
          caller: 'switchRetailCart',
        );
        await _persistRetailCartsIndex();
        return;
      } catch (_) {
        // cae al snapshot offline abajo
      }
    }

    if (businessId != null && businessId.isNotEmpty) {
      final snap = await _offlinePos.loadSnapshot(
        businessId: businessId,
        slotId: slotId,
      );
      if (snap != null) {
        if (_activeRetailSlotId != slotId || !stillSelected()) {
          return;
        }
        state = _normalizeHydratedState(
          snap.copyWith(loading: false, origin: 'quick'),
        );
        await _persistRetailCartsIndex();
        unawaited(_hydrateFiscalSequencesOffline());
        return;
      }
    }
    if (!stillSelected()) return;
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
    final cart = ref
        .read(retailCartsProvider)
        .carts
        .where((c) => c.slotId == slotId)
        .firstOrNull;
    if (cart == null) return;
    if (slotId != _activeRetailSlotId) await switchRetailCart(slotId);
    if (_activeRetailSlotId != slotId) return;
    // Cargar y anular también una pestaña inactiva. Borrar solo su snapshot
    // dejaba la venta huérfana y sus acciones seguían subiendo sin pestaña.
    if (cart.orderId != null && state.order == null) return;
    final loaded = state.order;
    if (loaded != null) {
      // Pestaña de una venta ya cobrada o anulada (la app se cerró entre el
      // cobro y _finalizeActiveRetailCartAfterPayment, o falló la recarga
      // posterior al cobro): solo se retira. fn_close_order_and_table no
      // protege 'paid' (annulOrder la usa para anular ventas cobradas), así
      // que anularla aquí pasaba la venta cobrada a 'void'.
      var closed =
          loaded.closedAt != null ||
          loaded.isPaid ||
          loaded.isCancelled ||
          loaded.status == 'void';
      var queueVoid = false;
      if (!closed && !loaded.id.startsWith('local-order-')) {
        // La pantalla puede estar vieja aunque diga «abierta»: la recarga
        // posterior al cobro falló, o tras un reinicio se repintó el respaldo
        // previo al cobro. Solo se anula en línea si el servidor confirma que
        // sigue abierta. Sin red o sin lectura, la anulación va a la cola y su
        // replay vuelve a leer el servidor y omite una venta cobrada.
        final closedOnServer = _preferLocalOperations
            ? null
            : await _retailOrderClosedOnServer(loaded.id);
        if (_activeRetailSlotId != slotId || state.order?.id != loaded.id) {
          return;
        }
        closed = closedOnServer == true;
        queueVoid = closedOnServer == null;
      }
      if (closed) {
        await markPaidOrderLocally(loaded.id);
      } else {
        // Cerrar la pestaña es una anulación automática: el servidor solo
        // anula si sigue abierta y sin cobros (otra caja pudo cobrarla
        // después de la lectura de arriba, o tener un abono parcial).
        String? notVoidable;
        try {
          await cancelCurrentOrder(
            expectedOrderId: loaded.id,
            queueVoid: queueVoid,
            voidOnlyIfUnpaid: true,
          );
        } on _OrderNotVoidable catch (e) {
          notVoidable = e.result;
        }
        if (notVoidable == 'already_closed') {
          await markPaidOrderLocally(loaded.id);
        } else if (notVoidable != null) {
          // Tiene cobros: no se descarta; la pestaña y sus productos quedan.
          if (_activeRetailSlotId == slotId && state.order?.id == loaded.id) {
            state = state.copyWith(
              error:
                  'Esta venta tiene cobros registrados. Complétala o anúlala '
                  'con motivo.',
            );
          }
          return;
        } else if (state.order != null) {
          // Un rechazo al anular conserva la pestaña y todos sus productos.
          return;
        }
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

  /// Lee en el servidor si la venta de una pestaña retail ya está cobrada,
  /// anulada o cerrada, antes de anularla. `null` si no se pudo leer (red,
  /// tiempo agotado): el caller NO anula en línea. Una orden que no aparece
  /// en el negocio cuenta como abierta (se conserva lo de siempre).
  Future<bool?> _retailOrderClosedOnServer(String orderId) async {
    try {
      final order = await ref
          .read(salesRepositoryProvider)
          .getOrder(orderId, businessId: _activeBusinessId)
          .timeout(const Duration(seconds: 5));
      if (order == null) return false;
      return order.closedAt != null ||
          order.isPaid ||
          order.isCancelled ||
          order.status == 'void';
    } catch (e) {
      debugPrint('closeRetailCart: no se pudo leer la orden $orderId: $e');
      return null;
    }
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

  static const _closedSaleRestartMessage =
      'La venta anterior ya estaba cerrada: se abrió una nueva. Vuelve a '
      'agregar el producto.';

  /// addItem/addOfferDeal encontraron la venta en pantalla ya cobrada o
  /// anulada: se abre la siguiente. El producto tocado NO se agregó, así que
  /// el aviso queda en la venta nueva; antes la apertura lo borraba y el
  /// lector cantaba «Agregado» sin haber agregado nada.
  Future<void> _restartClosedSale(String? origin) async {
    if (origin == 'quick' && _isRetail) {
      await _replaceClosedRetailCart();
    } else if (origin == 'quick') {
      await openQuick(forceRestart: true);
    } else if (origin == 'manual') {
      await openManual(forceRestart: true);
    } else {
      return;
    }
    if (state.origin == origin &&
        state.order != null &&
        !state.loading &&
        state.error == null) {
      state = state.copyWith(error: _closedSaleRestartMessage);
    }
  }

  /// Retail: la venta del carrito activo ya está cobrada o anulada (p. ej. el
  /// barrido de mesas vacías anuló el carrito vacío). Se abre un carrito NUEVO
  /// en su lugar y recién entonces se retira el cerrado. Antes se retiraba y se
  /// pasaba al último carrito abierto: la pantalla saltaba a la venta de OTRO
  /// cliente y el siguiente escaneo caía en ella. Si el carrito nuevo no se
  /// puede abrir (caja cerrada, tope de carritos), la pestaña cerrada se queda
  /// con el aviso: nunca se salta a otro carrito.
  Future<void> _replaceClosedRetailCart() async {
    final closedSlot = _activeRetailSlotId;
    final businessId = _activeBusinessId;
    if (closedSlot == null) {
      await _ensureRetailCartsInitialized();
      return;
    }
    // Sin la venta cerrada en pantalla: newRetailCart guarda lo que haya en
    // pantalla bajo el carrito activo antes de cambiar.
    state = const CurrentOrderState(origin: 'quick');
    await newRetailCart();
    final openedSlot = _activeRetailSlotId;
    if (openedSlot == null || openedSlot == closedSlot) return;
    if (businessId != null &&
        businessId.isNotEmpty &&
        _activeBusinessId == businessId) {
      await _offlinePos.saveSnapshot(
        businessId: businessId,
        slotId: closedSlot,
        origin: 'quick',
        state: const CurrentOrderState(),
        localOnly: true,
      );
    }
    if (_activeBusinessId != businessId) return;
    ref.read(retailCartsProvider.notifier).removeCart(closedSlot);
    await _persistRetailCartsIndex();
  }

  /// Abre una orden de delivery existente (ya creada por DeliveryViewModel).
  Future<void> openDeliveryOrder({
    required String tableId,
    String? deliveryType,
  }) async {
    ++_loadGeneration;
    final businessId = _activeBusinessId;
    var openToken = ++_openTableToken;
    await _ensureBusinessTaxSettingsLoaded();
    if (!await ensureCashSessionOpen()) return;
    if (openToken != _openTableToken || _activeBusinessId != businessId) {
      return;
    }
    state = state.copyWith(loading: true, error: null);
    try {
      final opening = openTable(tableId, peopleCount: 1);
      openToken = _openTableToken;
      await opening;
      if (openToken != _openTableToken ||
          _activeBusinessId != businessId ||
          _activeTableId != tableId) {
        return;
      }
      final order = state.order;
      if (order == null) return;
      // Cargar la dirección de entrega ya guardada (si la sesión la tiene).
      String? address = state.deliveryAddress;
      try {
        address = await ref
            .read(salesRepositoryProvider)
            .getSessionDeliveryAddress(order.sessionId, businessId: businessId);
      } catch (_) {
        // best-effort: la dirección es opcional, no rompe la apertura.
      }
      // La dirección puede llegar después de que el cajero abra otra cuenta.
      // Nunca aplicar ni guardar esa nueva cuenta bajo la mesa del delivery.
      if (openToken != _openTableToken ||
          _activeBusinessId != businessId ||
          _activeTableId != tableId ||
          state.order?.id != order.id) {
        return;
      }
      // El origin se fija aquí (después de openTable, que hidrató como
      // 'table'), así que aplicamos el "para llevar por defecto" de
      // delivery manualmente cuando la orden aún no tiene items.
      final deliveryTakeout = state.items.isEmpty
          ? _defaultTakeoutFor('delivery')
          : state.takeout;
      state = address == null
          ? state.copyWith(
              origin: 'delivery',
              deliveryType: deliveryType,
              takeout: deliveryTakeout,
              clearDeliveryAddress: true,
            )
          : state.copyWith(
              origin: 'delivery',
              deliveryType: deliveryType,
              takeout: deliveryTakeout,
              deliveryAddress: address,
            );
      await _persistCurrentState(tableId: tableId);
    } catch (e) {
      if (openToken != _openTableToken || _activeBusinessId != businessId) {
        return;
      }
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Guarda/edita la dirección de entrega del pedido de delivery. Campo
  /// opcional: una dirección vacía la limpia. Espejo de
  /// [assignCustomerToCurrentOrder].
  Future<void> updateDeliveryAddress(String? address) async {
    final order = state.order;
    if (order == null) return;
    final trimmed = address?.trim();
    try {
      await ref
          .read(salesRepositoryProvider)
          .updateDeliveryAddress(
            sessionId: order.sessionId,
            address: trimmed,
            businessId: _activeBusinessId,
          );
      state = (trimmed == null || trimmed.isEmpty)
          ? state.copyWith(clearDeliveryAddress: true)
          : state.copyWith(deliveryAddress: trimmed);
    } catch (e) {
      state = state.copyWith(error: 'Error al actualizar la dirección: $e');
    }
  }

  Future<void> assignManualOrderToTable({
    required String orderId,
    required String tableId,
  }) async {
    final businessId = _activeBusinessId;
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
      // La orden ya es de la mesa (mismo id, sesión de la mesa): el respaldo
      // 'manual' de este equipo deja de apuntarle. Si no, volver a Venta Manual
      // la retomaba como venta del mostrador: se le agregaban productos y se
      // cobraba (y cerraba) la cuenta de la mesa. Solo si el respaldo sigue
      // siendo de esta orden; no toca la cola ni el servidor.
      if (businessId != null && businessId.isNotEmpty) {
        await _releaseManualSlot(businessId: businessId, orderId: orderId);
      }
      await openTable(tableId);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Vacía el respaldo 'manual' si todavía guarda [orderId]. Best-effort: si
  /// falla, al retomar el servidor rechaza la orden (su sesión ya no es
  /// 'manual') y se abre una venta nueva.
  Future<void> _releaseManualSlot({
    required String businessId,
    required String orderId,
  }) async {
    try {
      // updateSnapshot solo escribe si el respaldo sigue siendo de esta orden
      // (o de su id local); el fallback solo aporta ese id.
      await _offlinePos.updateSnapshot(
        businessId: businessId,
        slotId: 'manual',
        origin: 'manual',
        fallbackState: CurrentOrderState(
          origin: 'manual',
          order: Order(
            id: orderId,
            sessionId: '',
            status: 'open',
            subtotal: 0,
            discounts: 0,
            serviceFee: 0,
            tax: 0,
            total: 0,
            createdAt: DateTime.now(),
          ),
        ),
        update: (_) => const CurrentOrderState(origin: 'manual'),
      );
    } catch (e) {
      debugPrint('[SalesVM] no se soltó el respaldo manual de $orderId: $e');
    }
  }

  /// Asigna el cliente a la orden DESDE QUE SE ELIGE: el estado cambia al
  /// instante (chip, comanda y factura ya lo usan) y el servidor se actualiza
  /// detrás. Sin red o en orden local queda pendiente y se guarda al
  /// reconectar; el cobro offline ya viaja con `customer_id`, así que el
  /// comprobante sale a su nombre igual. Si la venta rápida/manual todavía no
  /// tiene orden ([nextOrderOrigin]), se aplica a la venta nueva cuando abra.
  ///
  /// Devuelve null si quedó asignado, o el mensaje de error para mostrar.
  Future<String?> assignCustomerToCurrentOrder({
    required String customerId,
    required String customerName,
    String? customerLegalName,
    String? customerTaxId,
    String? nextOrderOrigin,
  }) async {
    final customer = _OrderCustomer(
      id: customerId,
      name: customerName,
      legalName: customerLegalName,
      taxId: customerTaxId,
    );
    final order = state.order;
    // Selección de esta asignación: tras la espera del servidor solo se
    // recarga si la pantalla sigue en esta misma cuenta (ver _loadOrderDetail).
    final selectionToken = _openTableToken;
    final selectedOrigin = state.origin;
    final orderClosing =
        order != null &&
        (order.id == _closingOrderId ||
            order.status == 'paid' ||
            order.status == 'void' ||
            order.closedAt != null);
    if (order == null || orderClosing) {
      if (nextOrderOrigin == 'quick' || nextOrderOrigin == 'manual') {
        _nextOrderCustomer = (
          origin: nextOrderOrigin!,
          businessId: _activeBusinessId,
          customer: customer,
          at: DateTime.now(),
        );
        return null;
      }
      return 'No hay una orden abierta para asignarle el cliente.';
    }

    final previous = (
      id: state.customerId,
      name: state.customerName,
      legalName: state.customerLegalName,
      taxId: state.customerTaxId,
    );
    final pending = _PendingOrderCustomer(customer);
    _pendingCustomers.removeWhere(
      (_, p) => DateTime.now().difference(p.at) > const Duration(hours: 12),
    );
    _pendingCustomers[order.id] = pending;
    _applyCustomerToState(customer);
    // Retail: reflejar el cliente en la etiqueta de la pestaña del carrito.
    if (_isRetail && _activeRetailSlotId != null) {
      ref
          .read(retailCartsProvider.notifier)
          .setCustomerName(_activeRetailSlotId!, customerName);
      await _persistRetailCartsIndex();
    }

    if (_preferLocalOperations || order.id.startsWith('local-order-')) {
      await _persistCurrentState(localOnly: true);
      return null;
    }

    pending.pushing = true;
    try {
      await ref
          .read(salesRepositoryProvider)
          .assignCustomerToSession(
            sessionId: order.sessionId,
            customerId: customerId,
            customerName: customerName,
            businessId: _activeBusinessId,
          )
          .timeout(const Duration(seconds: 10));
      pending.savedOnServer = true;
      pending.pushing = false;
    } catch (e) {
      pending.pushing = false;
      if (e is TimeoutException || OfflinePosService.isTransportError(e)) {
        // Queda pendiente: se guarda en el servidor en la próxima recarga
        // con red (ver _pushPendingCustomer).
        _recordTransportFailure();
        await _persistCurrentState(localOnly: true);
        return null;
      }
      // El servidor rechazó la asignación: deshacer lo aplicado.
      if (identical(_pendingCustomers[order.id], pending)) {
        _pendingCustomers.remove(order.id);
      }
      if (state.order?.id == order.id && state.customerId == customer.id) {
        state = state
            .copyWith(clearCustomer: true)
            .copyWith(
              customerId: previous.id,
              customerName: previous.name,
              customerLegalName: previous.legalName,
              customerTaxId: previous.taxId,
            );
        if (_isRetail && _activeRetailSlotId != null) {
          ref
              .read(retailCartsProvider.notifier)
              .setCustomerName(_activeRetailSlotId!, previous.name);
          await _persistRetailCartsIndex();
        }
      }
      return 'No se pudo asignar el cliente: ${FriendlyError.from(e)}';
    }
    // Sin `await` desde que se marcó `savedOnServer`: la recarga arranca ya y
    // su generación nueva descarta cualquier recarga vieja en vuelo. Si el
    // cajero ya pasó a otra cuenta (p. ej. Venta Rápida), no se recarga: el
    // cliente ya quedó en el servidor y la próxima carga de esta cuenta lo
    // trae. Antes esta recarga escribía la mesa en la pantalla nueva.
    await _loadOrderDetail(
      order.id,
      selectionToken: selectionToken,
      reloadOf: order.id,
      origin: selectedOrigin,
      caller: 'assignCustomer',
    );
    return null;
  }

  /// Pone el cliente en el estado. Limpia primero el anterior para que su
  /// RNC/razón social no se queden pegados al nuevo cliente si este no trae.
  void _applyCustomerToState(_OrderCustomer c) {
    state = state
        .copyWith(clearCustomer: true)
        .copyWith(
          customerId: c.id,
          customerName: c.name,
          customerLegalName: c.legalName,
          customerTaxId: c.taxId,
        );
  }

  /// Guarda en el servidor el cliente pendiente de [orderId] (elegido sin red
  /// o en orden local). Best-effort: si vuelve a fallar por red sigue
  /// pendiente; si el servidor lo rechaza se suelta para no reintentar en
  /// cada recarga.
  Future<void> _pushPendingCustomer(String orderId, {String? sessionId}) async {
    final pending = _pendingCustomers[orderId];
    if (pending == null || pending.savedOnServer || pending.pushing) return;
    if (orderId.startsWith('local-order-') || !_connectivity.isConnected) {
      return;
    }
    // Antes del await: evita dos envíos si llegan dos recargas juntas.
    pending.pushing = true;
    try {
      final repo = ref.read(salesRepositoryProvider);
      final resolvedSessionId =
          sessionId ??
          (await repo.getOrder(
            orderId,
            businessId: _activeBusinessId,
          ))?.sessionId;
      if (resolvedSessionId == null || resolvedSessionId.isEmpty) return;
      await repo
          .assignCustomerToSession(
            sessionId: resolvedSessionId,
            customerId: pending.customer.id,
            customerName: pending.customer.name,
            businessId: _activeBusinessId,
          )
          .timeout(const Duration(seconds: 10));
      pending.savedOnServer = true;
    } catch (e) {
      if (e is TimeoutException || OfflinePosService.isTransportError(e)) {
        return;
      }
      debugPrint('[SalesVM] cliente pendiente rechazado ($orderId): $e');
      if (identical(_pendingCustomers[orderId], pending)) {
        _pendingCustomers.remove(orderId);
      }
    } finally {
      pending.pushing = false;
    }
  }

  /// Tras sincronizar la cola offline: los clientes elegidos sobre órdenes
  /// locales pasan al id real de su orden y se guardan en el servidor.
  Future<void> _remapAndPushPendingCustomers(String businessId) async {
    for (final localId in _pendingCustomers.keys.toList(growable: false)) {
      if (!localId.startsWith('local-order-')) continue;
      final remoteId = await _offlinePos.mappedRemoteOrderId(
        businessId: businessId,
        localOrderId: localId,
      );
      if (remoteId == null) continue;
      final pending = _pendingCustomers.remove(localId);
      if (pending == null) continue;
      _pendingCustomers.putIfAbsent(remoteId, () => pending);
    }
    for (final orderId in _pendingCustomers.keys.toList(growable: false)) {
      await _pushPendingCustomer(orderId);
    }
  }

  /// La venta rápida/manual [orderId] ya se cobró y se está abriendo la
  /// siguiente: un cliente elegido en esta ventana es para la venta nueva.
  void markOrderClosing(String orderId) {
    _closingOrderId = orderId;
    // Cobrada en línea: el servidor ya la cerró, pero el respaldo
    // 'quick'/'manual' la guarda abierta. Al volver a la pantalla sin red se
    // retoma ese respaldo sin confirmarlo con el servidor, y la venta cobrada
    // aparecía como venta en curso (se podía cobrar otra vez). Las mesas ya
    // reciben esta marca al cobrarse completas (markPaidOrderLocally).
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;
    unawaited(
      _offlinePos
          .markOrderClosedLocally(businessId: businessId, orderId: orderId)
          .catchError(
            (Object e) => debugPrint('[SalesVM] marca de cierre local: $e'),
          ),
    );
  }

  // Negocio|orden de la última marca de venta cobrada escrita: el aviso del
  // modal de cobro y el respaldo de handleConfirmed no la repiten.
  String? _paidMarkWrittenFor;

  /// Venta rápida/manual cobrada EN LÍNEA: marca local de cerrada en cuanto
  /// se confirma el cobro, ANTES de imprimir. [markOrderClosing] la escribía
  /// recién al cerrar el diálogo (después de la impresión, que puede colgarse):
  /// si la app moría en ese lapso y reiniciaba sin red, el respaldo retomaba
  /// la venta cobrada como venta en curso y se podía cobrar otra vez. Solo la
  /// marca (que también suelta su respaldo): no toca la pantalla ni la venta
  /// en cierre. Best-effort: un fallo de disco no frena la impresión.
  ///
  /// Solo cobro de la cuenta completa ([checkId] null) de venta rápida/manual
  /// de restaurante con algún pago confirmado por el servidor ('completed').
  /// El cobro sin red ya recibe la marca con markPaidOrderLocally, y retail
  /// cambia de carrito con refreshOrder(clearIfPaid).
  ///
  /// Todo el contexto ([businessId], [isRetail], orden, origen, sub-cuenta) es
  /// el capturado al abrir el cobro, nunca el activo: si el cajero cambia de
  /// sucursal mientras responde el servidor, la marca va al negocio de la
  /// venta cobrada (antes iba al nuevo y la cobrada quedaba retomable).
  Future<void> markVirtualSalePaidLocally({
    required String businessId,
    required bool isRetail,
    required String orderId,
    required String origin,
    required String? checkId,
    required List<Payment> payments,
  }) async {
    if (checkId != null ||
        (origin != 'quick' && origin != 'manual') ||
        isRetail ||
        businessId.isEmpty ||
        !payments.any((payment) => payment.status == 'completed')) {
      return;
    }
    // El VM de cobro ya la escribió antes de esperar al e-CF: la de
    // handleConfirmed no repite la escritura.
    if (_paidMarkWrittenFor == '$businessId|$orderId') return;
    try {
      await _offlinePos.markOrderClosedLocally(
        businessId: businessId,
        orderId: orderId,
      );
      _paidMarkWrittenFor = '$businessId|$orderId';
    } catch (e) {
      debugPrint('[SalesVM] marca de cierre local tras el cobro: $e');
    }
  }

  /// Aplica a la venta recién abierta el cliente que se eligió mientras
  /// todavía no había orden. Solo si es del mismo modo y reciente.
  void _applyNextOrderCustomer(String origin) {
    final next = _nextOrderCustomer;
    // Si la venta no llegó a abrir, el cliente espera al siguiente intento.
    if (state.order == null) return;
    _nextOrderCustomer = null;
    _closingOrderId = null;
    if (next == null || next.origin != origin) return;
    // Elegido en otra sucursal (el dueño cambió de negocio en medio): no es
    // cliente de esta venta.
    if (next.businessId != _activeBusinessId) return;
    if (DateTime.now().difference(next.at) > const Duration(minutes: 2)) {
      return;
    }
    unawaited(
      assignCustomerToCurrentOrder(
        customerId: next.customer.id,
        customerName: next.customer.name,
        customerLegalName: next.customer.legalName,
        customerTaxId: next.customer.taxId,
      ),
    );
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
    String? customerTaxId,
  }) async {
    final order = state.order;
    if (order == null) return;
    // Selección de esta asignación: tras la espera del servidor, nada se
    // escribe si la pantalla ya pasó a otra cuenta (ver _loadOrderDetail).
    final selectionToken = _openTableToken;
    final selectedOrigin = state.origin;
    bool stillSelected() =>
        selectionToken == _openTableToken && state.order?.id == order.id;

    // Recordar la asignación para reaplicarla tras los reload (ver
    // _checkCustomerOverride): el reload del bundle puede no traer customer_rnc.
    _checkCustomerOverride[checkId] = (
      id: customerId,
      name: customerName,
      rnc: customerTaxId,
    );

    try {
      await ref
          .read(salesRepositoryProvider)
          .assignCustomerToCheck(
            checkId: checkId,
            customerId: customerId,
            customerName: customerName,
            customerRnc: customerTaxId,
          );
      if (!stillSelected()) return;
      // Reflejar de inmediato en el check local para que el chip del header
      // y los tabs muestren el nombre/RNC sin esperar al reload del bundle.
      final updatedChecks = state.checks
          .map(
            (c) => c.id == checkId
                ? c.copyWith(
                    customerId: customerId,
                    customerName: customerName,
                    customerRnc: customerTaxId,
                  )
                : c,
          )
          .toList(growable: false);
      state = state.copyWith(checks: updatedChecks);
      await _loadOrderDetail(
        order.id,
        selectionToken: selectionToken,
        reloadOf: order.id,
        origin: selectedOrigin,
        caller: 'assignCustomerToCheck',
      );
    } catch (e) {
      if (!stillSelected()) return;
      state = state.copyWith(
        error: 'Error al asignar cliente a la subcuenta: $e',
      );
    }
  }

  void updateFiscalType(String type) {
    _hasManualFiscalTypeSelection = true;
    state = state.copyWith(fiscalType: _normalizeFiscalTypeValue(type));
  }

  /// Asigna (o limpia, con [type] vacío) el tipo de comprobante de una
  /// sub-cuenta puntual en vez de la orden completa. Se usa cuando el cajero
  /// tiene una sub-cuenta seleccionada en el header: en una cuenta dividida
  /// cada check puede emitir un comprobante distinto (p. ej. dividida en 3
  /// con 2 Crédito Fiscal + 1 Consumidor Final). El override se guarda en
  /// `order_checks.requested_ncf_type` y lo consume el cobro por sub-cuenta;
  /// el bundle lo re-hidrata en recargas. La orden general conserva su tipo.
  Future<void> setFiscalTypeForCheck(String checkId, String type) async {
    final normalized = _normalizeFiscalTypeValue(type);
    final newValue = normalized.isEmpty ? null : normalized;

    // Recordar la elección para reaplicarla tras los reload (ver
    // _checkNcfOverride): así no revierte a B02 aunque el bundle no devuelva
    // requested_ncf_type.
    _checkNcfOverride[checkId] = newValue;

    // Reflejar de inmediato en el check local para que el dropdown del header
    // muestre el cambio sin esperar al reload del bundle.
    final updatedChecks = state.checks
        .map(
          (c) => c.id == checkId
              ? (newValue == null
                    ? c.copyWith(clearNcfType: true)
                    : c.copyWith(requestedNcfType: newValue))
              : c,
        )
        .toList(growable: false);
    state = state.copyWith(checks: updatedChecks);

    try {
      await ref
          .read(salesRepositoryProvider)
          .setCheckNcfType(checkId: checkId, ncfType: newValue);
    } catch (e) {
      state = state.copyWith(
        error: 'Error al asignar comprobante a la subcuenta: $e',
      );
    }
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

  /// Pantalla de venta rápida/manual mientras abre su cuenta: ninguna orden en
  /// memoria (mismo patrón que openTable). Solo se conserva lo que es del
  /// negocio y de la conexión (badge de pendientes, secuencias fiscales, error
  /// de impuestos que bloquea el cobro). También descarta las recargas de la
  /// cuenta anterior que ya estaban agendadas: si no, al dispararse la volvían
  /// a cargar en esta pantalla, con este origen y bajo este respaldo.
  void _showVirtualSaleOpening(String origin) {
    // Al pasar a quick/manual ya no hay mesa activa; sin esto una mutación
    // posterior con origin 'table' residual persistiría al slot equivocado.
    _activeTableId = null;
    _hasManualFiscalTypeSelection = false;
    _refreshOrderDebounceTimer?.cancel();
    _refreshOrderDebounceTimer = null;
    _queuedRefreshOrderId = null;
    _queuedClearIfPaid = false;
    // El canal de la cuenta anterior no sirve en esta pantalla: sus eventos
    // recargaban la venta que se estaba retomando antes de confirmarla. La
    // venta que abra o retome se suscribe al cargar.
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = null;
    _subscribedOrderId = null;
    state = CurrentOrderState(
      loading: true,
      origin: origin,
      isOfflineMode: state.isOfflineMode,
      syncInFlight: state.syncInFlight,
      pendingOfflineActions: state.pendingOfflineActions,
      lastSyncAt: state.lastSyncAt,
      fiscalSequences: state.fiscalSequences,
      taxConfigError: state.taxConfigError,
    );
  }

  /// ¿Sigue [orderId] siendo una venta [origin] abierta en el servidor?
  /// confirmed: su sesión (`table_sessions.origin`) es de este origen y no
  /// está cerrada. rejected: el servidor dice que no (otra pantalla o mesa real
  /// tras «Asignar a mesa», sesión cerrada, inexistente o de otro negocio).
  /// unreachable: sin red. unknown: el servidor respondió con un error; no se
  /// toma como «no» porque, si esta lectura fallara siempre, cada visita
  /// abriría una venta nueva y dejaría viva la anterior.
  /// revivable: sesión de este origen pero cerrada, y este equipo todavía
  /// tiene altas de la venta por subir. Así la deja el barrendero de mesas
  /// vacías (fn_release_empty_tables) cuando la venta se llenó sin red, y al
  /// subir el alta el trigger de order_items (20260819_0004) reabre la orden
  /// y su sesión. Abrir otra venta dejaba esos productos en una orden sin
  /// pantalla (nunca cobrada) o muertos en la cola. Decide la carga: si el
  /// servidor la cobró, se adopta el cierre y se abre una nueva.
  Future<_VirtualSaleSession> _confirmVirtualSaleSession(
    String orderId, {
    required String origin,
    required String businessId,
  }) async {
    try {
      final session = await ref
          .read(salesRepositoryProvider)
          .getOrderSessionOrigin(orderId, businessId: businessId)
          .timeout(const Duration(seconds: 10));
      if (session == null || session.origin != origin) {
        return _VirtualSaleSession.rejected;
      }
      if (session.closedAt == null) return _VirtualSaleSession.confirmed;
      try {
        final queued = await _offlinePos.orderQueueStatus(
          businessId: businessId,
          orderId: orderId,
        );
        if (queued.revivingAdds) return _VirtualSaleSession.revivable;
      } catch (e) {
        debugPrint('[SalesVM] no se leyó la cola de $orderId: $e');
      }
      return _VirtualSaleSession.rejected;
    } catch (e) {
      if (e is TimeoutException || OfflinePosService.isTransportError(e)) {
        _recordTransportFailure();
        return _VirtualSaleSession.unreachable;
      }
      debugPrint('[SalesVM] no se pudo confirmar la sesión de $orderId: $e');
      return _VirtualSaleSession.unknown;
    }
  }

  Future<void> _openManualOrQuick(
    String origin, {
    bool forceReset = false,
  }) async {
    // Reinicio tras cobrar (o tras detectar la venta cerrada): si en esa
    // ventana ya se abrió una venta NUEVA de esta pantalla (p. ej. el lector
    // escaneó el primer producto del siguiente cliente mientras se cerraba la
    // cobrada), se respeta. Antes se soltaba y se abría otra: el producto
    // escaneado desaparecía de la venta del cliente y su orden quedaba viva
    // sin pantalla. La cobrada nunca pasa este filtro: es la venta en cierre
    // (_closingOrderId) o ya está paid/void. Antes de tomar token: tomarlo
    // cortaría el alta en curso sobre esa venta nueva.
    if (forceReset &&
        state.origin == origin &&
        !state.loading &&
        _isReusableOpenOrder(state.order)) {
      return;
    }
    ++_loadGeneration;
    final openToken = ++_openTableToken;
    final businessId = _activeBusinessId;
    bool stillSelected() =>
        openToken == _openTableToken && _activeBusinessId == businessId;
    // Soltar la cuenta saliente ANTES de cualquier await. Antes la anterior
    // (p. ej. la mesa A) seguía en pantalla durante el respaldo, la caja y el
    // RPC, y se quedaba ahí si alguno fallaba: un producto o el cobro tocados
    // en Venta Manual caían en la mesa A. Su respaldo se guarda del estado
    // capturado aquí mismo (_persistCurrentState lo toma antes de su primer
    // await); no se borra nada del servidor, la cola ni el respaldo. Con
    // forceReset la saliente ya se cobró o se descartó: no se vuelve a guardar.
    final savingPrevious = forceReset ? null : _persistCurrentState();
    _showVirtualSaleOpening(origin);
    if (savingPrevious != null) {
      try {
        await savingPrevious;
      } catch (e) {
        debugPrint(
          '[SalesVM] no se guardó el respaldo de la cuenta anterior: $e',
        );
      }
      if (!stillSelected()) return;
    }

    // Retomar la venta de ESTE equipo por su id: el respaldo 'quick'/'manual'
    // es por instalación y negocio. El servidor ya no retoma (cada apertura es
    // una venta nueva), así que dos cajas nunca comparten la misma cuenta.
    if (!forceReset && businessId != null && businessId.isNotEmpty) {
      final snapshot = await _offlinePos.loadSnapshot(
        businessId: businessId,
        slotId: origin,
      );
      if (!stillSelected()) return;
      final saved = snapshot?.order;
      if (snapshot != null && saved != null && _isReusableOpenOrder(saved)) {
        final savedId = saved.id;
        // Una venta del servidor no se toca hasta confirmarla (igual que el
        // cache de openTable): se pinta con loading y los toques y el lector
        // esperan. Antes se podía agregar durante esa lectura y la respuesta
        // vieja del servidor pisaba lo recién agregado. El borrador local sí
        // se usa de una vez: no hay servidor que confirmar.
        final confirm =
            !_preferLocalOperations && !savedId.startsWith('local-order-');
        state = _normalizeHydratedState(
          snapshot.copyWith(
            loading: confirm,
            origin: origin,
            isOfflineMode: state.isOfflineMode,
            syncInFlight: state.syncInFlight,
            pendingOfflineActions: state.pendingOfflineActions,
            lastSyncAt: state.lastSyncAt,
            taxConfigError: state.taxConfigError,
          ),
        );
        if (!confirm) {
          unawaited(_hydrateFiscalSequencesOffline());
          _applyNextOrderCustomer(origin);
          return;
        }
        // El SERVIDOR confirma que sigue siendo una venta de esta pantalla:
        // su sesión es de este origen y sigue abierta. El estado de la orden
        // no basta: una Venta Manual pasada a una mesa con «Asignar a mesa»
        // sigue abierta con el mismo id (en la sesión de la mesa), y
        // Order.origin siempre llega como 'table'. Única excepción: sesión de
        // este origen cerrada con altas de esta venta aún en la cola
        // (revivable); ahí decide la carga.
        final session = await _confirmVirtualSaleSession(
          savedId,
          origin: origin,
          businessId: businessId,
        );
        if (!stillSelected()) return;
        if (session == _VirtualSaleSession.unreachable) {
          // Sin red: igual que retomar sin conexión (arriba). Una segunda
          // lectura al mismo servidor caído solo sumaría espera.
          state = state.copyWith(loading: false, error: state.error);
          unawaited(_hydrateFiscalSequencesOffline());
          _applyNextOrderCustomer(origin);
          return;
        }
        if (session == _VirtualSaleSession.rejected) {
          debugPrint(
            '[SalesVM] el respaldo $origin apunta a $savedId, que ya no es una '
            'venta $origin abierta en el servidor: se abre una venta nueva',
          );
          _showVirtualSaleOpening(origin);
        } else {
          // Una carga más nueva de esta misma venta (p. ej. la recarga al
          // reconectar) puede reemplazar la confirmación: se repite para
          // decidir con la respuesta del servidor y no con el respaldo
          // pintado. Antes se soltaba el bloqueo igual y se aceptaban toques
          // sobre una venta sin confirmar (o ya cobrada en el servidor).
          for (var attempt = 0; attempt < 3; attempt++) {
            final confirming = _loadOrderDetail(
              savedId,
              selectionToken: openToken,
              origin: origin,
              caller: 'resumeManualOrQuick:$origin',
            );
            // _loadOrderDetail toma su generación antes de su primer await.
            final confirmGeneration = _loadGeneration;
            try {
              await confirming;
            } catch (e) {
              debugPrint(
                '[SalesVM] no se confirmó la venta retomada $savedId: $e',
              );
            }
            if (!stillSelected()) return;
            if (_loadGeneration == confirmGeneration ||
                state.order?.id != savedId) {
              break;
            }
          }
          final shown = state.order;
          if (shown != null && shown.id != savedId) return;
          if (_isReusableOpenOrder(shown)) {
            // Sin red o con cambios en cola la carga conserva la pantalla.
            if (state.loading) {
              state = state.copyWith(loading: false, error: state.error);
            }
            _applyNextOrderCustomer(origin);
            return;
          }
          // Cobrada o anulada en el servidor (otra caja, o el cobro ya
          // subió), o ya no accesible: se abre una venta nueva en vez de
          // mostrarla abierta.
          _showVirtualSaleOpening(origin);
        }
      }
    }
    await _ensureBusinessTaxSettingsLoaded();
    if (!stillSelected()) return;
    // Caja cerrada: queda el aviso sin ninguna cuenta en pantalla.
    if (!await ensureCashSessionOpen()) return;
    if (!stillSelected()) return;

    if (!state.loading) state = state.copyWith(loading: true);
    String? openedOrderId;
    try {
      // `_preferLocalOperations` y no solo `!isConnected`: si otra lectura
      // acaba de fallar por red, la venta local sale de una vez en vez de
      // esperar 10 s al RPC mientras el detector confirma la caída.
      if (_preferLocalOperations) {
        throw TimeoutException('Sin conexión: se abre la venta local');
      }
      final res = await ref
          .read(salesRepositoryProvider)
          .openManualOrQuick(
            origin: origin,
            customerName: null,
            peopleCount: 1,
            businessId: businessId,
          )
          .timeout(const Duration(seconds: 10));
      if (!stillSelected()) return;
      final orderId = res['order_id'] as String;
      openedOrderId = orderId;
      await _loadOrderDetail(
        orderId,
        selectionToken: openToken,
        origin: origin,
        caller: 'openManualOrQuick:$origin',
      );
      if (!stillSelected()) return;
      _applyNextOrderCustomer(origin);
    } catch (e) {
      if (!stillSelected()) return;
      // Sin red: venta NUEVA local (no se recupera ninguna vieja, así que no
      // choca con PRD 2.5). Al sincronizar, el replay abre la sesión real y
      // remapea el local-order-… — el mismo camino que ya usan las mesas y
      // los carritos de retail. Antes aquí se mostraba "No se pudo abrir
      // Venta Rápida" y la caja rápida quedaba muerta toda la caída después
      // del primer cobro offline. Solo si el servidor no alcanzó a devolver
      // una venta: con ella, un borrador local partía la venta en dos.
      if (openedOrderId == null &&
          businessId != null &&
          businessId.isNotEmpty &&
          _shouldTreatAsOffline(e)) {
        final draft = await _offlinePos.createLocalDraft(
          businessId: businessId,
          origin: origin,
          opener: _localDraftOpener(),
        );
        if (!stillSelected()) return;
        state = _normalizeHydratedState(draft.copyWith(loading: false));
        unawaited(_hydrateFiscalSequencesOffline());
        _applyNextOrderCustomer(origin);
        return;
      }
      // Un fallo al abrir no autoriza borrar una venta guardada previamente,
      // ni dejar en pantalla una cuenta que no sea la de esta apertura.
      if (state.order != null && state.order!.id != openedOrderId) {
        _showVirtualSaleOpening(origin);
      }
      state = state.copyWith(
        loading: false,
        error:
            'No se pudo abrir Venta ${origin == 'quick' ? 'Rápida' : 'Manual'}: $e',
      );
    }
  }

  _OrderMutationContext _captureOrderMutation(String orderId) {
    final origin = state.origin;
    final waiter = _trustedActiveWaiter();
    final businessId = _activeBusinessId;
    final tableId = origin == 'table' || origin == 'delivery'
        ? _activeTableId
        : null;
    return _OrderMutationContext(
      orderId: orderId,
      businessId: businessId,
      origin: origin,
      tableId: tableId,
      slotId: origin == null ? null : _resolvePersistSlotId(origin, tableId),
      selectionToken: _openTableToken,
      // El autor de un ítem es el PIN; el empleado del cajero solo registra
      // quién hizo un retiro (nunca va como autor de lo que agrega).
      pinEmployeeId: waiter?.employeeId,
      pinEmployeeName: waiter?.displayName,
      actorEmployeeId:
          waiter?.employeeId ?? _cachedAuthEmployeeIdFor(businessId),
      userId: ref.read(sessionProvider).userId,
      snapshot: state,
    );
  }

  bool _isMutationOrderActive(_OrderMutationContext context) =>
      context.selectionToken == _openTableToken &&
      context.businessId == _activeBusinessId &&
      state.order?.id == context.orderId;

  CurrentOrderState _mutationItemsState(
    CurrentOrderState source,
    List<OrderItem> items,
  ) {
    final summary = summarizeOrderPricing(
      source.order,
      items,
      forcedOrigin: source.origin,
    );
    return source.copyWith(
      items: items,
      order: source.order?.copyWith(
        subtotal: summary.subtotal,
        discounts: summary.discounts,
        tax: summary.tax,
        serviceFee: summary.serviceFee,
        total: summary.total,
      ),
    );
  }

  void _applyOrderMutation(
    _OrderMutationContext context,
    CurrentOrderState Function(CurrentOrderState) update, {
    String? error,
  }) {
    final active = _isMutationOrderActive(context);
    context.snapshot = update(active ? state : context.snapshot).copyWith(
      error: error,
    );
    if (active) {
      state = context.snapshot;
    }
  }

  Future<void> _persistOrderMutation(
    _OrderMutationContext context,
    CurrentOrderState Function(CurrentOrderState) update,
  ) async {
    final businessId = context.businessId;
    final origin = context.origin;
    final slotId = context.slotId;
    if (businessId == null || origin == null || slotId == null) return;
    final active = _isMutationOrderActive(context);
    final snapshot = active ? state : context.snapshot;
    context.snapshot = snapshot;
    if (active) {
      await _offlinePos.saveSnapshot(
        businessId: businessId,
        slotId: slotId,
        origin: origin,
        tableId: context.tableId,
        state: snapshot,
        localOnly: true,
      );
    } else {
      final saved = await _offlinePos.updateSnapshot(
        businessId: businessId,
        slotId: slotId,
        origin: origin,
        tableId: context.tableId,
        fallbackState: snapshot,
        update: update,
      );
      if (saved == null) return;
      context.snapshot = saved;
    }
    if ((origin == 'table' || origin == 'delivery') &&
        context.tableId != null &&
        context.businessId == _activeBusinessId) {
      _tableCache[context.tableId!] = context.snapshot;
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
    if (!operatorHasPermissionRef(ref, 'ventas.orden.agregar_item')) {
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
    final mutation = _captureOrderMutation(orderId);

    // Anti doble-click: descarta el segundo disparo del mismo producto (con los
    // mismos modifiers) dentro de _addItemDebounceMs. Ver nota del campo.
    final addKey =
        '$menuItemId|$takeout|'
        '${selectedModifiers.map((m) => '${m.name}x${m.qty}').join(',')}';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastAddItemKey == addKey &&
        nowMs - _lastAddItemMs < _addItemDebounceMs) {
      return;
    }
    _lastAddItemKey = addKey;
    _lastAddItemMs = nowMs;

    // Identidad de ESTE toque (20260929_0001). Viaja en el intento online, en
    // el proxy del Hub y en la acción encolada: si el servidor ya guardó el
    // ítem pero se perdió la respuesta, el reintento devuelve el mismo ítem en
    // vez de crear otro. Un toque nuevo = un id nuevo = una unidad más.
    final clientOpId = const Uuid().v4();

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
      await _restartClosedSale(origin);
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
    final previousOrder = mutation.snapshot.order;

    // Escáner y algunos accesos rápidos solo pasan el ID. Para construir el
    // ítem sin servidor necesitamos el precio y nombre ya preparados en disco.
    if (productName == null || productPrice == null) {
      final businessId = mutation.businessId;
      if (businessId != null) {
        final catalog = await OfflineCatalogService().loadSnapshot(businessId);
        for (final row in catalog?.products ?? <Map<String, dynamic>>[]) {
          if (row['id']?.toString() != menuItemId) continue;
          final product = MenuProduct.fromMap(row);
          productName ??= product.name;
          productPrice ??= product.price;
          productTaxMode = product.taxMode;
          productTaxRate ??= product.calculateTaxRate(mutation.origin ?? 'table');
          productFullTaxRate ??= product.calculateFullTaxRate();
          break;
        }
      }
    }

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
    var itemSavedOnServer = false;
    String? savedItemId;
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
      final originForTaxes = parseSaleOrigin(mutation.origin);
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
      // persistir se hace aparte vía _resolveItemEmployeeId(). Solo PIN: este
      // item viaja como item_snapshot en la cola y el replay lo usa de autor;
      // el id del cajero ahí le acreditaba la mesa de un mesero.
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
        createdByEmployeeId: mutation.pinEmployeeId,
        createdByEmployeeName: mutation.pinEmployeeName,
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

      // Guard del alta: protege este tmp de recargas stale en vuelo hasta que
      // el server confirme su contraparte real (ver _loadOrderDetail).
      if (_isMutationOrderActive(mutation)) {
        _inFlightAddTmpIds.add(optimisticItem.id);
      }
      final addedItem = optimisticItem;
      _applyOrderMutation(
        mutation,
        (source) => _mutationItemsState(source, [...source.items, addedItem]),
      );
    }

    try {
      if (optimisticItem != null) {
        final addedItem = optimisticItem;
        await _persistOrderMutation(mutation, (source) {
          if (source.items.any((item) => item.id == addedItem.id)) return source;
          return _mutationItemsState(source, [...source.items, addedItem]);
        });
      }
      // La orden local se guarda antes de intentar un proxy o RPC remoto.
      if (_preferLocalOperations || orderId.startsWith('local-order-')) {
        throw OfflineShortCircuitException('add_item');
      }
      if (_isHubMode) {
        // Orden LOCAL (el Hub estaba offline al abrir) → op-log; el proxy no
        // aplica porque la orden aún no existe en el server.
        if (orderId.startsWith('local-order-')) {
          throw const _HubModeShortCircuit();
        }
        // Orden REAL → agregar el ítem por el Hub (real-time contra Supabase).
        final hubUrl = ref.read(hubModeProvider.notifier).reachableHubUrl;
        final realId = hubUrl == null
            ? null
            : await ref
                  .read(salesRepositoryProvider)
                  .addItemFromMenuViaHub(
                    hubBaseUrl: hubUrl,
                    orderId: orderId,
                    menuItemId: menuItemId,
                    quantity: qty,
                    checkPosition: effectiveCheckPos,
                    isTakeout: takeout,
                    notes: notes,
                    modifiers: selectedModifiers
                        .map((m) => m.toMap())
                        .toList(growable: false),
                    // Solo el PIN (se conoce sin red): la caja cliente no
                    // consulta Supabase directo antes del proxy (WAN malo).
                    // Sin PIN el ítem queda sin autor y el reporte lo
                    // acredita al mesero que abrió la mesa con PIN.
                    employeeId: mutation.pinEmployeeId,
                    clientOpId: clientOpId,
                  );
        if (realId != null && realId.isNotEmpty) {
          itemSavedOnServer = true;
          savedItemId = realId;
          if (optimisticItem != null) {
            final optId = optimisticItem.id;
            if (_isMutationOrderActive(mutation)) {
              _tmpToRealItemId[optId] = realId;
            }
            await _rememberKitchenItemIdentity(
              businessId: mutation.businessId,
              tmpId: optId,
              realId: realId,
            );
            // Adoptar el id real en el estado SIN refetch (la caja no llega a
            // Supabase): reemplaza el tmp por su versión con id real, para que
            // borrar/editar/cobrar después usen el id que el server conoce.
            _applyOrderMutation(mutation, (source) => source.copyWith(
              items: source.items
                  .map((it) => it.id == optId ? it.copyWith(id: realId) : it)
                  .toList(growable: false),
            ));
            await _persistOrderMutation(mutation, (source) => source.copyWith(
              items: source.items
                  .map((it) => it.id == optId ? it.copyWith(id: realId) : it)
                  .toList(growable: false),
            ));
          }
          return;
        }
        // Hub no respondió → respaldo local (op-log) por el catch.
        throw const _HubModeShortCircuit();
      }
      // El mesero del PIN se conoce sin red: va en la misma transacción del
      // alta. Sin PIN se resuelve después (puede consultar al servidor).
      final pinEmployeeId = mutation.pinEmployeeId;
      final added = await ref
          .read(salesRepositoryProvider)
          .addItemFromMenuIdempotent(
            clientOpId: clientOpId,
            orderId: orderId,
            menuItemId: menuItemId,
            quantity: qty,
            checkPosition: effectiveCheckPos,
            isTakeout: takeout,
            notes: notes,
            createdByEmployeeId: pinEmployeeId,
          );
      final itemId = added.itemId;
      itemSavedOnServer = added.itemExists;
      savedItemId = itemId;

      // Registrar tmp→real: a partir de aquí la recarga post-commit puede
      // soltar el optimista (su contraparte real ya existe en el server) sin
      // dejar duplicado.
      if (_isMutationOrderActive(mutation) &&
          optimisticItem != null && itemId.isNotEmpty) {
        _tmpToRealItemId[optimisticItem.id] = itemId;
      }
      if (optimisticItem != null && itemId.isNotEmpty) {
        await _rememberKitchenItemIdentity(
          businessId: mutation.businessId,
          tmpId: optimisticItem.id,
          realId: itemId,
        );
      }

      if (selectedModifiers.isNotEmpty && added.itemExists) {
        final modifiers = selectedModifiers
            .map((modifier) => modifier.toMap())
            .toList(growable: false);
        final repo = ref.read(salesRepositoryProvider);
        // Un alta repetida pudo haber guardado ya los extras: reemplazar deja
        // exactamente los elegidos, sin duplicarlos.
        if (added.replayed) {
          await repo.replaceOrderItemModifiers(
            itemId: itemId,
            modifiers: modifiers,
          );
        } else {
          await repo.addOrderItemModifiers(
            itemId: itemId,
            modifiers: modifiers,
          );
        }
      }

      // Audit trail del item: ver `_resolveItemEmployeeId` arriba. Va DESPUÉS
      // de los extras (que llevan precio) para que una consulta lenta no los
      // deje esperando, y antes de la recarga para que esta ya traiga al autor.
      //
      // 1) Modo multimesero: si hay `activeWaiter` (el mesero metió PIN al
      //    entrar a la mesa), ya viajó con el alta.
      // 2) Sin PIN se acredita al dueño de la mesa de la orden CAPTURADA
      //    (aunque el cajero ya haya cambiado de cuenta); si no hay dueño (o
      //    no se pudo saber), o es Venta Rápida/Manual, al empleado del
      //    usuario autenticado de ese negocio. Sin esto, todos los items que
      //    mete el cajero quedaban como "Sin asignar".
      if (itemId.isNotEmpty && pinEmployeeId == null && added.itemExists) {
        await _stampItemAuthor(mutation, itemId);
      }

      // Bypassear el debounce para que la respuesta sea instantánea
      if (_isMutationOrderActive(mutation)) {
        await _loadOrderDetail(
          orderId,
          selectionToken: mutation.selectionToken,
          reloadOf: orderId,
          caller: 'addItem',
        );
      }
      if (optimisticItem != null && itemId.isNotEmpty) {
        final temporaryId = optimisticItem.id;
        CurrentOrderState adoptItemId(CurrentOrderState source) => source.copyWith(
          items: source.items
              .map((item) => item.id == temporaryId
                  ? item.copyWith(id: itemId)
                  : item)
              .toList(growable: false),
        );
        _applyOrderMutation(mutation, adoptItemId);
        await _persistOrderMutation(mutation, adoptItemId);
      }

      // Fix #1: espejo del ítem al op-log del Hub (visibilidad LAN en clientes).
      // Id estable por item_id real → append idempotente.
      if (_activeBusinessId == mutation.businessId) {
        _mirrorHostMutationToHub({
        'id': 'host-add-$itemId',
        'type': 'add_item',
        'order_id': orderId,
        'item_id': itemId,
        'product_name': productName,
        'product_price': productPrice,
        'qty': qty,
        'check_pos': effectiveCheckPos,
        'takeout': takeout,
        'notes': notes,
      });
      }
    } catch (e) {
      final businessId = mutation.businessId;
      final isOffline = _shouldTreatAsOffline(e, orderId: orderId);

      if ((isOffline || itemSavedOnServer) &&
          optimisticItem != null &&
          businessId != null &&
          businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'add_item',
            'origin': mutation.origin,
            'table_id': mutation.tableId,
            'slot_id': mutation.slotId,
            'order_id': orderId,
            'item_id': optimisticItem.id,
            // Mismo id que el intento que acaba de fallar: si en realidad
            // hizo commit, el replay no crea un segundo ítem.
            'client_op_id': clientOpId,
            'menu_item_id': menuItemId,
            'qty': qty,
            'check_pos': effectiveCheckPos,
            'takeout': takeout,
            'notes': notes,
            'product_name': productName,
            'product_price': productPrice,
            'item_snapshot': OrderItemSnapshot.encode(optimisticItem),
            // Snapshot de modifiers seleccionados. Al sincronizar el replay
            // los re-aplica vía addOrderItemModifiers contra el item ya
            // creado en el server. Antes esto se perdía y los extras nunca
            // llegaban al server (bug del audit offline §sync).
            'selected_modifiers': selectedModifiers
                .map((m) => m.toMap())
                .toList(growable: false),
          },
        );
        final addedItem = optimisticItem;
        await _persistOrderMutation(mutation, (source) {
          if (source.items.any((item) => item.id == addedItem.id)) return source;
          return _mutationItemsState(source, [...source.items, addedItem]);
        });
        if (_isMutationOrderActive(mutation)) {
          state = state.copyWith(
            error: 'Producto agregado en local. Pendiente de sincronizar.',
          );
        }
        return;
      }

      // Revertir si hicimos optimismo
      if (optimisticItem != null) {
        final temporaryId = optimisticItem.id;
        final mappedId = businessId == null ? null : await _offlinePos
            .mappedRemoteItemId(businessId: businessId, localItemId: temporaryId);
        CurrentOrderState rollback(CurrentOrderState source) =>
            _mutationItemsState(source, source.items
                .where((item) => item.id != temporaryId && item.id != mappedId &&
                    item.id != savedItemId)
                .toList(growable: false));
        _applyOrderMutation(mutation, rollback, error: 'Error al agregar: $e');
        await _persistOrderMutation(mutation, rollback);
      } else if (_isMutationOrderActive(mutation)) {
        state = state.copyWith(error: 'Error al agregar producto: $e');
      }
    } finally {
      // Soltar el guard del alta. En el camino feliz, _loadOrderDetail ya
      // adoptó el item real (realId presente en el server) y descartó el tmp;
      // aquí solo limpiamos el registro. En error online se revierte el
      // optimismo; en offline el tmp persiste pero ya no hay recarga server
      // que lo amenace.
      if (optimisticItem != null) {
        _inFlightAddTmpIds.remove(optimisticItem.id);
        _tmpToRealItemId.remove(optimisticItem.id);
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
    if (!operatorHasPermissionRef(ref, 'ventas.orden.agregar_item')) {
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
    // Selección de esta oferta: tras cada espera, nada se escribe en pantalla
    // (optimista, recarga ni restauración) si el cajero ya pasó a otra cuenta.
    // Antes la recarga y la restauración del catch escribían la mesa A en la
    // Venta Rápida/Manual abierta mientras respondía el servidor.
    final selectionToken = _openTableToken;
    final selectionBusinessId = _activeBusinessId;
    bool stillSelected() =>
        selectionToken == _openTableToken &&
        _activeBusinessId == selectionBusinessId &&
        state.order?.id == orderId;
    final currentStatus = state.order?.status;
    if (currentStatus == 'paid' || currentStatus == 'void') {
      final origin = state.origin;
      state = state.copyWith(
        error: 'La orden anterior ya fue cerrada. Iniciando una nueva.',
      );
      await _restartClosedSale(origin);
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
    final previousOrder = state.order;

    await _ensureBusinessTaxSettingsLoaded();
    final resolvedTaxRate = productTaxRate ?? _cachedTaxRatePct;

    // OPTIMISTA: subtotal NETO (bruto - descuento) + marcador [DEAL:], igual que
    // lo guarda el backend, para que summarizeItemPricing aplique el override de
    // oferta y se vea "Subtotal/Descuento/Total" correcto al INSTANTE.
    final dealMarker = '[DEAL:${promotionId ?? ''}]';
    OrderItem? optimisticItem;
    if (previousOrder != null && stillSelected()) {
      final tempId = 'tmp_${DateTime.now().microsecondsSinceEpoch}';
      final grossAmount = (qty * originalPrice - discount)
          .clamp(0, double.infinity)
          .toDouble();
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

      final activeWaiter = _trustedActiveWaiter();
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
        total:
            updatedSummary.subtotal +
            updatedSummary.tax -
            updatedSummary.discounts,
      );
      state = state.copyWith(items: optimisticItems, order: updatedOrder);
    }

    // UN solo viaje: fn_add_offer_deal inserta la línea a precio original con el
    // descuento del deal. El client_op_id evita una segunda línea si la
    // respuesta se pierde y el alta se repite (20260929_0001).
    final clientOpId = const Uuid().v4();
    try {
      final dealItemId = await ref
          .read(salesRepositoryProvider)
          .addOfferDealItem(
            orderId: orderId,
            menuItemId: menuItemId,
            quantity: qty,
            discount: discount,
            name: name,
            promotionId: promotionId,
            checkPosition: effectiveCheckPos,
            clientOpId: clientOpId,
            createdByEmployeeId: _trustedActiveWaiter()?.employeeId,
          );
      if (optimisticItem != null && dealItemId != null) {
        await _rememberKitchenItemIdentity(
          businessId: selectionBusinessId,
          tmpId: optimisticItem.id,
          realId: dealItemId,
        );
      }
      await _loadOrderDetail(
        orderId,
        selectionToken: selectionToken,
        reloadOf: orderId,
        caller: 'addOfferDeal',
      );
    } catch (e) {
      // La oferta era de una cuenta que ya no está en pantalla: no hay nada
      // que restaurar ni recargar aquí (la próxima carga de esa cuenta trae
      // la verdad del servidor).
      if (!stillSelected()) return;
      if (optimisticItem != null) {
        // Solo se quita la línea de esta oferta. Volver a la lista de antes
        // borraba de la pantalla los productos agregados mientras esperaba.
        final failedId = optimisticItem.id;
        state = _mutationItemsState(
          state,
          state.items.where((item) => item.id != failedId).toList(),
        ).copyWith(error: 'No se pudo agregar la oferta: $e');
      } else {
        state = state.copyWith(error: 'No se pudo agregar la oferta: $e');
      }
      // Error de red: el servidor pudo haber guardado la línea igual. Recargar
      // muestra la verdad en vez de invitar a tocar otra vez (= duplicado).
      if (OfflinePosService.isTransportError(e)) refreshOrder();
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
      if (_isHubMode) {
        // Caja cliente: no intentamos Supabase directo (WAN malo) — optimista
        // + op-log; el Hub lo drena al servidor en ~4s (uplink rápido).
        throw const _HubModeShortCircuit();
      }
      await ref
          .read(salesRepositoryProvider)
          .markOrderTakeout(orderId: orderId, takeout: value);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline = _shouldTreatAsOffline(e, orderId: orderId);
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

  /// Un alta en línea terminó mientras una comanda local imprime su línea
  /// temporal: la línea pasa a su id real (ver _tmpToRealItemId). El bloqueo
  /// y la marca de enviada la siguen por ese id; antes quedaba editable y
  /// «por confirmar», y el siguiente «Enviar» la reimprimía.
  void _noteRenamedInLocalKitchenPrint(String tmpId, String realId) {
    for (final printing in _localKitchenPrints) {
      if (!printing.itemIds.contains(tmpId)) continue;
      printing.itemIds.add(realId);
      printing.renamedIds[tmpId] = realId;
    }
  }

  /// Alta en línea terminada (producto u oferta), con el negocio de la
  /// operación. El replay de una comanda local confirma solo sus líneas y
  /// busca esta por su id temporal: el mapeo se guarda si la comanda se está
  /// imprimiendo o si ya salió y su confirmación sigue en la cola (aunque la
  /// impresión haya terminado antes que el alta). Se espera: sin él, la
  /// comanda queda retenida.
  Future<void> _rememberKitchenItemIdentity({
    required String? businessId,
    required String tmpId,
    required String realId,
  }) async {
    if (businessId == null || businessId.isEmpty) return;
    final inLocalPrint = _localKitchenPrints.any(
      (printing) =>
          printing.businessId == businessId && printing.itemIds.contains(tmpId),
    );
    _noteRenamedInLocalKitchenPrint(tmpId, realId);
    try {
      await _offlinePos.rememberKitchenItemMapping(
        businessId: businessId,
        localItemId: tmpId,
        remoteItemId: realId,
        force: inLocalPrint,
      );
    } catch (e) {
      debugPrint('[SalesVM] mapeo de la línea de la comanda: $e');
    }
  }

  /// True si [itemId] es una línea de la comanda que se imprime ahora mismo
  /// por la LAN en este negocio (por su id local o, si la orden ya subió
  /// durante la impresión, por su id remoto). Solo se llama con una impresión
  /// en vuelo, así que sin ella las ediciones no ganan ningún await.
  Future<bool> _inLocalKitchenPrint(String itemId) async {
    final businessId = _activeBusinessId;
    for (final printing in List.of(_localKitchenPrints)) {
      if (printing.businessId != businessId) continue;
      if (printing.itemIds.contains(itemId)) return true;
      // Copia: un alta que termina durante los await agrega su id real.
      for (final localId in List.of(printing.itemIds)) {
        final mapped = await _offlinePos.mappedRemoteItemId(
          businessId: printing.businessId,
          localItemId: localId,
        );
        if (mapped == itemId) return true;
      }
    }
    return false;
  }

  /// Devuelve `true` si el producto salió de la cuenta: borrado en el
  /// servidor o encolado sin red (el borrado ya es un hecho para esta caja).
  /// `false` si no se borró — la pantalla no debe imprimir el comprobante ni
  /// avisar al bar de algo que sigue en la cuenta.
  Future<bool> deleteItem(
    String itemId, {
    String? reason,
    String? reasonCode,

    /// true = MERMA: el servidor NO devuelve el stock (20260920_0002).
    bool? isWaste,
  }) async {
    if (_localKitchenPrints.isNotEmpty &&
        await _inLocalKitchenPrint(itemId)) {
      state = state.copyWith(error: _localKitchenPrintBusyMessage);
      return false;
    }
    final orderId = state.order?.id;
    if (orderId == null) return false;

    OrderItem? targetItem;
    for (final item in state.items) {
      if (item.id == itemId) {
        targetItem = item;
        break;
      }
    }
    if (targetItem == null) {
      state = state.copyWith(
        error: 'No se elimino el producto: ya no pertenece a esta orden.',
      );
      return false;
    }
    final mutation = _captureOrderMutation(orderId);
    final previousPosition = state.items.indexOf(targetItem);
    String? mappedItemId;
    CurrentOrderState removeTarget(CurrentOrderState source) =>
        _mutationItemsState(source, source.items
            .where((item) => item.id != itemId && item.id != mappedItemId)
            .toList(growable: false));
    CurrentOrderState restoreTarget(CurrentOrderState source) {
      if (source.items.any((item) => item.id == itemId || item.id == mappedItemId)) {
        return source;
      }
      final items = List<OrderItem>.of(source.items);
      items.insert(previousPosition.clamp(0, items.length), targetItem!.copyWith(
        id: mappedItemId ?? itemId,
        orderId: source.order?.id ?? orderId,
      ));
      return _mutationItemsState(source, items);
    }

    // 2. Optimistic Local Update — marcamos el id como borrado pendiente para
    // que ninguna recarga stale (refreshOrder/Realtime) lo resucite.
    _pendingDeletedItemIds.add(itemId);
    _applyOrderMutation(mutation, removeTarget);

    var deletedOnServer = false;
    try {
      await _persistOrderMutation(mutation, removeTarget);
      if (_isHubMode) {
        // Caja cliente: no intentamos Supabase directo (WAN malo) — optimista
        // + op-log; el Hub lo drena al servidor en ~4s (uplink rápido).
        throw const _HubModeShortCircuit();
      }
      await ref.read(salesRepositoryProvider).deleteItem(itemId: itemId);
      deletedOnServer = true;

      // El borrado ya pasó: el motivo y el operador se anotan aparte, sin
      // hacer esperar a la pantalla.
      unawaited(
        _noteItemRemovalFor(
          mutation,
          itemId,
          reason: reason,
          reasonCode: reasonCode,
          isWaste: isWaste,
        ),
      );

      // Fase 1 Toast redesign: si el item borrado era el último de un
      // sub-check, cerrar ese check automáticamente. El principal (C1) y los
      // checks con items restantes se quedan como estaban.
      final deletedCheckId = targetItem.checkId;
      if (deletedCheckId != null && deletedCheckId.isNotEmpty) {
        try {
          await ref
              .read(salesRepositoryProvider)
              .closeEmptyCheckIfApplicable(deletedCheckId);
        } catch (checkError) {
          // El producto YA se borro. Fallar esta limpieza no puede restaurarlo
          // en pantalla ni encolar una segunda eliminacion.
          debugPrint(
            'No se pudo cerrar el check vacio $deletedCheckId: $checkError',
          );
        }
      }

      if (_isMutationOrderActive(mutation)) refreshOrder();
      await _persistOrderMutation(mutation, removeTarget);

      // Fix #1: espejo del borrado al op-log del Hub (visibilidad LAN).
      if (_activeBusinessId == mutation.businessId) {
        _mirrorHostMutationToHub({
        'type': 'delete_item',
        'order_id': orderId,
        'item_id': itemId,
      });
      }
      return true;
    } catch (e) {
      final businessId = mutation.businessId;
      if (deletedOnServer) {
        if (_isMutationOrderActive(mutation)) {
          state = state.copyWith(
          error: 'Producto eliminado; no se pudo actualizar la copia local: $e',
        );
        }
        return true;
      }
      final isOffline = _shouldTreatAsOffline(e, orderId: orderId);
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        try {
          await _offlinePos.enqueueAction(
            businessId: businessId,
            action: {
              'type': 'delete_item',
              'origin': mutation.origin,
              'table_id': mutation.tableId,
              'slot_id': mutation.slotId,
              'order_id': orderId,
              'item_id': itemId,
              'product_id': targetItem.productId,
              'product_name': targetItem.productName,
              'notes': targetItem.notes,
              'is_takeout': targetItem.isTakeout,
              // El replay necesita el motivo y el operador del momento.
              'reason': reason,
              'reason_code': reasonCode,
              'is_waste': isWaste,
              'employee_id':
                  mutation.actorEmployeeId,
            },
          );
        } catch (queueError) {
          _pendingDeletedItemIds.remove(itemId);
          mappedItemId = await _offlinePos
              .mappedRemoteItemId(businessId: businessId, localItemId: itemId);
          _applyOrderMutation(mutation, restoreTarget,
              error: 'No se guardo la eliminacion offline: $queueError');
          await _persistOrderMutation(mutation, restoreTarget);
          return false;
        }
        try {
          await _persistOrderMutation(mutation, removeTarget);
        } catch (snapshotError) {
          if (_isMutationOrderActive(mutation)) {
            state = state.copyWith(
            error:
                'Eliminacion en cola, pero fallo la copia local: '
                '$snapshotError. No cierre este equipo hasta sincronizar.',
          );
          }
          // La eliminación SÍ quedó en la cola: se va a aplicar.
          return true;
        }
        if (_isMutationOrderActive(mutation)) {
          state = state.copyWith(
          error: 'Producto eliminado en local. Pendiente de sincronizar.',
        );
        }
        return true;
      }

      // El borrado falló → soltamos la guarda para no ocultar el item.
      _pendingDeletedItemIds.remove(itemId);
      if (businessId != null) {
        mappedItemId = await _offlinePos
          .mappedRemoteItemId(businessId: businessId, localItemId: itemId);
      }
      _applyOrderMutation(mutation, restoreTarget, error: 'Error al eliminar: $e');
      await _persistOrderMutation(mutation, restoreTarget);
      return false;
    }
  }

  List<OrderItemTaxLine> _taxLinesAtSubtotal(OrderItem item, double subtotal) {
    if (item.subtotal <= 0) return item.taxLines;
    final ratio = subtotal / item.subtotal;
    return item.taxLines
        .map(
          (line) => OrderItemTaxLine(
            id: line.id,
            orderItemId: line.orderItemId,
            taxId: line.taxId,
            taxName: line.taxName,
            taxRate: line.taxRate,
            amount: _roundMoney(line.amount * ratio),
            createdAt: line.createdAt,
          ),
        )
        .toList(growable: false);
  }

  Future<void> updateItemQuantity(String itemId, double quantity) async {
    if (!operatorHasPermissionRef(ref, 'ventas.orden.editar_item')) {
      state = state.copyWith(
        error: 'No tienes permiso para editar líneas de orden.',
      );
      return;
    }
    if (_localKitchenPrints.isNotEmpty &&
        await _inLocalKitchenPrint(itemId)) {
      state = state.copyWith(error: _localKitchenPrintBusyMessage);
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

    if (targetItem == null) {
      state = state.copyWith(error: 'El producto ya no pertenece a esta orden.');
      return;
    }
    final mutation = _captureOrderMutation(orderId);
    final originalItem = targetItem;
    final mutationKey = '${mutation.businessId}|$orderId|$itemId';
    final quantityVersion = (_itemQuantityMutationVersions[mutationKey] ?? 0) + 1;
    _itemQuantityMutationVersions[mutationKey] = quantityVersion;
    String? mappedItemId;
    bool matchesItem(OrderItem item) => item.id == itemId || item.id == mappedItemId;
    CurrentOrderState rollbackQuantity(CurrentOrderState source) {
      if (_itemQuantityMutationVersions[mutationKey] != quantityVersion) {
        return source;
      }
      return _mutationItemsState(source, source.items.map((item) {
          if (!matchesItem(item) || (item.quantity - quantity).abs() > 0.0001) {
            return item;
          }
          return item.copyWith(
            quantity: originalItem.quantity,
            subtotal: originalItem.subtotal,
            tax: originalItem.tax,
            total: originalItem.total,
            taxLines: originalItem.taxLines,
          );
        }).toList(growable: false));
    }
    CurrentOrderState quantitySnapshot = mutation.snapshot;
    {
      // PRD 2: el item.tax ya viene consolidado del motor backend (incluye
      // propina si aplicaba). El frontend optimista derive la tasa total
      // del propio item y no agrega service fee separado.
      final taxRate = targetItem.subtotal > 0
          ? (targetItem.tax / targetItem.subtotal)
          : 0.0;
      final optimisticAmounts = _estimateOptimisticItemAmounts(
        grossAmount:
            (targetItem.unitPrice +
                targetItem.modifiers.fold<double>(
                  0,
                  (sum, modifier) => sum + modifier.price * modifier.qty,
                )) *
            quantity,
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
                    total: (optimisticAmounts.total - item.discounts)
                        .clamp(0, double.infinity)
                        .toDouble(),
                    taxLines: _taxLinesAtSubtotal(
                      item,
                      optimisticAmounts.subtotal,
                    ),
                  ),
          )
          .toList(growable: false);
      final updatedSummary = summarizeOrderPricing(
        state.order,
        optimisticItems,
      );
      quantitySnapshot = state.copyWith(
        items: optimisticItems,
        order: state.order?.copyWith(
          subtotal: updatedSummary.subtotal,
          tax: updatedSummary.tax,
          serviceFee: updatedSummary.serviceFee,
          total: updatedSummary.total,
        ),
        error: null,
      );
      _applyOrderMutation(mutation, (_) => quantitySnapshot);
    }

    // Guarda: el cambio de cantidad queda pendiente hasta que el server lo
    // confirme; así una recarga stale (qty vieja) no revierte la línea.
    _pendingItemQty[itemId] = quantity;
    final updatedItem = quantitySnapshot.items.firstWhere(
      (item) => item.id == itemId,
    );
    CurrentOrderState applyQuantity(CurrentOrderState source) =>
        _mutationItemsState(source, source.items.map((item) => !matchesItem(item)
            ? item
            : item.copyWith(
                quantity: updatedItem.quantity,
                subtotal: updatedItem.subtotal,
                tax: updatedItem.tax,
                total: updatedItem.total,
                taxLines: updatedItem.taxLines,
              )).toList(growable: false));

    var quantitySavedOnServer = false;
    try {
      await _persistOrderMutation(mutation, applyQuantity);
      if (_isHubMode) {
        // Caja cliente: no intentamos Supabase directo (WAN malo) — optimista
        // + op-log; el Hub lo drena al servidor en ~4s (uplink rápido).
        throw const _HubModeShortCircuit();
      }
      await ref
          .read(salesRepositoryProvider)
          .updateItemQuantity(itemId: itemId, quantity: quantity);
      quantitySavedOnServer = true;
      if (_isMutationOrderActive(mutation)) refreshOrder();

      // Fix #1: espejo del cambio de cantidad al op-log del Hub.
      if (_activeBusinessId == mutation.businessId) {
        _mirrorHostMutationToHub({
        'type': 'update_item_quantity',
        'order_id': orderId,
        'item_id': itemId,
        'quantity': quantity,
      });
      }
    } catch (e) {
      final businessId = mutation.businessId;
      final isOffline = _shouldTreatAsOffline(e, orderId: orderId);
      if (isOffline && businessId != null && businessId.isNotEmpty) {
        // Una edición posterior de la misma línea ya manda la cantidad
        // vigente (confirmada o en su propia cola). Encolar esta, más vieja,
        // la dejaría al sincronizar: 2 encolado después de confirmar 3.
        if (_itemQuantityMutationVersions[mutationKey] != quantityVersion) {
          return;
        }
        try {
          await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'update_item_quantity',
            'origin': mutation.origin,
            'table_id': mutation.tableId,
            'slot_id': mutation.slotId,
            'order_id': orderId,
            'item_id': itemId,
            'quantity': quantity,
            'item_snapshot': OrderItemSnapshot.encode(updatedItem),
            'product_id': targetItem.productId,
            'product_name': targetItem.productName,
            'notes': targetItem.notes,
            'is_takeout': targetItem.isTakeout,
          },
        );
        } catch (queueError) {
          mappedItemId = await _offlinePos.mappedRemoteItemId(
            businessId: businessId,
            localItemId: itemId,
          );
          if (_itemQuantityMutationVersions[mutationKey] == quantityVersion &&
              _pendingItemQty[itemId] == quantity) {
            _pendingItemQty.remove(itemId);
          }
          _applyOrderMutation(mutation, rollbackQuantity,
              error: 'No se guardó la cantidad offline: $queueError');
          await _persistOrderMutation(mutation, rollbackQuantity);
          return;
        }
        await _persistOrderMutation(mutation, (source) => source);
        if (_isMutationOrderActive(mutation)) {
          state = state.copyWith(
          error: 'Cantidad actualizada en local. Pendiente de sincronizar.',
        );
        }
        return;
      }

      if (quantitySavedOnServer) return;
      // El cambio falló → soltamos la guarda para no fijar una qty inexistente.
      if (_itemQuantityMutationVersions[mutationKey] == quantityVersion &&
          _pendingItemQty[itemId] == quantity) {
        _pendingItemQty.remove(itemId);
      }
      if (businessId != null) {
        mappedItemId = await _offlinePos.mappedRemoteItemId(
        businessId: businessId,
        localItemId: itemId,
      );
      }
      _applyOrderMutation(mutation, rollbackQuantity,
          error: 'Error al actualizar cantidad: $e');
      await _persistOrderMutation(mutation, rollbackQuantity);
    }
  }

  Future<void> updateItemNotes(String itemId, String notes) async {
    if (!operatorHasPermissionRef(ref, 'ventas.orden.editar_item')) {
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
      if (_isHubMode) {
        // Caja cliente: no intentamos Supabase directo (WAN malo) — optimista
        // + op-log; el Hub lo drena al servidor en ~4s (uplink rápido).
        throw const _HubModeShortCircuit();
      }
      await ref
          .read(salesRepositoryProvider)
          .updateItemNotes(itemId: itemId, notes: notes);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline = _shouldTreatAsOffline(e, orderId: orderId);
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
      if (_isHubMode) {
        // Caja cliente: no intentamos Supabase directo (WAN malo) — optimista
        // + op-log; el Hub lo drena al servidor en ~4s (uplink rápido).
        throw const _HubModeShortCircuit();
      }
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
          .map(
            (item) =>
                item.id == itemId ? item.copyWith(isTakeout: isTakeout) : item,
          )
          .toList(growable: false);
      state = state.copyWith(items: _filterTaxLinesByTakeout(patchedItems));
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline = _shouldTreatAsOffline(e, orderId: orderId);
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
            'item_snapshot': _snapshotForItem(itemId),
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
    final groups = await _itemOptionsWithOfflineFallback(
      fetch: () => ref
          .read(salesRepositoryProvider)
          .getComboGroupsForMenuItem(menuItemId),
      loadCached: (bid) =>
          PosLookupOfflineCache().loadComboGroups(bid, menuItemId),
      saveCached: (bid, rows) =>
          PosLookupOfflineCache().saveComboGroups(bid, menuItemId, rows),
    );
    _comboGroupsCache[menuItemId] = groups;
    return groups;
  }

  Future<List<Map<String, dynamic>>> getMenuItemModifierGroups(
    String menuItemId,
  ) async {
    final cached = _modifierGroupsCache[menuItemId];
    if (cached != null) return cached;
    final groups = await _itemOptionsWithOfflineFallback(
      fetch: () => ref
          .read(salesRepositoryProvider)
          .getModifierGroupsForMenuItem(menuItemId),
      loadCached: (bid) =>
          PosLookupOfflineCache().loadModifierGroups(bid, menuItemId),
      saveCached: (bid, rows) =>
          PosLookupOfflineCache().saveModifierGroups(bid, menuItemId, rows),
    );
    _modifierGroupsCache[menuItemId] = groups;
    return groups;
  }

  /// Modificadores / grupos de combo de un producto sin que la red pueda
  /// impedir agregarlo. Se piden ANTES de cada `addItem`: sin este respaldo,
  /// con el internet caído ningún producto nuevo entraba a la orden.
  ///
  /// Sin red se sirve la última copia en disco (la bajada en background la
  /// mantiene al día). Si este equipo nunca la bajó, el producto entra SIN
  /// modificadores — el mesero puede anotarlo — en vez de perder la venta.
  /// Los errores que no son de red se siguen lanzando.
  Future<List<Map<String, dynamic>>> _itemOptionsWithOfflineFallback({
    required Future<List<Map<String, dynamic>>> Function() fetch,
    required Future<List<Map<String, dynamic>>?> Function(String businessId)
    loadCached,
    required Future<void> Function(
      String businessId,
      List<Map<String, dynamic>> rows,
    )
    saveCached,
  }) async {
    final businessId = _activeBusinessId ?? '';
    Future<List<Map<String, dynamic>>> fromCache() async =>
        (businessId.isEmpty ? null : await loadCached(businessId)) ??
        const <Map<String, dynamic>>[];

    if (_preferLocalOperations) return fromCache();
    try {
      final rows = await fetch().timeout(const Duration(seconds: 6));
      if (businessId.isNotEmpty) unawaited(saveCached(businessId, rows));
      return rows;
    } catch (e) {
      if (!OfflinePosService.isTransportError(e)) rethrow;
      _recordTransportFailure();
      return fromCache();
    }
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
    if (!operatorHasPermissionRef(ref, 'ventas.orden.editar_item')) {
      state = state.copyWith(
        error: 'No tienes permiso para editar líneas de orden.',
      );
      return;
    }
    if (_localKitchenPrints.isNotEmpty &&
        await _inLocalKitchenPrint(itemId)) {
      state = state.copyWith(error: _localKitchenPrintBusyMessage);
      throw const _KitchenRoundEditBlocked(_localKitchenPrintBusyMessage);
    }
    final orderId = state.order?.id;
    if (orderId == null) return;

    // Modal abierto antes de que la ronda saliera a cocina: trae la línea
    // «por enviar», pero ya se envió. Cambiarle la cantidad en sitio cobraría
    // unidades que cocina nunca recibió (o quitaría sin PIN algo ya impreso).
    final staleDraft =
        updatedItem.status == 'draft' || updatedItem.status == 'open';
    if (staleDraft) {
      for (final current in state.items) {
        if (current.id != itemId) continue;
        final status = current.status;
        final sentNow =
            status != 'draft' &&
            status != 'open' &&
            status != 'void' &&
            status != 'paid';
        if (sentNow &&
            (updatedItem.quantity - current.quantity).abs() > 0.0001) {
          state = state.copyWith(error: _kitchenRoundAlreadySentMessage);
          throw const _KitchenRoundEditBlocked(
            _kitchenRoundAlreadySentMessage,
          );
        }
        break;
      }
    }

    // Sin red (u orden local) el guardado del modal no tiene endpoint: se
    // reparte en las mutaciones que SÍ saben encolar (cantidad, notas, para
    // llevar). Antes salía "No se pudo guardar" y el cambio se perdía.
    if (!_connectivity.isConnected || orderId.startsWith('local-order-')) {
      await _updateItemViaQueueableMutations(itemId, updatedItem);
      return;
    }

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
      }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

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
      if (OfflinePosService.isTransportError(e)) {
        unawaited(_connectivity.forceReachabilityCheck());
        await _updateItemViaQueueableMutations(resolvedId, updatedItem);
        return;
      }
      state = state.copyWith(error: 'Error al actualizar item: $e');
      rethrow;
    }
  }

  /// Aplica lo que cambió en el modal de edición usando las mutaciones que
  /// tienen camino offline (optimista + cola). El descuento por línea no lo
  /// tiene: se avisa en vez de perderlo en silencio.
  Future<void> _updateItemViaQueueableMutations(
    String itemId,
    OrderItem updatedItem,
  ) async {
    OrderItem? current;
    for (final item in state.items) {
      if (item.id == itemId) {
        current = item;
        break;
      }
    }
    if (current == null) return;

    final newNotes = updatedItem.notes?.trim() ?? '';
    final oldNotes = current.notes?.trim() ?? '';
    final discountChanged =
        (updatedItem.discounts - current.discounts).abs() > 0.0001;

    if ((updatedItem.quantity - current.quantity).abs() > 0.0001) {
      await updateItemQuantity(itemId, updatedItem.quantity);
    }
    if (newNotes != oldNotes) {
      await updateItemNotes(itemId, newNotes);
    }
    if (updatedItem.isTakeout != current.isTakeout) {
      await toggleItemTakeout(itemId, updatedItem.isTakeout);
    }
    if (discountChanged) {
      state = state.copyWith(
        error:
            'Sin conexión: el descuento de la línea no se guardó. '
            'Aplícalo de nuevo cuando vuelva el internet.',
      );
    }
  }

  Future<void> applyDiscountPercentToItems({
    required List<String> itemIds,
    required double percent,
    bool preAuthorized = false,
  }) async {
    // [preAuthorized] lo usa la pantalla cuando ya validó el acceso
    // (permiso del usuario o PIN de supervisor de respaldo). El chequeo
    // de permiso queda como red de seguridad para cualquier otro llamador.
    if (!preAuthorized &&
        !operatorHasPermissionRef(ref, 'ventas.orden.descuento_aplicar')) {
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
          // Una línea con premio de la tarjeta de sellos conserva su unidad
          // gratis: el porcentaje va sobre lo que el cliente sí paga. Sin
          // premio es exactamente base × %.
          final discount = discountKeepingLoyaltyReward(
            subtotal: item.subtotal,
            tax: item.tax,
            quantity: item.quantity,
            notes: item.notes,
            manualOnRest: (rest) => rest * (clampedPercent / 100),
          );
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

  /// Aplica un descuento de monto fijo repartiéndolo entre los ítems
  /// proporcionalmente a su base (subtotal + impuesto). Persiste por ítem con
  /// el mismo canal que el descuento porcentual, así impresión, reportes y
  /// split-bill no necesitan cambios.
  Future<void> applyDiscountAmountToItems({
    required List<String> itemIds,
    required double amount,
    bool preAuthorized = false,
  }) async {
    // Ver nota en applyDiscountPercentToItems: la pantalla autoriza con
    // permiso o PIN de respaldo; aquí solo queda la red de seguridad.
    if (!preAuthorized &&
        !operatorHasPermissionRef(ref, 'ventas.orden.descuento_aplicar')) {
      state = state.copyWith(
        error: 'No tienes permiso para aplicar descuentos.',
      );
      return;
    }
    final orderId = state.order?.id;
    if (orderId == null || itemIds.isEmpty || amount <= 0) return;

    final targetItems = state.items
        .where(
          (i) =>
              itemIds.contains(i.id) &&
              i.status != 'paid' &&
              i.status != 'void',
        )
        .toList(growable: false);
    if (targetItems.isEmpty) return;

    // Base descontable: lo que NO cubre un premio de la tarjeta de sellos
    // (sin premio, subtotal + impuesto como siempre).
    final baseByItemId = <String, double>{
      for (final item in targetItems)
        item.id: loyaltyDiscountableBase(
          subtotal: item.subtotal,
          tax: item.tax,
          quantity: item.quantity,
          notes: item.notes,
        ),
    };
    final totalBase = baseByItemId.values.fold<double>(0, (s, b) => s + b);
    if (totalBase <= 0) return;

    // Nunca descontar más que el total de los ítems objetivo.
    final effectiveAmount = amount.clamp(0, totalBase).toDouble();

    // Prorrateo con ajuste de redondeo: los primeros llevan su parte
    // redondeada a centavos y el último absorbe la diferencia para que la
    // suma sea exactamente el monto pedido.
    final discountByItemId = <String, double>{};
    double assigned = 0;
    for (var i = 0; i < targetItems.length; i++) {
      final item = targetItems[i];
      final base = baseByItemId[item.id]!;
      double share;
      if (i == targetItems.length - 1) {
        share = (effectiveAmount - assigned).clamp(0, base).toDouble();
      } else {
        share = double.parse(
          (effectiveAmount * (base / totalBase)).toStringAsFixed(2),
        ).clamp(0, base).toDouble();
      }
      share = double.parse(share.toStringAsFixed(2));
      assigned += share;
      // El premio (si lo hay) se suma encima de su parte del monto.
      discountByItemId[item.id] = discountKeepingLoyaltyReward(
        subtotal: item.subtotal,
        tax: item.tax,
        quantity: item.quantity,
        notes: item.notes,
        manualOnRest: (_) => share,
      );
    }

    state = state.copyWith(loading: true, error: null);
    try {
      await Future.wait(
        targetItems.map((item) {
          final notesWithoutCourtesy = _stripCourtesyFromNotes(item.notes);
          return ref
              .read(salesRepositoryProvider)
              .updateItemDiscountAndNotes(
                itemId: item.id,
                discounts: discountByItemId[item.id]!,
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
    bool preAuthorized = false,
  }) async {
    // Ver nota en applyDiscountPercentToItems: la pantalla autoriza con
    // permiso o PIN de respaldo; aquí solo queda la red de seguridad.
    if (!preAuthorized &&
        !operatorHasPermissionRef(ref, 'ventas.orden.descuento_aplicar')) {
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
      if (_isHubMode) {
        // Caja cliente: no intentamos Supabase directo (WAN malo) — optimista
        // + op-log; el Hub lo drena al servidor en ~4s (uplink rápido).
        throw const _HubModeShortCircuit();
      }
      await ref
          .read(salesRepositoryProvider)
          .moveItemToCheck(itemId: itemId, checkPosition: pos);
      refreshOrder();
    } catch (e) {
      final businessId = _activeBusinessId;
      final isOffline = _shouldTreatAsOffline(e, orderId: orderId);
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
    if (!operatorHasPermissionRef(ref, 'ventas.mesas.liberar')) {
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

  /// True si la venta en pantalla ya se cobró sin internet y su cobro espera
  /// en la cola. [cancelCurrentOrder] no la anula; los botones lo consultan
  /// para avisar en vez de decir "Venta descartada".
  Future<bool> currentOrderHasQueuedPayment() async {
    final orderId = state.order?.id;
    final businessId = _activeBusinessId;
    if (orderId == null || businessId == null || businessId.isEmpty) {
      return false;
    }
    return _offlinePos.hasQueuedPayment(
      businessId: businessId,
      orderId: orderId,
    );
  }

  /// [queueVoid]: no anular en línea aunque haya red; la anulación va a la
  /// cola y su replay lee el servidor y omite una venta ya cobrada o cerrada.
  /// Para cuando la pantalla puede estar vieja y no se pudo confirmar en el
  /// servidor que la orden sigue abierta (ver closeRetailCart).
  /// [voidOnlyIfUnpaid]: anulación automática (cerrar una pestaña retail).
  /// En línea, el servidor anula solo si la venta sigue abierta y sin cobros;
  /// si no, lanza [_OrderNotVoidable] y no cambia nada. La anulación que pide
  /// el cajero no lo usa.
  Future<void> cancelCurrentOrder({
    String? reason,
    bool releaseOnlyIfEmpty = false,
    String? expectedOrderId,
    bool queueVoid = false,
    bool voidOnlyIfUnpaid = false,
  }) async {
    final cancellingState = state;
    final orderId = cancellingState.order?.id;
    if (expectedOrderId != null && expectedOrderId != orderId) return;
    if (releaseOnlyIfEmpty && state.items.isNotEmpty) return;
    if (orderId == null) {
      _hasManualFiscalTypeSelection = false;
      state = const CurrentOrderState();
      return;
    }
    final trimmedReason = reason?.trim();
    final businessId = _activeBusinessId;
    var selectionToken = _openTableToken;
    bool stillSelected() =>
        _activeBusinessId == businessId &&
        _openTableToken == selectionToken &&
        state.order?.id == orderId;
    void clearCancelledSelection() {
      if (!stillSelected()) return;
      _hasManualFiscalTypeSelection = false;
      state = const CurrentOrderState();
    }
    // La nota también pertenece a la cuenta que se está anulando. Una
    // navegación durante el cierre nunca debe escribir la nota en otra mesa.
    final cancelledSessionId = cancellingState.order!.sessionId;
    final noteAtCancellation = cancellingState.sessionNote?.trim();
    final actorAtCancellation = ref.read(sessionProvider).userName?.trim() ?? '';
    final cancellationStamp = DateTime.now().toLocal().toIso8601String();

    // Venta cobrada sin internet: su cobro espera en la cola. Anularla o
    // descartarla lo borraba junto con la venta (orden local) o lo dejaba sin
    // orden abierta a la que aplicarse al sincronizar (orden del servidor).
    // Pasaba al tocar "Descartar venta" o "Salir" al cambiar de pantalla con
    // la venta ya cobrada todavía visible. Ya está pagada: solo sale de la
    // pantalla y la cola la sube con su comprobante.
    if (businessId != null &&
        businessId.isNotEmpty &&
        await _offlinePos.hasQueuedPayment(
          businessId: businessId,
          orderId: orderId,
        )) {
      if (releaseOnlyIfEmpty) return;
      await _offlinePos.markOrderClosedLocally(
        businessId: businessId,
        orderId: orderId,
      );
      if (_activeBusinessId == businessId) {
        _tableCache.removeWhere((_, cached) => cached.order?.id == orderId);
      }
      if (stillSelected()) {
        ++_loadGeneration;
        selectionToken = ++_openTableToken;
      }
      clearCancelledSelection();
      return;
    }

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
      if (businessId == null || businessId.isEmpty) {
        throw StateError('No se puede cerrar la orden sin negocio activo.');
      }
      if (orderId.startsWith('local-order-')) {
        final mappedRemoteId = await _offlinePos.mappedRemoteOrderId(
          businessId: businessId,
          localOrderId: orderId,
        );
        final terminalMode = ref.read(hubModeProvider);
        final hubKnowsOrder =
            terminalMode == TerminalMode.hubClient ||
            terminalMode == TerminalMode.hubHost ||
            await _offlinePos.mayExistRemotely(
              businessId: businessId,
              orderId: orderId,
            );
        if (mappedRemoteId == null && !hubKnowsOrder) {
          // La orden nunca llegó al server: purgamos sus acciones encoladas
          // y snapshots. Antes solo se reseteaba la UI y la cola recreaba la
          // mesa al reconectar (mesa fantasma) mientras el overlay del salón
          // la seguía mostrando ocupada.
          // `false` = tenía un cobro en cola (o la cola no se pudo leer): la
          // venta se conserva y tampoco se encola su anulación.
          final discarded = await _offlinePos.discardLocalOrder(
            businessId: businessId,
            localOrderId: orderId,
          );
          if (discarded) {
            _tableCache.removeWhere((_, s) => s.order?.id == orderId);
          }
          return;
        }
        // Ya sincronizó en background: la orden real existe en el server,
        // hay que anularla de verdad. void_order con el id local resuelve
        // al remoto vía el mapping en el replay.
      }
      await _offlinePos.enqueueAction(
        businessId: businessId,
        action: <String, dynamic>{
          'type': releaseOnlyIfEmpty ? 'release_empty_order' : 'void_order',
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
      if (releaseOnlyIfEmpty &&
          (ref.read(hubModeProvider) == TerminalMode.hubClient ||
              ref.read(hubModeProvider) == TerminalMode.hubHost)) {
        // enqueueAction starts this drain asynchronously; await that same
        // flight so the salon refresh sees the Hub acknowledgement promptly.
        await _offlinePos.flushPendingToHub(businessId);
      }
      if (orderId.startsWith('local-order-')) {
        await _offlinePos.removeOrderSnapshots(
          businessId: businessId,
          orderId: orderId,
        );
        _tableCache.removeWhere((_, s) => s.order?.id == orderId);
      }
    }

    // Tras anular, la pantalla abre una venta nueva en la misma mesa. La orden
    // anulada no debe volver a aparecer: openTable pinta primero el cache en
    // memoria (y si no hay, el snapshot en disco), y una recarga de Realtime
    // ya agendada o en vuelo la volvería a cargar mientras la nueva abre. Mismo
    // trato que un pago completo (markPaidOrderLocally). La liberación de una
    // mesa vacía (releaseOnlyIfEmpty) no pasa por aquí: no reabre nada.
    Future<void> forgetVoidedOrder() async {
      if (releaseOnlyIfEmpty) return;
      if (_activeBusinessId == businessId) {
        _tableCache.removeWhere((_, cached) => cached.order?.id == orderId);
        if (_queuedRefreshOrderId == orderId) {
          _queuedRefreshOrderId = null;
          _queuedClearIfPaid = false;
          _refreshOrderDebounceTimer?.cancel();
        }
      }
      if (stillSelected()) {
        ++_loadGeneration;
        selectionToken = ++_openTableToken;
      }
      if (businessId == null || businessId.isEmpty) return;
      try {
        await _offlinePos.markOrderClosedLocally(
          businessId: businessId,
          orderId: orderId,
        );
      } catch (e) {
        debugPrint('cancelCurrentOrder: no se marcó cerrada localmente: $e');
      }
    }

    // Local IDs are not valid for the online close RPC. Route them through
    // the durable queue even if the connectivity probe still reports online.
    if (orderId.startsWith('local-order-')) {
      await enqueueVoidOffline();
      await forgetVoidedOrder();
      clearCancelledSelection();
      return;
    }

    // Caso 1: ya estamos offline declarado (o el caller pidió no anular en
    // línea). No intentamos online, encolamos directamente. (La audit note
    // igual NO se persiste en server — ver limitación en el case
    // 'void_order' del _replayAction.)
    if (queueVoid || !_connectivity.isConnected) {
      await enqueueVoidOffline();
      await forgetVoidedOrder();
      clearCancelledSelection();
      return;
    }

    // Caso 2: online declarado. Intentamos persistir audit note + close. Si
    // cualquiera falla por red mid-call, encolamos void_order como fallback
    // y resetamos UI igual.
    try {
      if (trimmedReason != null && trimmedReason.isNotEmpty) {
        try {
          final actor = actorAtCancellation.isEmpty
              ? 'Usuario'
              : actorAtCancellation;
          final auditLine =
              '[ANULACION][$cancellationStamp] $actor: $trimmedReason';
          final nextNote =
              noteAtCancellation == null || noteAtCancellation.isEmpty
              ? auditLine
              : '$noteAtCancellation\n$auditLine';
          await ref
              .read(salesRepositoryProvider)
              .updateSessionNote(
                sessionId: cancelledSessionId,
                note: nextNote,
                businessId: businessId,
              );
          if (stillSelected()) state = state.copyWith(sessionNote: nextNote);
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
      if (voidOnlyIfUnpaid) {
        // Anulación automática: el servidor comprueba y anula en una sola
        // transacción, con la orden bloqueada como en el cobro. Sin la
        // migración 20261009_0007 (PGRST202), el cierre de siempre.
        String? guarded;
        try {
          guarded = await ref
              .read(salesRepositoryProvider)
              .voidOrderIfUnpaid(orderId);
        } on PostgrestException catch (e) {
          if (e.code != 'PGRST202') rethrow;
        }
        if (guarded == null) {
          await ref
              .read(salesRepositoryProvider)
              .closeOrder(orderId: orderId, status: 'void');
        } else if (guarded == 'already_closed' || guarded == 'has_payments') {
          throw _OrderNotVoidable(guarded);
        }
      } else {
        await ref
            .read(salesRepositoryProvider)
            .closeOrder(orderId: orderId, status: 'void');
      }

      // Fix #1: espejo de la anulación al op-log del Hub → libera la mesa en
      // las cajas cliente.
      _mirrorHostMutationToHub({'type': 'void_order', 'order_id': orderId});
    } catch (e) {
      if (!isNetworkError(e)) rethrow;
      debugPrint(
        'cancelCurrentOrder: closeOrder online falló por red, encolando '
        'void_order para sync posterior. $e',
      );
      await enqueueVoidOffline();
    }

    await forgetVoidedOrder();
    clearCancelledSelection();
  }

  /// Confirma la orden enviándola a cocina. Retorna el [KitchenSendResult]
  /// para que la UI pueda mostrar snackbar amigable cuando alguna área
  /// escala al worker. Retorna `null` si no había orden o si la orden
  /// fue al path local (offline / orden local sin sincronizar).
  Future<KitchenSendResult?> confirmOrder({
    String? tableName,
    String? waiterName,
    // Área con 2+ impresoras: pregunta en cuál imprime este dispositivo
    // (como la precuenta). [forceChoosePrinter] = mantener presionado.
    KitchenAreaPrinterChooser? choosePrinter,
    bool forceChoosePrinter = false,
  }) async {
    if (!operatorHasPermissionRef(ref, 'ventas.orden.enviar_cocina')) {
      state = state.copyWith(
        error: 'No tienes permiso para enviar órdenes a cocina.',
      );
      return null;
    }
    final sentState = state;
    final orderId = sentState.order?.id;
    if (orderId == null) return null;
    final sentBusinessId = _activeBusinessId;
    final sentOrigin = sentState.origin;
    final sentTableId = _activeTableId;
    final sentSlotId = _resolvePersistSlotId(sentOrigin ?? 'table', sentTableId);
    bool stillSelected() =>
        _activeBusinessId == sentBusinessId && state.order?.id == orderId;
    // Si el envío online ya preguntó y luego cayó al camino local, no se
    // vuelve a preguntar: la elección quedó guardada.
    var askedForPrinter = false;
    final KitchenAreaPrinterChooser? chooser = choosePrinter == null
        ? null
        : (areaName, printers, current) {
            askedForPrinter = true;
            return choosePrinter(areaName, printers, current);
          };
    // Las líneas de esta ronda quedan sin edición desde que se capturan hasta
    // marcarlas enviadas (ver _localKitchenPrints), también mientras se
    // intenta por la nube: si la red cae en ese intento, la comanda sale por
    // la LAN con [sentState], y una cantidad cambiada durante la espera
    // quedaba «por confirmar» y el siguiente «Enviar» la reimprimía entera.
    // El intento por la nube tiene tope: cada petición corta a los 30 s
    // (ResilientHttpClient) y, ya detectada la caída, las demás fallan al
    // instante.
    final printing = (
      businessId: sentBusinessId ?? '',
      itemIds: {
        for (final item in sentState.items)
          if (item.status == 'draft' || item.status == 'open') item.id,
      },
      renamedIds: <String, String>{},
    );
    _localKitchenPrints.add(printing);
    // El camino local se devuelve sin await (sus errores no pasan por el
    // catch de abajo): se queda con el bloqueo y lo suelta al imprimir.
    var lockHandedToLan = false;
    // No ponemos loading: true aquí para evitar el parpadeo de la pantalla completa.
    // El usuario verá el item aparecer inmediatamente cuando _loadOrderDetail termine.
    // state = state.copyWith(loading: true);
    try {
      final session = ref.read(sessionProvider);
      final businessId = sentBusinessId;
      if (businessId == null || businessId.isEmpty) {
        throw Exception(
          'No se pudo resolver el negocio activo para imprimir la comanda.',
        );
      }
      if (sentOrigin == null) throw StateError('Orden sin origen.');
      await _offlinePos.saveSnapshot(
        businessId: businessId,
        slotId: sentSlotId,
        origin: sentOrigin,
        tableId: sentTableId,
        state: sentState,
      );

      // Camino local: imprime directo por la LAN y encola el envío para el
      // replay. Es el de siempre sin red; ahora también el de la ventana en
      // que la red ya murió pero el detector aún no lo admite.
      Future<KitchenSendResult> sendLocallyUnguarded() async {
        // sendLocalOrderToKitchen ya encola su propio 'confirm_local_order'
        // (con printed_areas para que el replay marque sin reimprimir). Antes
        // aquí se encolaba ADEMÁS un 'send_to_kitchen' → dos replays por
        // envío: el primero reimprimía la comanda entera online y el segundo
        // moría con "No hay items nuevos" (op veneno, caso 2026-07-25).
        final localResult = await ref
            .read(printingServiceProvider)
            .sendLocalOrderToKitchen(
              businessId: businessId,
              localState: sentState,
              tableName:
                  tableName ?? (sentOrigin == 'table' ? 'MESA' : 'LOCAL'),
              waiterName:
                  waiterName ?? await _localOpenerName(businessId, orderId),
              businessName: session.activeBusinessName,
              choosePrinter: chooser,
              forceChoosePrinter: forceChoosePrinter && !askedForPrinter,
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
        final sentQuantities = <String, double>{};
        for (final item in sentState.items) {
          if (item.status != 'draft' && item.status != 'open') continue;
          sentQuantities[item.id] = item.quantity;
          final mapped = await _offlinePos.mappedRemoteItemId(
            businessId: businessId,
            localItemId: item.id,
          );
          if (mapped != null) sentQuantities[mapped] = item.quantity;
        }
        // Una línea temporal cuya alta en línea terminó durante la impresión
        // ya está en pantalla con su id real: se busca al aplicar la marca,
        // no antes (el cambio puede llegar en cualquier await de arriba).
        double? sentQuantity(String itemId) {
          final direct = sentQuantities[itemId];
          if (direct != null) return direct;
          for (final renamed in printing.renamedIds.entries) {
            if (renamed.value == itemId) return sentQuantities[renamed.key];
          }
          return null;
        }

        CurrentOrderState markSent(CurrentOrderState target) => target.copyWith(
          items: target.items.map((item) {
            if (sentQuantity(item.id) == item.quantity &&
                (item.status == 'draft' || item.status == 'open')) {
              return item.copyWith(status: 'pending');
            }
            return item;
          }).toList(growable: false),
          loading: false,
          error: localResult.pendingAreas.isEmpty
              ? 'Comanda enviada localmente. Pendiente de sincronizar.'
              : 'Comanda guardada. Pendiente de imprimir en: '
                    '${localResult.pendingAreas.join(", ")}. '
                    'Comprueba la impresora y la conexión local.',
        );
        // La sync pudo subir la orden durante la impresión y recargarla con
        // su UUID remoto: sigue siendo la MISMA cuenta. Comparar solo el id
        // crudo dejaba la ronda impresa en "POR CONFIRMAR" y un segundo
        // «Enviar» la reimprimía entera por la nube.
        final mappedOrderId = orderId.startsWith('local-order-')
            ? await _offlinePos.mappedRemoteOrderId(
                businessId: businessId,
                localOrderId: orderId,
              )
            : null;
        final visibleOrderId = state.order?.id;
        final sameAccount =
            _activeBusinessId == sentBusinessId &&
            visibleOrderId != null &&
            (visibleOrderId == orderId ||
                (mappedOrderId != null && visibleOrderId == mappedOrderId));
        if (sameAccount) {
          // Una recarga en vuelo trae el estado previo a esta ronda (ítems en
          // draft): se descarta para que no pise la marca de enviados.
          ++_loadGeneration;
          state = markSent(state);
          await _persistCurrentState(localOnly: true);
        } else {
          await _offlinePos.updateSnapshot(
            businessId: businessId,
            slotId: sentSlotId,
            origin: sentOrigin,
            tableId: sentTableId,
            fallbackState: sentState,
            update: markSent,
          );
        }
        return KitchenSendResult(
          dispatchIds: localResult.dispatchIds,
          directAreas: localResult.dispatchIds.keys.toList(growable: false),
          escalatedAreas: const [],
          pendingPrintAreas: localResult.pendingAreas,
        );
      }

      Future<KitchenSendResult> sendLocally() async {
        lockHandedToLan = true;
        try {
          return await sendLocallyUnguarded();
        } finally {
          _localKitchenPrints.remove(printing);
        }
      }

      // Si hay ítems temporales, el servidor aún NO tiene la ronda completa.
      // Enviar por nube aquí omitía los productos agregados durante el corte
      // (o decía "no hay items"), incluso tras recuperar la conexión.
      if (_preferLocalOperations ||
          orderId.startsWith('local-order-') ||
          sentState.items.any((item) => item.id.startsWith('tmp_'))) {
        return sendLocally();
      }

      // Ítems que ESTE device ya sabe enviados (p.ej. impresos por el camino
      // local/offline con replay aún pendiente): el server puede tenerlos
      // todavía en draft — sin excluirlos, la comanda saldría ENTERA
      // (rondas viejas + nuevas). Caso real Android 2026-07-25.
      final locallySentIds = sentState.items
          .where((i) => i.status != 'draft' && i.status != 'open')
          .map((i) => i.id)
          .toSet();

      final KitchenSendResult result;
      try {
        result = await ref
            .read(printingServiceProvider)
            .sendOrderToKitchen(
              orderId: orderId,
              businessId: businessId,
              fallbackTableName: tableName,
              fallbackWaiterName:
                  waiterName ?? await _localOpenerName(businessId, orderId),
              excludeItemIds: locallySentIds,
              choosePrinter: chooser,
              forceChoosePrinter: forceChoosePrinter,
            );
      } on KitchenSendNetworkException catch (e) {
        // Sin papel impreso todavía: repetir por el camino local no duplica
        // la comanda. Antes esto terminaba en un snackbar rojo y la comanda
        // no salía ni se encolaba.
        debugPrint('confirmOrder: sin red antes de imprimir, envío local ($e)');
        _recordTransportFailure();
        return sendLocally();
      }
      if (stillSelected()) refreshOrder();
      return result;
    } catch (e) {
      if (stillSelected()) {
        state = state.copyWith(loading: false, error: e.toString());
      }
      rethrow;
    } finally {
      if (!lockHandedToLan) _localKitchenPrints.remove(printing);
    }
  }

  /// Fee de delivery propio (cargo EXENTO sumado al total después de
  /// impuestos). Fija `orders.delivery_fee` y recomputa el total.
  /// Online: RPC `fn_set_delivery_fee` + reload autoritativo. Offline:
  /// encola `set_delivery_fee` y refleja el fee/total localmente (el replay
  /// llama al RPC al reconectar). Ver docs/PRD_DELIVERY_FEE_PROPIO.md.
  Future<void> setDeliveryFee(double amount) async {
    final order = state.order;
    if (order == null) return;
    final orderId = order.id;
    final businessId = _activeBusinessId;
    final origin = state.origin;
    final tableId = _activeTableId;
    final slotId = _resolvePersistSlotId(origin ?? 'delivery', tableId);
    final clamped = amount < 0 ? 0.0 : amount;

    // Optimista: reflejar el fee y el nuevo total localmente (clave offline,
    // para que el cobro use el total correcto sin esperar al server).
    final withFee = order.copyWith(deliveryFee: clamped);
    final newTotal = summarizeOrderPricing(
      withFee,
      state.items,
      forcedOrigin: state.origin,
    ).total;
    state = state.copyWith(order: withFee.copyWith(total: newTotal));
    final feeSnapshot = state;
    if (businessId != null && businessId.isNotEmpty && origin != null) {
      await _offlinePos.saveSnapshot(
        businessId: businessId,
        slotId: slotId,
        origin: origin,
        tableId: tableId,
        state: feeSnapshot,
        localOnly: !_connectivity.isConnected || orderId.startsWith('local-order-'),
      );
    }

    if (!_connectivity.isConnected || orderId.startsWith('local-order-')) {
      if (businessId != null && businessId.isNotEmpty) {
        await _offlinePos.enqueueAction(
          businessId: businessId,
          action: {
            'type': 'set_delivery_fee',
            'order_id': orderId,
            'amount': clamped,
            'origin': origin,
            'table_id': tableId,
            'slot_id': slotId,
          },
        );
      }
      return;
    }

    // Online: el backend fija el fee y recomputa el total; recargamos para
    // tener los totales autoritativos (y que la factura/NCF cuadren).
    await ref
        .read(salesRepositoryProvider)
        .setDeliveryFee(orderId: orderId, amount: clamped);
    if (_activeBusinessId == businessId && state.order?.id == orderId) {
      await reloadOrderNow();
    }
  }

  /// VENTA RÁPIDA: imprime la comanda de cocina a partir de un SNAPSHOT de
  /// ítems capturado ANTES de cobrar. Necesario porque al pagar los ítems
  /// quedan `paid` y el envío normal (que re-lee de BD y filtra draft/open)
  /// los descartaría. Best-effort: nunca lanza (no debe tumbar el cobro).
  /// Solo imprime la comanda; no toca estados en BD (la orden ya está pagada).
  Future<void> fireQuickSaleKitchenSnapshot({
    required Order order,
    required List<OrderItem> items,
    String tableName = 'Venta Rápida',
    // Cliente de la venta: la comanda lo imprime para que cocina sepa a quién
    // llamar. Sin él salía solo "MESA: Venta Rápida".
    String? customerName,
  }) async {
    try {
      final session = ref.read(sessionProvider);
      final businessId = session.activeBusinessId;
      if (businessId == null || businessId.isEmpty) return;
      // Forzamos `draft` para que sendLocalOrderToKitchen (filtra draft/open)
      // imprima TODOS los ítems del snapshot.
      final snapItems = items
          .where((i) => i.status != 'void')
          .map((i) => i.copyWith(status: 'draft'))
          .toList(growable: false);
      if (snapItems.isEmpty) return;
      final snapState = CurrentOrderState(
        order: order,
        items: snapItems,
        origin: 'quick',
        customerName: customerName,
      );
      await ref
          .read(printingServiceProvider)
          .sendLocalOrderToKitchen(
            businessId: businessId,
            localState: snapState,
            tableName: tableName,
            // Los ítems ya traen a quien los digitó; esto es solo para los
            // que no. Nunca la cuenta logueada (ver _localOpenerName).
            waiterName: await _localOpenerName(businessId, order.id),
            businessName: session.activeBusinessName,
          );
    } catch (e) {
      debugPrint('Venta rápida: no se pudo enviar la comanda a cocina: $e');
    }
  }

  Future<void> reprintKitchenTicket({
    required String orderId,
    List<OrderItem>? items,
  }) async {
    if (!operatorHasPermissionRef(ref, 'kds.reimprimir_comanda')) {
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

  /// Recarga la orden actual desde el server de forma INMEDIATA y awaiteada
  /// (sin el debounce de [refreshOrder]). Se llama justo antes de imprimir la
  /// precuenta/factura para que el papel refleje el estado autoritativo del
  /// server, sin depender de que Realtime haya entregado cada evento — el
  /// canal puede perder cambios si se cayó/reconectó o si otra caja agregó
  /// ítems (caso real: precuenta sin los ítems agregados después).
  ///
  /// No-op si no hay orden, es una orden local (sin server todavía) o no hay
  /// internet: offline en una sola caja ya es fresco; la frescura multi-caja
  /// sin internet la da el Hub/LAN (F3). Tolerante: un fallo de recarga no
  /// debe trabar la impresión (el caller decide), así que captura y sigue.
  /// Después de una carga de [orderId] que tomó [generation]: si algo la
  /// reemplazó antes de escribir (el reintento de la confirmación al retomar
  /// una Venta Rápida, una recarga de Realtime, la marca de comanda enviada),
  /// quien lee el estado enseguida (Pre-Cuenta, Cobrar, subir una venta local
  /// para cobrarla) vería lo pintado. Sigue la carga vigente de esa cuenta o,
  /// si no hay otra, repite la suya con [reload], hasta que haya datos del
  /// servidor de esa generación en adelante. Con tope de vueltas y de tiempo;
  /// nunca lanza.
  Future<void> _settleOrderLoad({
    required String orderId,
    required int generation,
    required int token,
    required Future<void> Function() reload,
  }) async {
    var mine = generation;
    final deadline = DateTime.now().add(_reloadFollowBudget);
    try {
      for (var i = 0; i < 3; i++) {
        final remaining = deadline.difference(DateTime.now());
        if (_freshLoadGeneration >= mine ||
            _loadGeneration == mine ||
            token != _openTableToken ||
            remaining <= Duration.zero) {
          return;
        }
        final newer = _latestOrderLoad;
        if (newer != null &&
            newer.generation > mine &&
            newer.orderId == orderId) {
          mine = newer.generation;
          await newer.done.timeout(remaining);
        } else {
          final again = reload();
          mine = _loadGeneration;
          await again.timeout(remaining);
        }
      }
    } catch (e) {
      debugPrint('_settleOrderLoad($orderId): $e');
    }
  }

  Future<void> reloadOrderNow() async {
    final orderId = state.order?.id;
    if (orderId == null || orderId.startsWith('local-order-')) return;
    if (!_connectivity.isConnected) return;
    _refreshOrderDebounceTimer?.cancel();
    final token = _openTableToken;
    try {
      Future<void> load() => _loadOrderDetail(
        orderId,
        selectionToken: token,
        reloadOf: orderId,
        caller: 'reloadOrderNow',
      );
      final first = load();
      // _loadOrderDetail toma su generación antes de su primer await.
      final generation = _loadGeneration;
      await first;
      await _settleOrderLoad(
        orderId: orderId,
        generation: generation,
        token: token,
        reload: load,
      );
    } catch (e) {
      debugPrint('reloadOrderNow falló (se imprime con el estado actual): $e');
    }
  }

  String? _promotingLocalOrderId;

  /// True mientras [promoteLocalOrderForPayment] sube una venta: el segundo
  /// toque de "Pagar" se ignora en vez de abrir un cobro offline en paralelo.
  bool get isPromotingLocalOrder => _promotingLocalOrderId != null;

  /// Tope de la espera de [promoteLocalOrderForPayment]. La pasada forzada
  /// espera la que esté en curso y luego corre la suya: tras un corte largo
  /// eso podía tardar minutos con el cliente esperando en el mostrador.
  @visibleForTesting
  static Duration promoteSyncBudget = const Duration(seconds: 30);

  /// Lo que muestra el banner de ventas mientras se sube la venta para
  /// cobrarla: el toque de "Pagar" no queda en silencio.
  static const _promotingSyncStatus = 'Subiendo la venta para cobrarla...';
  static const _syncingStatus = 'Sincronizando operaciones offline...';

  /// Venta abierta como borrador local (`local-order-…`) durante un bajón de
  /// red —venta rápida la abre así también en los 20 s posteriores a una
  /// lectura lenta—. Su cobro siempre iba por la cola offline y lo que salía
  /// era la PRECUENTA, aunque al pagar ya hubiera internet. Si hay conexión,
  /// la sube ANTES del cobro (la misma sincronización del botón "Sync ahora")
  /// y deja cargada la orden real, para cobrarla en línea con su comprobante.
  ///
  /// Devuelve el id real, o null si la venta sigue local (sin red, Hub, o algo
  /// de ESTA venta no subió): en ese caso el cobro sigue el camino offline de
  /// siempre. Cobrar la orden real sin todos sus ítems la cerraría con menos.
  Future<String?> promoteLocalOrderForPayment(String localOrderId) async {
    if (!localOrderId.startsWith('local-order-')) return null;
    if (state.order?.id != localOrderId) return null;
    if (!_connectivity.isConnected || isPromotingLocalOrder) return null;
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return null;

    _promotingLocalOrderId = localOrderId;
    try {
      // Indicador visible (banner de ventas y chip de la orden) mientras sube.
      await _refreshOfflineMonitor();
      // Una sola espera, con tope. force ya espera la pasada en curso (que
      // puede estar subiendo esta misma venta) y luego corre la suya. Si el
      // tope vence, se cobra por el camino offline de siempre: la pasada
      // sigue en segundo plano y el cobro encolado sube detrás de los ítems
      // de esta venta, contra su mapping. No se pierde ni se duplica nada.
      await syncPendingOfflineActions(
        force: true,
      ).timeout(promoteSyncBudget, onTimeout: () {});

      final remoteId = await _offlinePos.mappedRemoteOrderId(
        businessId: businessId,
        localOrderId: localOrderId,
      );
      if (remoteId == null) return null;
      final leftovers = (await _offlinePos.unsettledActions(
        businessId,
      )).any((action) => action['order_id'] == localOrderId);
      if (leftovers) return null;

      // El sync pudo cargar otra orden (`lastMappedOrderId` es la última que
      // subió, no necesariamente esta) o el cajero pudo cambiar de venta.
      final current = state.order?.id;
      if (current != localOrderId && current != remoteId) return null;
      final token = _openTableToken;
      final loadOrigin = state.origin;
      Future<void> load() => _loadOrderDetail(
        remoteId,
        selectionToken: token,
        reloadOf: current,
        origin: loadOrigin,
        caller: 'promoteLocalOrderForPayment',
      );
      final first = load();
      final generation = _loadGeneration;
      await first;
      // Reemplazada por otra carga (p. ej. Realtime tras subirla): sin esto
      // la venta seguía local en pantalla y se cobraba por la cola, con
      // precuenta en vez de factura.
      await _settleOrderLoad(
        orderId: remoteId,
        generation: generation,
        token: token,
        reload: load,
      );
      if (state.order?.id != remoteId) return null;

      final slotId = _activeRetailSlotId;
      if (_isRetail && slotId != null) {
        ref.read(retailCartsProvider.notifier).setOrderId(slotId, remoteId);
        await _persistRetailCartsIndex();
      }
      return remoteId;
    } catch (e) {
      debugPrint('promoteLocalOrderForPayment: la venta sigue local: $e');
      return null;
    } finally {
      _promotingLocalOrderId = null;
      // Quita el indicador; si la pasada sigue en segundo plano, el banner
      // vuelve a decir que sincroniza.
      if (ref.mounted) {
        try {
          await _refreshOfflineMonitor(
            syncStatus: _syncInFlight ? _syncingStatus : '',
          );
        } catch (e) {
          debugPrint('promoteLocalOrderForPayment: banner sin refrescar: $e');
        }
      }
    }
  }

  /// Sube la cola offline del negocio activo.
  ///
  /// [force] = pedido explícito del cajero ("Sincronizar ahora", badge,
  /// banner, reintentar dead, cobro de una venta local): reintenta las dead,
  /// ignora el backoff, muestra su resultado (snackbar del shell) y, si llega
  /// con otra pasada en curso, espera a una pasada forzada propia.
  ///
  /// Sin [force] es una pasada automática (uplink del shell, reconexión):
  /// silenciosa, solo actualiza los contadores del badge/banner. Si llega con
  /// otra pasada en curso no hace nada (esa ya hace el trabajo).
  ///
  /// La venta activa se recarga solo si la pasada completó o concilió algo,
  /// o si [reloadActiveOrder] lo pide (reconexión).
  Future<void> syncPendingOfflineActions({
    bool force = false,
    bool reloadActiveOrder = false,
  }) async {
    if (_syncInFlight) {
      if (!force) return;
      // promoteLocalOrderForPayment, _retryDead y el botón leen la cola justo
      // después de esperar este Future: debe terminar cuando la pasada que
      // pidieron haya corrido, no antes.
      return (_forcedSyncRerun ??= Completer<void>()).future;
    }
    final automatic = !force;
    final businessId = _activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;

    // Si el caller forzo el sync (boton "Sync ahora" del banner), refrescar
    // el estado de reachability AHORA en vez de esperar al proximo poll de
    // 30s. El caso comun: Supabase tuvo blips → _reachable quedo en false
    // → el wifi esta perfecto pero el banner sigue "Sync pausada" hasta el
    // proximo poll. Con esto el boton hace lo que el cajero espera.
    if (force && !_connectivity.isConnected) {
      await _connectivity.forceReachabilityCheck();
      // Otra pasada pudo arrancar durante la espera: esperar la nuestra
      // detrás de ella en vez de correr dos a la vez.
      if (_syncInFlight) {
        return (_forcedSyncRerun ??= Completer<void>()).future;
      }
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
      syncStatus: _syncingStatus,
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

      // El negocio puede cambiar mientras los RPC terminan. La cola del
      // negocio anterior sigue guardada, pero no modifica la venta visible.
      if (_activeBusinessId != businessId) return;

      // Publicamos el resultado al provider central para que el badge
      // del topbar refresque su count y el shell muestre la notificación
      // post-sync con detalle (pagos completados, NCFs emitidos, etc.).
      // Una pasada automática solo mueve los contadores: ningún snackbar.
      ref
          .read(offlineQueueStatusProvider.notifier)
          .publishSyncResult(result, automatic: automatic);

      // F3b-3c: si este dispositivo es el Hub Local, drena también su op-log
      // a Supabase (las ops que recibió de otras cajas mientras no había red).
      // En los dispositivos que NO son Hub el op-log está vacío → no-op. Gated
      // por kHubModeEnabled; best-effort (no rompe el sync de la cola propia).
      var hubLogCompleted = 0;
      if (kHubModeEnabled) {
        try {
          final hubLog = await _offlinePos.syncHubOpLog(
            businessId: businessId,
            salesRepository: ref.read(salesRepositoryProvider),
            printingService: ref.read(printingServiceProvider),
            inventoryRepository: ref.read(inventoryRepositoryProvider),
            cashierRepository: ref.read(cashierRepositoryProvider),
          );
          hubLogCompleted = hubLog.completed;
        } catch (e) {
          debugPrint('[SalesVM] syncHubOpLog (drenado del Hub) falló: $e');
        }
      }
      if (_activeBusinessId != businessId) return;

      // Clientes elegidos sin red: pasan al id real de su orden y se guardan
      // en el servidor. Antes de las recargas de abajo, para que estas ya
      // encuentren el cliente bajo el id nuevo.
      if (_pendingCustomers.isNotEmpty) {
        try {
          await _remapAndPushPendingCustomers(businessId);
        } catch (e) {
          debugPrint('[SalesVM] clientes pendientes: $e');
        }
      }

      // Sin nada completado ni conciliado, esta pasada no cambió la venta
      // activa en el servidor: recargarla solo reiniciaba la generación de
      // carga y cancelaba el refresh de Realtime en cada pasada.
      if (reloadActiveOrder ||
          result.completed > 0 ||
          result.reconciled > 0 ||
          hubLogCompleted > 0) {
        await _refreshActiveOrderAfterSync(businessId);
        if (_activeBusinessId != businessId) return;
      }

      // Refrescar el salón cuando el sync aplicó cambios: las mesas recién
      // creadas en server ya no dependen del overlay local y las anuladas
      // deben soltarse. Antes el grid quedaba stale hasta que Realtime o el
      // timer de 10s de la zona visible lo refrescara.
      if (result.completed > 0) {
        try {
          unawaited(ref.read(byZoneVmProvider.notifier).load(businessId));
        } catch (_) {
          // best-effort: el refresh del salón nunca rompe el sync.
        }
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

      // El aviso de error solo para una pasada pedida por el cajero; la
      // automática deja el detalle en el banner (syncStatus) y en la cola.
      state = state.copyWith(
        error: !automatic && result.hasFailures ? syncMessage : state.error,
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
      if (_activeBusinessId != businessId) return;
      if (!automatic) {
        state = state.copyWith(error: 'Error sincronizando offline: $e');
      }
      await _refreshOfflineMonitor(
        syncStatus: 'Error sincronizando offline.',
        syncInFlight: false,
      );
    } finally {
      _syncInFlight = false;
      // Antes de cualquier await: el pedido force que esperaba arranca su
      // pasada ya, sin que otra se cuele, y su Future termina con ella.
      final rerun = _forcedSyncRerun;
      _forcedSyncRerun = null;
      if (rerun != null) {
        if (ref.mounted) {
          unawaited(
            syncPendingOfflineActions(force: true).then<void>(
              (_) => rerun.complete(),
              onError: rerun.completeError,
            ),
          );
        } else {
          rerun.complete();
        }
      }
      // Sin syncInFlight explícito: si arrancó la pasada pedida, el banner
      // debe seguir mostrando que hay una en curso.
      await _refreshOfflineMonitor();
    }
  }

  Future<void> _refreshActiveOrderAfterSync(String businessId) async {
    final activeOrderId = state.order?.id;
    final origin = state.origin;
    if (activeOrderId == null || _activeBusinessId != businessId) return;
    final mappedId = await _offlinePos.mappedRemoteOrderId(
      businessId: businessId,
      localOrderId: activeOrderId,
    );
    final resolvedId = mappedId ?? activeOrderId;
    final pending = await _offlinePos.hasUnsettledOrderActions(
      businessId: businessId,
      orderId: activeOrderId,
    );
    if (_activeBusinessId != businessId || state.order?.id != activeOrderId) {
      return;
    }
    if (pending || resolvedId.startsWith('local-order-')) {
      // Conservar TODO el contenido local si solo subió parte de la venta.
      // Al completarse, la próxima pasada sí carga el bundle del servidor.
      return;
    }
    if (origin == 'quick' && _activeRetailSlotId != null) {
      ref
          .read(retailCartsProvider.notifier)
          .setOrderId(_activeRetailSlotId!, resolvedId);
      await _persistRetailCartsIndex();
      if (_activeBusinessId != businessId || state.order?.id != activeOrderId) {
        return;
      }
    }
    // Recarga de la cuenta que estaba en pantalla al empezar (o su id real
    // tras subir): si el cajero ya pasó a otra, no arranca.
    await _loadOrderDetail(
      resolvedId,
      selectionToken: _openTableToken,
      reloadOf: activeOrderId,
      origin: origin,
      caller: 'syncOffline:active',
    );
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
      // Una sola recarga por flush. Si llegan ecos de Realtime DURANTE la
      // recarga, el `finally` los re-agenda con debounce (colapsa la ráfaga en
      // UNA recarga de cola) en vez de re-bajar el bundle inmediato otra vez.
      if (_queuedRefreshOrderId != null) {
        final orderId = _queuedRefreshOrderId!;
        final clearIfPaid = _queuedClearIfPaid;

        _queuedRefreshOrderId = null;
        _queuedClearIfPaid = false;

        // La pantalla ya pasó a OTRA orden (típico: venta rápida cobrada →
        // openQuick abrió la siguiente): recargar la vieja es trabajo muerto
        // y, si la carga falla, su recovery vaciaba la orden NUEVA. Sin red
        // pasaba siempre, porque la venta local nueva abre al instante.
        // Sin cuenta en pantalla tampoco hay nada que refrescar: cargar aquí
        // metía la cuenta anterior en la pantalla que se está abriendo (venta
        // rápida/manual o la mesa siguiente), con su origen y su respaldo.
        final current = state.order?.id;
        if (current != orderId) return;

        await _loadOrderDetail(
          orderId,
          selectionToken: _openTableToken,
          reloadOf: orderId,
          caller: 'scheduledRefresh',
        );
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
        // Re-agendar con DEBOUNCE (no inmediato) para colapsar los ecos que
        // llegaron durante la recarga en una sola recarga de cola.
        _scheduleOrderRefresh(
          _queuedRefreshOrderId!,
          clearIfPaid: _queuedClearIfPaid,
        );
      }
    }
  }

  void selectCheck(String? checkId) {
    state = state.copyWith(
      selectedCheckId: checkId,
      clearSelectedCheck: checkId == null,
    );
  }

  /// Carga [orderId] y la escribe en pantalla y en su respaldo.
  ///
  /// Regla central: solo escribe para la selección vigente.
  /// [selectionToken] es el `_openTableToken` de la selección que pidió la
  /// carga (la apertura que la lanza, o la cuenta en pantalla cuando el caller
  /// la capturó antes de su await). [reloadOf] marca una RECARGA: el id que
  /// debe seguir en pantalla (el local cuyo remoto es [orderId], o el mismo).
  /// Si la selección ya cambió, la carga ni arranca (no toma generación, así
  /// que tampoco reemplaza la carga de la pantalla nueva) ni escribe estado
  /// ni el respaldo 'quick'/'manual'.
  Future<void> _loadOrderDetail(
    String orderId, {
    required int selectionToken,
    String? reloadOf,
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
    _PreloadedOrderBundle? preloadedBundle,
  }) {
    final generationBefore = _loadGeneration;
    final load = _runOrderDetailLoad(
      orderId,
      selectionToken: selectionToken,
      reloadOf: reloadOf,
      origin: origin,
      tableId: tableId,
      caller: caller,
      preloadedBundle: preloadedBundle,
    );
    // _runOrderDetailLoad toma su generación antes de su primer await.
    if (_loadGeneration != generationBefore) {
      _latestOrderLoad = (
        generation: _loadGeneration,
        orderId: orderId,
        done: load,
      );
    }
    return load;
  }

  Future<void> _runOrderDetailLoad(
    String orderId, {
    required int selectionToken,
    String? reloadOf,
    String? origin,
    String? tableId,
    required String caller,
    _PreloadedOrderBundle? preloadedBundle,
  }) async {
    // Reclama esta carga como la vigente. Cualquier `_loadOrderDetail` que
    // arranque después tendrá una generación mayor; al escribir el state esta
    // carga comprueba que `myGeneration == _loadGeneration` y, si no, se
    // descarta para no pisar el resultado de una carga más fresca (evita que un
    // reload stale en vuelo borre el item recién agregado — ver `_loadGeneration`).
    //
    // Antes, una recarga tardía de la cuenta anterior (cliente asignado u
    // oferta que respondió después de pasar a Venta Rápida/Manual) tomaba
    // generación, reemplazaba la apertura y escribía la mesa A con el origen
    // de la pantalla nueva: quedaba guardada como la venta de este equipo.
    bool selectionCurrent() =>
        selectionToken == _openTableToken &&
        (reloadOf == null ||
            state.order?.id == reloadOf ||
            state.order?.id == orderId);
    if (!selectionCurrent()) return;
    final myGeneration = ++_loadGeneration;
    final loadBusinessId = _activeBusinessId;
    bool superseded() =>
        myGeneration != _loadGeneration ||
        _activeBusinessId != loadBusinessId ||
        !selectionCurrent();
    final previousOrderId = state.order?.id;
    final previousOrigin = state.origin;
    final sameLogicalOrder =
        previousOrderId == orderId ||
        (previousOrderId != null &&
            loadBusinessId != null &&
            await _offlinePos.mappedRemoteOrderId(
                  businessId: loadBusinessId,
                  localOrderId: previousOrderId,
                ) ==
                orderId);
    // Cambios de ESTA cuenta aún en la cola (pendientes, fallidos o muertos):
    // lo de pantalla es la verdad local. Antes se cortaba aquí sin leer, y una
    // operación muerta dejaba la cuenta abierta para siempre aunque otro equipo
    // ya la hubiera cobrado o anulado. Ahora se lee el servidor y solo se
    // adopta un cierre definitivo (ver abajo); si no, se conserva lo local.
    final queueBusinessId = previousOrderId == orderId ? loadBusinessId : null;
    // Contador de la cola ANTES de leerla: si no cambia mientras se lee el
    // servidor, esta lectura sigue valiendo y no se repite (ver abajo).
    final queueRevisionAtStart = queueBusinessId == null
        ? 0
        : _offlinePos.queueRevision(queueBusinessId);
    final queuedAtStart = queueBusinessId == null
        ? null
        : await _offlinePos.orderQueueStatus(
            businessId: queueBusinessId,
            orderId: orderId,
          );
    final keepLocalContent = queuedAtStart?.unsettled ?? false;
    // Sin servidor que consultar (borrador local o sin red): como antes.
    if (keepLocalContent &&
        (orderId.startsWith('local-order-') ||
            (preloadedBundle == null && _preferLocalOperations))) {
      if (!superseded()) {
        state = state.copyWith(loading: false);
      }
      return;
    }
    if (superseded()) return;
    final tableCacheHit = tableId != null && _tableCache.containsKey(tableId);
    // Cargas de mesa con tableId explícito fijan la mesa activa (clave del
    // snapshot offline). Las recargas sin tableId (realtime/refresh) heredan
    // la mesa activa vigente vía _persistCurrentState.
    if (tableId != null && origin == 'table') {
      _activeTableId = tableId;
    }
    if (state.order?.id != orderId) {
      _hasManualFiscalTypeSelection = false;
    }

    _refreshOrderDebounceTimer?.cancel();
    await _ensureBusinessTaxSettingsLoaded();
    await _ensureDefaultTakeoutLoaded();
    await _ensureBusinessFiscalSettingsLoaded();
    if (superseded()) return;
    final repo = ref.read(salesRepositoryProvider);
    Order? order;
    List<OrderItem> items = const [];
    List<OrderCheck> checks = const [];
    // `loadError` solo recoge fallos de la lectura de respaldo: protege la
    // pantalla. El del bundle va aparte; si el respaldo trae la cuenta
    // completa, sus datos se aplican y el error del bundle no cuenta.
    String? loadError;
    String? bundleError;
    String? customerId;
    String? customerName;
    String? sessionNote;

    var loadedByBundle = false;
    // Si algo falló por RED (no porque la orden no exista), lo que hay en
    // pantalla sigue siendo lo último bueno y NO se debe pisar. Ver abajo.
    var failedByNetwork = false;
    void noteFailure(Object e) {
      if (OfflinePosService.isTransportError(e)) failedByNetwork = true;
    }

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
        final bundle = await repo
            .getOrderBundle(orderId, businessId: loadBusinessId)
            .timeout(const Duration(seconds: 12));
        order = bundle.order;
        items = bundle.items;
        checks = bundle.checks;
        customerId = bundle.customerId;
        customerName = bundle.customerName;
        sessionNote = bundle.note;

        loadedByBundle = order != null;
      } catch (e) {
        noteFailure(e);
        bundleError = FriendlyError.from(e);
      }
    }

    // Si el bundle cayó por red, las 3 lecturas de respaldo van al mismo
    // servidor caído: solo sumarían espera.
    if (!loadedByBundle && !failedByNetwork) {
      final orderFuture = repo.getOrder(orderId, businessId: loadBusinessId);
      // Respaldo COMPLETO, con el mismo alcance que el bundle (ítems abiertos,
      // con extras y líneas de impuesto). Sin ellos la precuenta salía sin los
      // extras y con el desglose de impuestos adivinado. Si esas lecturas
      // fallan, getOrderItems lanza y la pantalla se conserva.
      final itemsFuture = repo.getOrderItems(
        orderId,
        includeModifiers: true,
        limit: _fallbackItemsLimit,
        onlyOpen: true,
        businessId: loadBusinessId,
      );
      final checksFuture = repo.getOrderChecks(
        orderId,
        businessId: loadBusinessId,
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
          // `ignore` como las de arriba: un rechazo temprano no sale como
          // error no controlado; el await de abajo igual lo recibe.
          customerFuture = repo.getSessionCustomer(
            order.sessionId,
            businessId: loadBusinessId,
          )..ignore();
        }
        checks = await checksFuture;
      } catch (e) {
        noteFailure(e);
        loadError ??= e.toString();
      }

      try {
        items = await itemsFuture;
        // Con el tope lleno puede haber más ítems: no es la cuenta completa.
        if (items.length >= _fallbackItemsLimit) {
          loadError ??=
              'La lectura de respaldo trajo $_fallbackItemsLimit productos o '
              'más (puede estar incompleta).';
        }
      } catch (e) {
        noteFailure(e);
        loadError ??= e.toString();
      }

      if (customerFuture != null) {
        try {
          final customer = await customerFuture;
          customerId = customer.customerId;
          customerName = customer.customerName;
          sessionNote = customer.note;
        } catch (e) {
          // Sin el cliente la recarga lo borraba de pantalla (y de la
          // precuenta): también cuenta como respaldo incompleto.
          noteFailure(e);
          loadError ??= e.toString();
        }
      }
    }

    // Recarga de la MISMA orden que falló por red (internet caído, o la
    // ventana en que el detector todavía no lo admite): se conserva lo que hay
    // en pantalla. Antes caía al recovery de abajo, que VACIABA la orden — la
    // mesa se veía vacía, la precuenta y la factura salían sin productos y
    // cada toque mostraba "Error… envíame una captura". También cubre la
    // carga parcial (orden sí, ítems no), que pintaba la orden sin ítems.
    if (superseded()) return;
    if (failedByNetwork &&
        sameLogicalOrder &&
        state.order?.id == previousOrderId) {
      if (myGeneration != _loadGeneration) return;
      debugPrint(
        '[SalesViewModel] _loadOrderDetail($caller): sin red, se conserva la '
        'orden en pantalla (${loadError ?? bundleError})',
      );
      unawaited(_connectivity.forceReachabilityCheck());
      if (state.loading) state = state.copyWith(loading: false);
      return;
    }

    // Respaldo incompleto (falló alguna de sus lecturas): nunca se aplica a
    // medias sobre la misma cuenta. Se conserva la pantalla con un aviso que
    // no bloquea; la próxima carga buena lo limpia.
    if (loadError != null &&
        sameLogicalOrder &&
        state.order?.id == previousOrderId) {
      if (myGeneration != _loadGeneration) return;
      state = state.copyWith(
        loading: false,
        error:
            'No se pudo actualizar la orden. Se conserva la venta guardada: $loadError',
      );
      return;
    }

    if (order == null && items.isEmpty) {
      // Una carga más nueva ya tomó el relevo: no limpiar el state ni loguear
      // un ERROR espurio con data vieja. La carga vigente decide el recovery.
      if (myGeneration != _loadGeneration) return;
      // Tails de IDs para que la captura del usuario sea autodiagnosticable
      // sin tener que pedirle logs. order=…<8> · business=…<8>.
      String tail(String? value) {
        if (value == null || value.isEmpty) return 'null';
        return value.length >= 8 ? value.substring(value.length - 8) : value;
      }

      final activeBusinessId = _activeBusinessId;
      final diag =
          'order=…${tail(orderId)} · business=…${tail(activeBusinessId)}';

      debugPrint("===== _loadOrderDetail ERROR =====");
      debugPrint("caller: $caller");
      debugPrint("orderId: $orderId");
      debugPrint("activeBusinessId: $activeBusinessId");
      debugPrint("loadedByBundle: $loadedByBundle");
      debugPrint("loadError: $loadError");
      debugPrint("bundleError: $bundleError");
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
      // Un fallo de red no dice nada sobre a qué orden apunta la mesa.
      // Con el bundle caído y un respaldo que respondió sin error pero sin
      // la cuenta, el "no existe" es del servidor: también se limpia (antes
      // quedaba un error fijo sobre una cuenta que ya no existe).
      if (!failedByNetwork) _tableCache.remove(tableId);
      final baseMessage =
          loadError ??
          bundleError ??
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
        fiscalSequencesLoadError = FriendlyError.from(e);
      }
    }

    // Una respuesta fiscal tardía tampoco puede podar las guardas de una
    // cuenta más reciente antes del chequeo que precede la escritura.
    if (superseded()) return;

    // Cambios de esta cuenta en la cola, de antes o que cayeron a ella
    // MIENTRAS se leía el servidor (un alta que se fue a la cola ya soltó su
    // guarda anti-parpadeo): con la cuenta abierta en el servidor, lo de
    // pantalla es la verdad local y la lectura no lo pisa. Solo se adopta un
    // cierre DEFINITIVO del servidor: esas operaciones ya no pueden aplicarse
    // y siguen en la cola (no se borra nada), pero la cuenta no queda abierta
    // y cobrable aquí.
    //
    // Definitivo = cobrada ('paid'/'partially_paid'). Una anulada (o cerrada
    // sin cobro a la vista) NO lo es mientras quede un alta suya por subir:
    // al subir, el trigger de order_items (20260819_0004) la resucita. Así
    // anula el barrendero de mesas vacías (fn_release_empty_tables: 'void' +
    // closed_at, sin marca que lo distinga de una anulación a mano) una cuenta
    // que se llenó sin red. Antes ese cierre se adoptaba: los productos sin
    // subir desaparecían de la pantalla, del respaldo y de la precuenta.
    final serverClosed = _isClosedOrder(order);
    final settledOnServer =
        order != null &&
        serverClosed &&
        (order.isPaid || order.status == 'partially_paid');
    if (queueBusinessId != null &&
        queuedAtStart != null &&
        !settledOnServer &&
        // Solo se protege una copia local ABIERTA. Cerrada en pantalla solo
        // queda al adoptar un cierre del servidor (el cobro sin red limpia la
        // pantalla): si el servidor la reabrió (alta resucitada, cobro
        // anulado), se aplica el servidor. Antes la regla protegía esa copia
        // cerrada y vacía como si fuera lo local mientras quedara una
        // operación muerta.
        !_isClosedOrder(state.order)) {
      bool keepsLocal(({bool unsettled, bool revivingAdds}) queued) =>
          serverClosed ? queued.revivingAdds : queued.unsettled;
      var keepLocal = keepsLocal(queuedAtStart);
      // Solo se vuelve a leer la cola si cambió durante la lectura del
      // servidor. Antes se leía (y descifraba completa) dos veces por recarga.
      if (!keepLocal &&
          _offlinePos.queueRevision(queueBusinessId) != queueRevisionAtStart) {
        keepLocal = keepsLocal(
          await _offlinePos.orderQueueStatus(
            businessId: queueBusinessId,
            orderId: orderId,
          ),
        );
        if (superseded()) return;
      }
      if (keepLocal) {
        if (state.order?.id != orderId) return;
        if (state.loading) state = state.copyWith(loading: false);
        // Realtime sigue activo: es lo que avisa si otro equipo la cierra.
        _subscribeToOrderUpdates(orderId);
        return;
      }
    }
    if (keepLocalContent && serverClosed) {
      // Los cambios sin subir siguen visibles en la cola (badge/visor).
      debugPrint(
        '[SalesViewModel] _loadOrderDetail($caller): la cuenta $orderId se '
        'cerró en el servidor con cambios locales en la cola',
      );
    }

    final resolvedFiscalType = _resolveFiscalTypeForState(
      state,
      fiscalSequences,
    );

    // Guardas anti-parpadeo. Al cambiar de orden no aplican (se limpian).
    if (previousOrderId != orderId) {
      _pendingDeletedItemIds.clear();
      _pendingItemQty.clear();
      _inFlightAddTmpIds.clear();
      _tmpToRealItemId.clear();
    } else {
      // BORRADOS: los ids que el server YA NO trae están confirmados → salen
      // de la guarda; los que el server AÚN trae (recarga stale antes del
      // commit) se filtran para que el item borrado no reaparezca.
      if (_pendingDeletedItemIds.isNotEmpty) {
        final serverIds = items.map((i) => i.id).toSet();
        _pendingDeletedItemIds.removeWhere((id) => !serverIds.contains(id));
        if (_pendingDeletedItemIds.isNotEmpty) {
          items = items
              .where((i) => !_pendingDeletedItemIds.contains(i.id))
              .toList();
        }
      }
      // CANTIDAD: si el server trae una qty vieja para un item con cambio
      // optimista en vuelo, conservamos la línea optimista (no revertimos)
      // hasta que el server confirme la qty esperada.
      if (_pendingItemQty.isNotEmpty) {
        final currentById = {for (final i in state.items) i.id: i};
        items = items.map((srv) {
          final expected = _pendingItemQty[srv.id];
          if (expected == null) return srv;
          if ((srv.quantity - expected).abs() < 0.0001) {
            _pendingItemQty.remove(srv.id); // server confirmó
            return srv;
          }
          return currentById[srv.id] ?? srv; // stale → mantener optimista
        }).toList();
        // Soltar guardas de items que el server ya no trae (borrados).
        final serverIds = items.map((i) => i.id).toSet();
        _pendingItemQty.removeWhere((id, _) => !serverIds.contains(id));
      }
      // ALTA: conservar los items agregados optimistamente (tmp_) cuyo INSERT
      // el server AÚN no refleja en esta recarga (típico de un eco Realtime
      // que corre antes del commit). Se sueltan en cuanto su contraparte real
      // —mapeada en _tmpToRealItemId al volver addItemFromMenu— ya viene en la
      // lista, evitando un duplicado (tmp + real). Sin esto, una recarga stale
      // en vuelo descartaba el item recién tocado y se veía "salir y volver".
      if (_inFlightAddTmpIds.isNotEmpty) {
        final serverIds = items.map((i) => i.id).toSet();
        final tmpInState = {
          for (final i in state.items)
            if (_inFlightAddTmpIds.contains(i.id)) i.id: i,
        };
        final keep = <OrderItem>[];
        for (final tmpId in _inFlightAddTmpIds) {
          final realId = _tmpToRealItemId[tmpId];
          final confirmed = realId != null && serverIds.contains(realId);
          if (!confirmed && tmpInState[tmpId] != null) {
            keep.add(tmpInState[tmpId]!);
          }
        }
        if (keep.isNotEmpty) {
          items = [...items, ...keep];
        }
      }
    }

    // Reaplicar los overrides fiscales por sub-cuenta (tipo de comprobante y
    // cliente/RNC) que el cajero fijó en el header. El bundle de la BD viva
    // puede no devolver requested_ncf_type / customer_rnc; sin esto la
    // selección revertía a B02 / perdía el RNC al recargar (p. ej. al asignar
    // cliente). Podamos overrides de checks que ya no existen (cerrados o de
    // otra orden).
    if (_checkNcfOverride.isNotEmpty || _checkCustomerOverride.isNotEmpty) {
      final checkIds = checks.map((c) => c.id).toSet();
      _checkNcfOverride.removeWhere((id, _) => !checkIds.contains(id));
      _checkCustomerOverride.removeWhere((id, _) => !checkIds.contains(id));
      if (_checkNcfOverride.isNotEmpty || _checkCustomerOverride.isNotEmpty) {
        checks = checks
            .map((c) {
              var nc = c;
              if (_checkNcfOverride.containsKey(c.id)) {
                final v = _checkNcfOverride[c.id];
                nc = v == null
                    ? nc.copyWith(clearNcfType: true)
                    : nc.copyWith(requestedNcfType: v);
              }
              final cust = _checkCustomerOverride[c.id];
              if (cust != null) {
                nc = nc.copyWith(
                  customerId: cust.id,
                  customerName: cust.name,
                  customerRnc: cust.rnc,
                );
              }
              return nc;
            })
            .toList(growable: false);
      }
    }

    // Punto de no retorno: si entre el fetch y aquí arrancó una carga más
    // nueva, descartamos este resultado (potencialmente stale) para no pisar el
    // state fresco. No hay `await` entre esta comprobación y la escritura, así
    // que la condición no puede cambiar bajo nuestros pies.
    if (superseded()) return;

    // Cliente elegido que el servidor todavía no confirma: gana sobre el
    // bundle hasta que el bundle lo traiga (o el servidor ya lo tenga y otra
    // caja lo haya cambiado después). Ver _pendingCustomers.
    final pendingCustomer = _pendingCustomers[orderId];
    var pushPendingCustomer = false;
    if (pendingCustomer != null) {
      final c = pendingCustomer.customer;
      final confirmed =
          customerId == c.id ||
          (customerId == null && customerName?.trim() == c.name.trim());
      final changedElsewhere =
          pendingCustomer.savedOnServer &&
          customerId != null &&
          customerId != c.id;
      if (confirmed || changedElsewhere) {
        _pendingCustomers.remove(orderId);
      } else {
        customerId = c.id;
        customerName = c.name;
        pushPendingCustomer =
            !pendingCustomer.savedOnServer && !pendingCustomer.pushing;
      }
    }

    _freshLoadGeneration = myGeneration;
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

    if (pushPendingCustomer) {
      unawaited(_pushPendingCustomer(orderId, sessionId: order?.sessionId));
    }

    final promotionsChanged = await _applyAutomaticPromotionsIfNeeded();
    if (superseded() || state.order?.id != orderId) return;
    if (promotionsChanged) {
      refreshOrder();
      return;
    }

    await _persistCurrentState(tableId: tableId);
    if (superseded() || state.order?.id != orderId) return;
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

    // El canal es de ESTA orden: un evento que llega cuando la pantalla ya
    // muestra otra cuenta (la baja del canal es asíncrona) no recarga la cuenta
    // en pantalla. Antes un cambio en la mesa A recargaba la venta rápida que
    // se estaba retomando y le quitaba la confirmación con el servidor.
    void refreshOwnOrder({bool clearIfPaid = false}) {
      if (state.order?.id != orderId) return;
      refreshOrder(clearIfPaid: clearIfPaid);
    }

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
            refreshOwnOrder();
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
            refreshOwnOrder();
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
            refreshOwnOrder(clearIfPaid: true);
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
            refreshOwnOrder();
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
    final estimatedSubtotal =
        item.quantity * (item.unitPrice + modifiersPerUnit);
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
              !(line.startsWith(_dealPrefix) && line.endsWith(']')) &&
              // Premio de la tarjeta de sellos: una cortesía lo reemplaza
              // (la línea queda gratis entera) y los sellos vuelven solos.
              !(line.startsWith(loyaltyMarkerPrefix) && line.endsWith(']')),
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

  /// Convierte un `time` de Postgres ("HH:mm:ss" / "HH:mm") a minutos desde
  /// medianoche, para comparar la franja horaria del happy hour. Devuelve null
  /// si no hay valor o no es parseable (=> sin restricción horaria).
  int? _promoTimeToMinutes(dynamic value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
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
    // Sin red no hay dónde aplicarlas: antes esta lectura esperaba el timeout
    // global (30 s) al final de CADA carga de orden, y si fallaba tumbaba
    // `openTable` al camino offline con una mesa ya abierta en el server.
    if (_preferLocalOperations) return false;

    final List<dynamic> promosRaw;
    try {
      promosRaw = await Supabase.instance.client
          .from('promotions')
          .select(
            'id,name,promo_type,discount_type,discount_value,min_purchase,target_scope,applies_to,target_ids,days_of_week,auto_apply,is_active,start_date,end_date,start_time,end_time,buy_quantity,pay_quantity,reward_quantity,priority,stackable',
          )
          .eq('business_id', businessId)
          .eq('is_active', true)
          .eq('auto_apply', true)
          .order('priority', ascending: false)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      if (e is TimeoutException || OfflinePosService.isTransportError(e)) {
        _recordTransportFailure();
      }
      debugPrint('[promos] no se pudieron leer ofertas automáticas: $e');
      return false;
    }

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
          // Happy hour: franja horaria diaria (hora local de la caja). Solo se
          // evalúa si AMBAS horas están definidas; si no, aplica todo el día.
          // Si end < start, la franja cruza la medianoche (ej. 22:00 → 02:00).
          final startMin = _promoTimeToMinutes(promo['start_time']);
          final endMin = _promoTimeToMinutes(promo['end_time']);
          var inTimeWindow = true;
          if (startMin != null && endMin != null && startMin != endMin) {
            final nowMin = now.hour * 60 + now.minute;
            inTimeWindow = startMin < endMin
                ? (nowMin >= startMin && nowMin < endMin)
                : (nowMin >= startMin || nowMin < endMin);
          }
          return inDateRange && inWeekday && inTimeWindow;
        })
        .toList(growable: false);

    if (promos.isEmpty) {
      // Antes se QUITABAN todas las auto-ofertas ya aplicadas cuando no había
      // ninguna promo activa/en-franja. Eso borraba la oferta de cuentas
      // abiertas al desactivar la promo o cerrar el happy hour (ej. aplicada a
      // las 8:55, pago a las 9:30). Ahora se CONGELAN: no se toca nada. Una
      // oferta ya aplicada solo se recalcula/quita mientras su promo siga
      // vigente (ver activePromoIds abajo).
      return false;
    }

    // IDs de las promos ACTUALMENTE activas y dentro de su franja horaria. Una
    // oferta ya aplicada cuya promo NO esté aquí (se desactivó o su happy hour
    // cerró) se congela: el motor no la recalcula ni la quita.
    final activePromoIds = promos
        .map((promo) => promo['id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();

    final eligibleBaseItems = openItems
        .where((item) {
          if (_hasCourtesyNote(item.notes)) return false;
          if (_isDealNote(item.notes)) return false;
          final existingPromoId = _extractAutoPromoId(item.notes);
          if (existingPromoId != null) {
            // Oferta ya aplicada: solo re-evaluable si su promo SIGUE activa/en
            // franja; si no, se congela (el motor no la toca).
            return activePromoIds.contains(existingPromoId);
          }
          return item.discounts <= 0.009;
        })
        .toList(growable: false);

    if (eligibleBaseItems.isEmpty) return false;

    final updates =
        <
          ({String itemId, double discount, String? notes, String promotionId})
        >[];
    final touchedItemIds = <String>{};

    List<OrderItem> itemsForPromo(Map<String, dynamic> promo) {
      // Regla: una auto-promo NUNCA debe descontar productos que no están en su
      // oferta. Antes, scope vacío/'all'/'category' hacía `return true` para
      // TODOS los ítems → una promo mal configurada (p.ej. "3x2 cerveza" con
      // target_scope='all' y target_ids=null) se pegaba a agua, soda, etc.
      final rawScope =
          (promo['target_scope']?.toString().trim().isNotEmpty ?? false)
          ? promo['target_scope'].toString().trim().toLowerCase()
          : (promo['applies_to']?.toString().trim().toLowerCase() ?? '');
      final type =
          (promo['promo_type']?.toString() ??
                  promo['discount_type']?.toString() ??
                  'percentage')
              .toLowerCase();
      final targetIds =
          (promo['target_ids'] as List?)
              ?.map((value) => value?.toString() ?? '')
              .where((value) => value.isNotEmpty)
              .toSet() ??
          <String>{};

      // Tipos ESPECÍFICOS de producto (bogo / bundle): no existe un "3x2 de
      // todo" — SIEMPRE requieren target_ids con los productos en oferta.
      final isProductSpecific = type == 'bogo' || type == 'bundle_price';
      // 'all' solo aplica globalmente para descuentos lineales (porcentaje /
      // monto fijo), donde "toda la carta" sí es una oferta legítima.
      final appliesToAll = rawScope == 'all' && !isProductSpecific;

      // Sin scope global y sin target_ids → no aplica a nada (fail-safe).
      // 'category' tampoco aplica: OrderItem no trae la categoría, así que no
      // podemos validar por categoría; mejor no descontar que descontar de más.
      if (!appliesToAll && targetIds.isEmpty) {
        return const <OrderItem>[];
      }
      return eligibleBaseItems
          .where((item) {
            if (touchedItemIds.contains(item.id)) return false;
            if (appliesToAll) return true;
            final productId = item.productId?.trim();
            return productId != null &&
                productId.isNotEmpty &&
                targetIds.contains(productId);
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

        // El BOGO se calcula DENTRO de cada cuenta (split bill), por PRODUCTO
        // y por UNIDADES (no por filas). El reparto vive en
        // `allocateBogoDiscounts` (data/utils/bogo_promo_allocator.dart), puro
        // y testeado: agrupa por cuenta+producto, libera
        // (unidades ~/ buyQty) * freeQty por grupo y descuenta solo esas
        // unidades a las más baratas del propio producto. Determinista → mismo
        // reparto en cada recarga, sin churn, sin contaminación entre cuentas
        // ni entre productos.
        final byItemId = {for (final item in targetItems) item.id: item};
        final allocations = allocateBogoDiscounts(
          lines: targetItems
              .map(
                (item) => BogoLine(
                  id: item.id,
                  quantity: item.quantity.round(),
                  gross: grossAmount(item),
                  checkId: item.checkId,
                  productId: item.productId,
                ),
              )
              .toList(growable: false),
          buyQuantity: buyQty,
          freeQuantity: freeQty,
        );

        for (final entry in allocations.entries) {
          final item = byItemId[entry.key];
          if (item == null) continue;
          updates.add((
            itemId: item.id,
            discount: entry.value,
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
          // Solo se re-evalúa (y eventualmente se quita) si la promo SIGUE
          // activa/en-franja — churn normal de una promo vigente al cambiar el
          // carrito. Si la promo ya no está activa, la oferta se congela.
          return promoId != null &&
              activePromoIds.contains(promoId) &&
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
