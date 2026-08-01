import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/kitchen_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/hub/hub_client.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart' show TerminalMode;
import 'package:mangopos/core/offline/hub/hub_event_stream.dart';
import 'package:mangopos/core/offline/hub/hub_kitchen_projector.dart';
import 'package:mangopos/core/offline/hub/hub_mode_controller.dart'
    show hubModeProvider;

final kitchenRepositoryProvider = Provider<KitchenRepository>((ref) {
  return KitchenRepository(Supabase.instance.client);
});

final printingServiceProvider = Provider<PrintingService>((ref) {
  return PrintingService(Supabase.instance.client);
});

final kitchenViewModelProvider = ChangeNotifierProvider<KitchenViewModel>((
  ref,
) {
  return KitchenViewModel(
    ref.read(kitchenRepositoryProvider),
    ref.read(printingServiceProvider),
    ref,
  );
});

/// Clave de una tarjeta del KDS: orden + ronda (`kitchen_sent_at`) + área de
/// producción. Debe coincidir EXACTAMENTE con la agrupación del tablero
/// ([_KitchenViewState._activeOrders]) para que el guard anti-vaciado
/// ([KitchenViewModel._bumpWouldEmptyCard]) identifique la tarjeta correcta.
String kitchenCardKey(KitchenItem item) {
  final round = item.kitchenSentAt?.toIso8601String() ?? 'legacy';
  final area = (item.areaCode == null || item.areaCode!.isEmpty)
      ? '__none__'
      : item.areaCode!;
  return '${item.orderId}::$round::$area';
}

/// Momento en que una comanda SALIÓ del KDS, para ordenar "Completados hoy".
///
/// Prioridad:
///   1. `kitchen_done_at` — el sello de despacho de la orden. Es el correcto:
///      una comanda de 10 platos que el cocinero fue marcando de a uno tiene
///      su último `ready_at` mucho antes del despacho, y sin este sello se
///      hundía debajo de comandas más chicas despachadas después.
///   2. el último `ready_at` de sus ítems — órdenes aún sin sellar.
///   3. `created_at` — ítems sin ningún sello (legacy/importados).
DateTime kitchenDispatchedAt(List<KitchenItem> items) {
  DateTime? dispatched;
  DateTime? lastReady;
  DateTime? created;
  for (final item in items) {
    final done = item.kitchenDoneAt;
    if (done != null && (dispatched == null || done.isAfter(dispatched))) {
      dispatched = done;
    }
    final ready = item.readyAt;
    if (ready != null && (lastReady == null || ready.isAfter(lastReady))) {
      lastReady = ready;
    }
    if (created == null || item.createdAt.isAfter(created)) {
      created = item.createdAt;
    }
  }
  return dispatched ?? lastReady ?? created ?? DateTime.now();
}

class KitchenViewModel extends ChangeNotifier {
  final KitchenRepository _repository;
  final PrintingService _printingService;
  // H6: acceso al modo hub (LAN-first) para leer el tablero del Hub y enrutar
  // los cambios de estado del KDS por la red local en vez de Supabase.
  final Ref _ref;
  HubEventStream? _hubEvents;
  StreamSubscription<Map<String, dynamic>>? _hubEventsSub;
  String? _hubEventsUrl;
  Timer? _hubPollTimer;

  bool _isLoading = false;
  List<KitchenItem> _items = [];
  String? _businessId;
  RealtimeChannel? _rtItems;
  Timer? _refreshDebounce;
  bool _refreshing = false;
  bool _refreshQueued = false;
  final Map<String, _StatusOverride> _statusOverrides = {};

  /// Áreas de producción configuradas por el comercio (Cocina, Bar, etc.).
  /// Se cargan una vez en `init()` y alimentan el dropdown de filtro.
  List<KitchenArea> _availableAreas = const [];

  /// Código del área seleccionada actualmente en el filtro. `null` = "Todos"
  /// (no filtra, muestra items de cualquier área).
  String? _selectedAreaCode;

