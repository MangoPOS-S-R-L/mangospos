import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/kitchen_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';

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
  );
});

class KitchenViewModel extends ChangeNotifier {
  final KitchenRepository _repository;
  final PrintingService _printingService;

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

  KitchenViewModel(this._repository, this._printingService);

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
        _subscribeRealtime(client, _businessId!);
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
      // Modo "sale al pagar" → kds_active_items (solo pendientes/listos).
      // Modo "esperar al cocinero" → kds_open_orders (incluye pagadas hasta
      // que la cocina las marque). En paralelo traemos los completados de hoy
      // (independiente del tablero) para el stat "Completados Hoy".
      final results = await Future.wait([
        _completeOnPayment
            ? _repository.getActiveItems(businessId: _businessId)
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

  Future<void> startCooking(String itemId) async {
    _applyLocalItemStatus(itemId, 'preparing');
    try {
      await _repository.updateItemStatus(itemId: itemId, status: 'preparing');
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
      await _repository.startPreparingOrder(orderId);
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error starting order preparation: $e');
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    }
  }

  Future<void> markReady(String itemId) async {
    _applyLocalItemStatus(itemId, 'ready');
    try {
      await _repository.updateItemStatus(itemId: itemId, status: 'ready');
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
  Future<String?> markOrderReady(String orderId, {List<String>? itemIds}) async {
    final scope = itemIds?.toSet();
    bool inScope(KitchenItem i) =>
        i.orderId == orderId && (scope == null || scope.contains(i.id));

    // Items que aún faltaban (los que esta acción transiciona a 'ready').
    final openItems = _items
        .where(
          (item) =>
              inScope(item) &&
              (item.status == 'pending' || item.status == 'preparing'),
        )
        .toList(growable: false);
    final affectedIds = openItems.map((item) => item.id).toSet();

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
      // Marcado confiable ítem por ítem. NO usamos el RPC `fn_mark_order_ready`
      // porque en este entorno no persistía y la card "se devolvía"; el update
      // directo por ítem es el mismo camino probado del bump individual.
      for (final item in openItems) {
        await _repository.updateItemStatus(itemId: item.id, status: 'ready');
      }
      // Sello de cocina terminada: solo si a la orden ya no le queda trabajo
      // pendiente en NINGUNA ronda (todo está listo/servido). Así, en modo
      // "esperar al cocinero", una ronda aún por cocinar no saca del tablero
      // toda la orden. Los ítems 'ready' de rondas previas no cuentan como
      // trabajo pendiente.
      final orderHasPendingWork = _items.any(
        (item) =>
            item.orderId == orderId &&
            (item.status == 'pending' || item.status == 'preparing'),
      );
      if (!orderHasPendingWork) {
        await _repository.markOrderKitchenDone(orderId);
      }
      String? notice;
      if (_businessId != null && allActiveIds.isNotEmpty) {
        try {
          final report = await _printingService.printReadyOrderTicket(
            orderId: orderId,
            businessId: _businessId!,
            itemIds: allActiveIds,
          );
          if (report.nothingPrinted && report.missingReadyPrinter) {
            notice = _readyPrinterNotice(report.areasWithoutReadyPrinter);
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

  /// Mensaje amigable cuando ninguna área imprimió el ticket LISTO por falta
  /// de una impresora con "Imprimir al marcar listo" activa. Traduce los
  /// códigos de área a nombres legibles usando las áreas cargadas.
  String _readyPrinterNotice(List<String> areaCodes) {
    final names = areaCodes.map((code) {
      for (final a in _availableAreas) {
        if (a.code == code) return a.name;
      }
      return code;
    }).toList(growable: false);
    final areas = names.isEmpty ? '' : ' (${names.join(', ')})';
    return 'La comanda se marcó lista, pero no salió impresa: ninguna '
        'impresora del área$areas tiene activado "Imprimir al marcar listo". '
        'Actívalo en Ajustes → Impresoras → Asignaciones de área.';
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