  /// Setting `kds_complete_on_payment`:
  /// - TRUE (default): al pagar, la comanda sale del KDS. El tablero muestra
  ///   solo órdenes con trabajo pendiente (vía `kds_active_items`).
  /// - FALSE: la comanda se queda aunque esté pagada, hasta que el cocinero la
  ///   marque ("Marcar todo listo"). El tablero usa `kds_open_orders`
  ///   (órdenes con `kitchen_done_at IS NULL`).
  bool _completeOnPayment = true;

  KitchenViewModel(this._repository, this._printingService, this._ref);

  // Solo CAJA CLIENTE del Hub. El equipo Hub (host) tiene internet → su KDS
  // lee de Supabase normal (no del op-log). Ver nota en SalesViewModel._isHubMode.
  bool get _isHubMode {
    return _ref.read(hubModeProvider) == TerminalMode.hubClient;
  }

  /// H6: obtiene los ítems del tablero de cocina desde el Hub. El equipo Hub
  /// proyecta su op-log local; una caja cliente pide el delta del Hub
  /// (`GET /hub/state`). null si no aplica o no se pudo leer.
  Future<List<KitchenItem>?> _fetchHubKitchenItems() async {
    if (_businessId == null) return null;
    final mode = _ref.read(hubModeProvider);
    List<Map<String, dynamic>> ops;
    if (mode == TerminalMode.hubHost) {
      ops = await OfflinePosService().getLocalHubOps(_businessId!);
    } else if (mode == TerminalMode.hubClient) {
      final url = _ref.read(hubModeProvider.notifier).reachableHubUrl;
      if (url == null) return null;
      final state =
          await HubClient().getStateSince(url, businessId: _businessId!);
      ops = state?.ops ?? const [];
    } else {
      return null;
    }
    final orders = HubKitchenProjector.project(ops);
    return orders.expand((o) => o.items).toList(growable: false);
  }

  /// H6: enruta un cambio de estado del KDS. En modo hub encola una op
  /// `kds_item_status` (que va al Hub y, al subir, actualiza el ítem real). En
  /// modo nube, el update directo a Supabase de siempre.
  Future<void> _setItemStatus(String itemId, String status) async {
    if (_isHubMode && _businessId != null) {
      await OfflinePosService().enqueueAction(
        businessId: _businessId!,
        action: {
          'type': 'kds_item_status',
          'item_id': itemId,
          'status': status,
        },
      );
    } else {
      await _repository.updateItemStatus(itemId: itemId, status: status);
    }
  }

  bool get isLoading => _isLoading;
  List<KitchenItem> get items => _items;
  List<KitchenArea> get availableAreas => _availableAreas;
  String? get selectedAreaCode => _selectedAreaCode;

  /// Ver [_completeOnPayment]. La vista lo usa para decidir cuándo una comanda
  /// sale del tablero.
  bool get completeOnPayment => _completeOnPayment;

  /// Ítems que la cocina terminó HOY (vía `kds_completed_today`, basado en
  /// `ready_at`). Independiente del tablero vivo — alimenta "Completados Hoy".
  List<KitchenItem> _completedTodayItems = const [];
  List<KitchenItem> get completedTodayItems => _completedTodayItems;

  /// Items que pasan el filtro de área seleccionada. Si no hay filtro
  /// activo, devuelve todos. Si el filtro está en un código y el item
  /// no tiene `areaCode` (ej. menu_item sin área asignada), lo
  /// excluimos — el comercio así detecta visualmente qué productos
  /// le faltan configurar.
  List<KitchenItem> get _filteredItems {
    final code = _selectedAreaCode;
    if (code == null || code.isEmpty) return _items;
    return _items.where((i) => i.areaCode == code).toList(growable: false);
  }

  /// Todos los ítems activos visibles (respetando el filtro de área). El
  /// tablero los agrupa por orden para armar las comandas.
  List<KitchenItem> get visibleActiveItems => _filteredItems;

  // Derive filtered lists (ahora también respetan el filtro de área).
  List<KitchenItem> get pendingItems =>
      _filteredItems.where((i) => i.status == 'pending').toList();
  List<KitchenItem> get preparingItems =>
      _filteredItems.where((i) => i.status == 'preparing').toList();
  List<KitchenItem> get readyItems =>
      _filteredItems.where((i) => i.status == 'ready').toList();

  /// Cambia el área visible. Pasá `null` para "Todos".
  void setSelectedAreaCode(String? code) {
    if (_selectedAreaCode == code) return;
    _selectedAreaCode = code;
    notifyListeners();
  }

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      _businessId = await resolveBusinessIdOrNull(client, 'auto');
      if (_businessId != null) {
        // Leemos el modo del tablero antes del primer refresh para elegir la
        // fuente correcta (kds_active_items vs kds_open_orders).
        try {
          _completeOnPayment = await PosSettingsRepository(client)
              .getKdsCompleteOnPayment(_businessId!);
        } catch (_) {
          _completeOnPayment = true;
        }
        // Cargar áreas en paralelo con el refresh inicial. El dropdown del
        // filtro depende de esta lista — si la query falla, queda vacía y
        // el UI muestra solo "Todos".
        await Future.wait([
          _loadAreas(),
          refresh(),
        ]);
        // H6: en modo hub el Realtime de Supabase no sirve (las comandas viven
        // en el Hub) → usamos el feed del Hub (WS para cliente) + un poll de
        // respaldo. En modo nube, el Realtime de siempre.
        if (_isHubMode) {
          _startHubFeed();
        } else {
          _subscribeRealtime(client, _businessId!);
        }
      }
    } catch (e) {
      debugPrint('Error initializing kitchen: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadAreas() async {
    if (_businessId == null) return;
    try {
      _availableAreas =
          await _repository.getPrintAreas(businessId: _businessId!);
    } catch (e) {
      debugPrint('Error loading print areas: $e');
      _availableAreas = const [];
    }
  }

  Future<void> refresh({bool force = false}) async {
    if (_businessId == null) return;
    if (_refreshing && !force) {
      _refreshQueued = true;
      return;
    }
    _refreshing = true;
    try {
      // H6: en modo hub el tablero se reconstruye del op-log del Hub (las
      // comandas que las cajas mandaron por LAN), no de Supabase. Si el Hub no
      // responde, caemos al camino normal de abajo.
      if (_isHubMode) {
        final hubItems = await _fetchHubKitchenItems();
        if (hubItems != null) {
          _items = _applyStatusOverrides(hubItems);
          notifyListeners();
          return;
        }
      }
      // Modo "sale al pagar" → kds_active_items (solo pendientes/listos).
      // Modo "esperar al cocinero" → kds_open_orders (incluye pagadas hasta
      // que la cocina las marque). En paralelo traemos los completados de hoy
      // (independiente del tablero) para el stat "Completados Hoy".
      final results = await Future.wait([
        _completeOnPayment
            ? _repository.getActiveItems(
                businessId: _businessId,
                includeModifiers: true,
              )
            : _repository.getOpenItems(businessId: _businessId),
        _repository.getCompletedTodayItems(businessId: _businessId),
      ]);
      _items = _applyStatusOverrides(results[0]);
      _completedTodayItems = results[1];
      notifyListeners();
    } catch (e) {
      debugPrint('Error refreshing kitchen items: $e');
    } finally {
      _refreshing = false;
      if (_refreshQueued) {
        _refreshQueued = false;
        unawaited(refresh());
      }
    }
  }

  /// True si el ítem está actualmente 'paid' en el tablero. Solo ocurre en modo
  /// "esperar al cocinero" (kds_open_orders trae los pagados); en modo "sale al
  /// pagar" los pagados nunca llegan al KDS. Ver [stampItemCookProgress].
  bool _isPaidItem(String itemId) {
    for (final i in _items) {
      if (i.id == itemId) return i.status == 'paid';
    }
    return false;
  }

  Future<void> startCooking(String itemId) async {
    // Ítem ya pagado (modo "esperar al cocinero"): sellamos solo `started_at`
    // sin revertir el 'paid'. En cualquier otro estado, la transición normal
    // a 'preparing' aplica.
    final preservePaid = _isPaidItem(itemId) && !_isHubMode;
    _applyLocalItemStatus(itemId, 'preparing');
    try {
      if (preservePaid) {
        await _repository.stampItemCookProgress(itemId: itemId, ready: false);
      } else {
        await _setItemStatus(itemId, 'preparing');
      }
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error starting cooking: $e');
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    }
  }

  Future<void> startPreparingOrder(String orderId) async {
    _applyLocalOrderStatus(orderId, from: {'pending'}, to: 'preparing');
    final affectedIds = _items
        .where((item) => item.orderId == orderId && item.status == 'preparing')
        .map((item) => item.id)
        .toSet();
    try {
      if (_isHubMode) {
        for (final id in affectedIds) {
          await _setItemStatus(id, 'preparing');
        }
      } else {
        await _repository.startPreparingOrder(orderId);
      }
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error starting order preparation: $e');
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    }
  }

  Future<void> markReady(String itemId) async {
    // El bump individual solo MARCA el ítem como listo (progreso). La comanda
    // se queda en el tablero —aunque se marquen todos los ítems— hasta que se
    // despache con "Marcar todo listo" (que los pasa a 'served' e imprime).
    // Ítem ya pagado (modo "esperar al cocinero"): sellamos solo `ready_at`
    // sin revertir el 'paid' (del que depende la reapertura al anular el pago).
    final preservePaid = _isPaidItem(itemId) && !_isHubMode;
    _applyLocalItemStatus(itemId, 'ready');
    try {
      if (preservePaid) {
        await _repository.stampItemCookProgress(itemId: itemId, ready: true);
      } else {
        await _setItemStatus(itemId, 'ready');
      }
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error marking ready: $e');
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    }
  }

  /// Despacha una comanda ("Marcar todo listo"): marca lo que falte como
  /// listo, imprime el ticket LISTO de esa RONDA y la quita del tablero.
  ///
  /// [itemIds] limita la acción a los ítems de esa ronda/tarjeta (una orden
  /// puede tener varias comandas). Si es null, opera sobre toda la orden
  /// (compat). La cocina se sella solo cuando ya no quedan ítems activos de la
  /// orden (última ronda), para no borrar del tablero rondas aún pendientes.
  ///
  /// Devuelve un aviso para el usuario cuando el ticket LISTO no pudo salir
  /// porque el área no tiene impresora con "Imprimir al marcar listo" activa.
  /// `null` = todo bien (imprimió o no había nada que imprimir).
  Future<String?> markOrderReady(
    String orderId, {
    List<String>? itemIds,
    // Impresión pedida explícitamente por el usuario (modal al completar la
    // comanda círculo a círculo): imprime aunque el área no tenga "Imprimir
    // al marcar listo" activo, cayendo a sus impresoras normales de comanda.
    bool forcePrint = false,
  }) async {
    final scope = itemIds?.toSet();
    bool inScope(KitchenItem i) =>
        i.orderId == orderId && (scope == null || scope.contains(i.id));

    // Ítems que se estaban cocinando (incluye los que el chef ya marcó 'ready'
    // por su círculo): esta acción los DESPACHA a 'served'. 'served' es un
    // estado terminal PERSISTENTE que saca la comanda del tablero de verdad
    // (sobrevive recargas), a diferencia de dejarlos 'ready' —que solo tacha—.
    // Los 'paid' no se tocan (mantienen su cobro); salen por el sello + ready_at.
    final cookingItems = _items
        .where(
          (item) =>
              inScope(item) &&
              (item.status == 'pending' ||
                  item.status == 'preparing' ||
                  item.status == 'ready'),
        )
        .toList(growable: false);
    final affectedIds = cookingItems.map((item) => item.id).toSet();

    // TODA la ronda activa, incluidos los ítems que el chef ya marcó listos
    // uno por uno. El ticket LISTO debe reflejar la comanda completa, no solo
    // el último ítem.
    final allActiveIds = _items
        .where(inScope)
        .map((item) => item.id)
        .toList(growable: false);

    // Optimista: sacar SOLO los ítems de esta ronda del tablero.
    _items = _items.where((item) => !inScope(item)).toList(growable: false);
    notifyListeners();

    try {
      // Despacho a 'served'. En nube usamos un update por lote (marca ready_at
      // si falta y pasa a 'served' solo lo que se estaba cocinando). En hub,
      // encolamos la op por ítem —el tablero del Hub ya saca la comanda por el
      // estado de sus ítems y se reconcilia al subir—.
      if (_isHubMode) {
        for (final item in cookingItems) {
          await _setItemStatus(item.id, 'served');
        }
      } else {
        await _repository.markCardItemsServed(affectedIds.toList());
      }
      // Sello de cocina terminada: solo si a la orden ya no le queda trabajo
      // pendiente en NINGUNA ronda (todo está listo/servido). Así, en modo
      // "esperar al cocinero", una ronda aún por cocinar no saca del tablero
      // toda la orden.
      var orderHasPendingWork = _items.any(
        (item) =>
            item.orderId == orderId &&
            (item.status == 'pending' ||
                item.status == 'preparing' ||
                item.status == 'ready'),
      );
      // En modo hub el "sello" de cocina terminada (kitchen_done_at) se
      // reconcilia al subir; el tablero del Hub ya saca la comanda por el
      // estado 'ready' de sus ítems. Evitamos el RPC a Supabase aquí.
      if (!orderHasPendingWork && !_isHubMode) {
        // El tablero local puede NO contener aún una ronda que la mesa acaba
        // de enviar (Realtime/poll con retraso). Sellar con ese snapshot
        // borraría la comanda nueva del KDS (kds_open_orders filtra
        // kitchen_done_at) y le estamparía ready_at sin cocinar. Confirmamos
        // contra el server; si la consulta falla, NO sellamos (el sello sale
        // en el próximo despacho de la orden).
        try {
          orderHasPendingWork =
              await _repository.orderHasActiveKitchenItems(orderId);
        } catch (_) {
          orderHasPendingWork = true;
        }
      }
      if (!orderHasPendingWork && !_isHubMode) {
        await _repository.markOrderKitchenDone(orderId);
      }
      String? notice;
      if (_businessId != null && allActiveIds.isNotEmpty) {
        try {
          final report = await _printingService.printReadyOrderTicket(
            orderId: orderId,
            businessId: _businessId!,
            itemIds: allActiveIds,
            fallbackToAreaPrinters: forcePrint,
          );
          // Avisar SIEMPRE que un área se haya saltado por falta de impresora
          // de "listo" — incluso si OTRA área sí imprimió (caso parcial: p. ej.
          // Cocina imprime pero Bar no). Antes se exigía `nothingPrinted`, así
          // que el salto parcial quedaba mudo y el usuario no sabía por qué su
          // segunda área nunca imprimía el ticket de LISTO.
          if (report.missingReadyPrinter) {
            // Con forcePrint el fallback ya intentó las impresoras normales:
            // llegar aquí = el área no tiene NINGUNA impresora asignada.
            notice = forcePrint
                ? 'La comanda no salió en: '
                    '${_areaNames(report.areasWithoutReadyPrinter)}. Esa área '
                    'no tiene ninguna impresora asignada en Ajustes → '
                    'Impresoras.'
                : _readyPrinterNotice(report.areasWithoutReadyPrinter);
          }
        } catch (e) {
          debugPrint('Error printing ready ticket: $e');
        }
      }
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
      return notice;
    } catch (e) {
      debugPrint('Error marking order ready: $e');
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
      return null;
    }
  }

  /// Traduce códigos de área a nombres legibles usando las áreas cargadas.
  String _areaNames(List<String> areaCodes) {
    final names = areaCodes.map((code) {
      for (final a in _availableAreas) {
        if (a.code == code) return a.name;
      }
      return code;
    }).toList(growable: false);
    return names.isEmpty ? 'un área' : names.join(', ');
  }

  /// Mensaje amigable cuando ninguna área imprimió el ticket LISTO por falta
  /// de una impresora con "Imprimir al marcar listo" activa.
  String _readyPrinterNotice(List<String> areaCodes) {
    return 'El ticket de LISTO no salió en: ${_areaNames(areaCodes)}. Esa '
        'área no tiene una impresora con "Imprimir al marcar listo" '
        'activado. Actívalo en Ajustes → Impresoras → Asignaciones de área.';
  }

  /// Reimprime la comanda de una tarjeta (viva o de "Completados hoy") en
  /// las impresoras normales de comanda, con marca de REIMPRESIÓN. No toca
  /// estados ni crea rondas nuevas. Devuelve el mensaje para el snackbar
  /// (null = imprimió todo sin novedades).
  Future<String?> reprintComanda({
    required String orderId,
    required List<String> itemIds,
    // Área de la tarjeta reimpresa (el tablero separa una tarjeta por
    // estación): la reimpresión sale solo por esa área. Null = todas las
    // áreas de los ítems (reimpresión desde "Completados hoy").
    String? areaCode,
  }) async {
    final businessId = _businessId;
    if (businessId == null || itemIds.isEmpty) {
      return 'No se pudo reimprimir la comanda.';
    }
    try {
      final report = await _printingService.reprintComandaTicket(
        orderId: orderId,
        businessId: businessId,
        itemIds: itemIds,
        onlyAreaCode: areaCode,
      );
      if (report.nothingPrinted) {
        return report.missingReadyPrinter
            ? 'La comanda no salió en: '
                '${_areaNames(report.areasWithoutReadyPrinter)}. Revisa que el '
                'área tenga impresora asignada y que esté accesible.'
            : 'No se pudo reimprimir la comanda.';
      }
      if (report.missingReadyPrinter) {
        return 'Comanda reimpresa, pero no salió en: '
            '${_areaNames(report.areasWithoutReadyPrinter)} (sin impresora '
            'asignada o inaccesible).';
      }
      return null;
    } catch (e) {
      debugPrint('Error reimprimiendo comanda: $e');
      return 'No se pudo reimprimir la comanda.';
    }
  }

  void _subscribeRealtime(SupabaseClient client, String businessId) {
    _rtItems?.unsubscribe();
    // PRD 7 Fase 4.1 — `order_items` no tiene `business_id` directo
    // (su scope viene via `orders.session_id → table_sessions.business_id`),
    // así que no podemos aplicar `filter: business_id=eq.X` server-side.
    // RLS es la barrera real de aislamiento. El channel ya está scoped
    // por businessId en su nombre para evitar colisiones entre tenants
    // dentro del mismo cluster Realtime.
    _rtItems = client.channel('rt:kitchen_items:$businessId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'order_items',
        callback: (_) => _scheduleRefresh(),
      )
      ..subscribe();
  }

  /// H6: engancha el feed del Hub. Cliente → WebSocket del Hub (refresco
  /// instantáneo). Host → no tiene WS propio, así que un poll de respaldo cada
  /// 3s cubre tanto al host como a reconexiones del cliente.
  void _startHubFeed() {
    final businessId = _businessId;
    if (businessId == null) return;
    if (_ref.read(hubModeProvider) == TerminalMode.hubClient) {
      final url = _ref.read(hubModeProvider.notifier).reachableHubUrl;
      if (url != null && _hubEventsUrl != url) {
        _disconnectHubEvents();
        _hubEventsUrl = url;
        final stream = HubEventStream(baseUrl: url, businessId: businessId);
        _hubEvents = stream;
        _hubEventsSub = stream.ops.listen((_) => _scheduleRefresh());
        stream.connect();
      }
    }
    _hubPollTimer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(refresh()),
    );
  }

  void _stopHubFeed() {
    _hubPollTimer?.cancel();
    _hubPollTimer = null;
    _disconnectHubEvents();
  }

  void _disconnectHubEvents() {
    _hubEventsSub?.cancel();
    _hubEventsSub = null;
    final s = _hubEvents;
    _hubEvents = null;
    _hubEventsUrl = null;
    if (s != null) unawaited(s.dispose());
  }

  void _scheduleRefresh({bool immediate = false}) {
    _refreshDebounce?.cancel();
    if (immediate) {
      unawaited(refresh(force: true));
      return;
    }
    _refreshDebounce = Timer(
      const Duration(milliseconds: 220),
      () => unawaited(refresh()),
    );
  }

  void _applyLocalItemStatus(String itemId, String status) {
    final now = DateTime.now();
    var changed = false;
    _items = _items
        .where((item) {
          if (item.id != itemId) return true;
          changed = true;
          return status != 'served';
        })
        .map((item) {
          if (item.id != itemId) return item;
          _statusOverrides[itemId] = _StatusOverride(
            status: status,
            startedAt: status == 'preparing' ? (item.startedAt ?? now) : null,
            readyAt: status == 'ready' ? now : null,
          );
          return item.copyWith(
            status: status,
            startedAt: status == 'preparing'
                ? (item.startedAt ?? now)
                : item.startedAt,
            readyAt: status == 'ready' ? now : item.readyAt,
          );
        })
        .toList(growable: false);

    if (changed) notifyListeners();
  }

  void _applyLocalOrderStatus(
    String orderId, {
    required Set<String> from,
    required String to,
  }) {
    final now = DateTime.now();
    var changed = false;

    _items = _items
        .map((item) {
          if (item.orderId != orderId || !from.contains(item.status)) {
            return item;
          }
          _statusOverrides[item.id] = _StatusOverride(
            status: to,
            startedAt: to == 'preparing' ? (item.startedAt ?? now) : null,
            readyAt: to == 'ready' ? now : null,
          );
          changed = true;
          return item.copyWith(
            status: to,
            startedAt: to == 'preparing'
                ? (item.startedAt ?? now)
                : item.startedAt,
            readyAt: to == 'ready' ? now : item.readyAt,
          );
        })
        .toList(growable: false);

    if (changed) notifyListeners();
  }

  List<KitchenItem> _applyStatusOverrides(List<KitchenItem> fetched) {
    if (_statusOverrides.isEmpty) return fetched;
    final now = DateTime.now();
    final result = <KitchenItem>[];

    for (final item in fetched) {
      final override = _statusOverrides[item.id];
      if (override == null) {
        result.add(item);
        continue;
      }

      // Si backend ya confirmó el mismo estado, liberamos override.
      if (item.status == override.status) {
        _statusOverrides.remove(item.id);
        result.add(item);
        continue;
      }

      // Evita "rebotes" visuales a estados anteriores por lecturas stale breves.
      if (override.expiresAt.isAfter(now)) {
        result.add(
          item.copyWith(
            status: override.status,
            startedAt: override.startedAt ?? item.startedAt,
            readyAt: override.readyAt ?? item.readyAt,
          ),
        );
        continue;
      }

      _statusOverrides.remove(item.id);
      result.add(item);
    }

    return result;
  }

  void _clearOverride(String itemId) {
    _statusOverrides.remove(itemId);
  }

  void _clearOverrides(Iterable<String> itemIds) {
    for (final id in itemIds) {
      _statusOverrides.remove(id);
    }
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _statusOverrides.clear();
    _rtItems?.unsubscribe();
    _rtItems = null;
    _stopHubFeed();
    super.dispose();
  }
}

class _StatusOverride {
  final String status;
  final DateTime? startedAt;
  final DateTime? readyAt;
  final DateTime expiresAt;

  _StatusOverride({
    required this.status,
    this.startedAt,
    this.readyAt,
    DateTime? expiresAt,
  }) : expiresAt = expiresAt ?? DateTime.now().add(const Duration(seconds: 4));
}
