import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/kitchen_models.dart';
import '../../../data/repositories/kitchen_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../services/session/session_controller.dart';
import '../state/kds_state.dart';

// Provider
final kitchenRepositoryProvider = Provider<KitchenRepository>(
  (ref) => KitchenRepository(Supabase.instance.client),
);

final kdsViewModelProvider = StateNotifierProvider<KdsViewModel, KdsState>(
  (ref) => KdsViewModel(ref.read(kitchenRepositoryProvider), ref),
);

/// 🍳 ViewModel del KDS
class KdsViewModel extends StateNotifier<KdsState> {
  final KitchenRepository _kitchenRepo;
  final Ref _ref;
  RealtimeChannel? _rtOrderItems;
  Timer? _reloadDebounce;
  Timer? _refreshTimer;
  String? _businessId;
  bool _loadingOrders = false;
  bool _loadOrdersQueued = false;

  KdsViewModel(this._kitchenRepo, this._ref) : super(const KdsState());

  /// Verifica si el usuario activo puede cambiar el estado de comandas.
  /// Setea el error en state y retorna false si no tiene permiso.
  bool _canChangeStatus() {
    if (_ref.read(sessionProvider.notifier).hasPermission('kds.cambiar_estado')) {
      return true;
    }
    state = state.copyWith(
      error: 'No tienes permiso para cambiar el estado de comandas.',
    );
    return false;
  }

  // ============================================================
  // 🚀 INICIALIZACIÓN
  // ============================================================

  /// Inicializar KDS
  Future<void> initialize({String? areaCode}) async {
    state = state.copyWith(loading: true, error: null, selectedArea: areaCode);

    try {
      _businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );
      // Cargar órdenes iniciales
      await loadOrders();

      // Cargar estadísticas
      await loadStats();

      // Suscribirse a cambios en tiempo real
      if (state.autoRefresh) {
        _subscribeToOrders();
      }

      // Timer para actualizar tiempos
      _startRefreshTimer();

      state = state.copyWith(loading: false);
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error al inicializar KDS: $e',
      );
    }
  }

  /// Cargar órdenes
  Future<void> loadOrders({bool force = false}) async {
    if (_loadingOrders && !force) {
      _loadOrdersQueued = true;
      return;
    }
    _loadingOrders = true;
    try {
      final orders = await _kitchenRepo.getActiveOrders(
        businessId: _businessId,
        areaCode: state.selectedArea,
      );

      state = state.copyWith(orders: orders);
    } catch (e) {
      state = state.copyWith(error: 'Error al cargar órdenes: $e');
    } finally {
      _loadingOrders = false;
      if (_loadOrdersQueued) {
        _loadOrdersQueued = false;
        unawaited(loadOrders());
      }
    }
  }

  /// Cargar estadísticas
  Future<void> loadStats() async {
    try {
      final stats = await _kitchenRepo.getKitchenStats(businessId: _businessId);
      final avgTime = await _kitchenRepo.getAveragePreparationTime(
        businessId: _businessId,
      );

      state = state.copyWith(stats: stats, averageTime: avgTime);
    } catch (e) {
      // No mostrar error, las estadísticas son opcionales
    }
  }

  // ============================================================
  // 🔔 SUSCRIPCIONES
  // ============================================================

  /// Suscribirse a cambios en tiempo real
  void _subscribeToOrders() {
    _rtOrderItems?.unsubscribe();
    _rtOrderItems =
        Supabase.instance.client.channel(
            'rt:kds_order_items:${_businessId ?? 'unknown'}',
          )
          ..onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'order_items',
            callback: _onRealtimeOrderItemChange,
          )
          ..subscribe();
  }

  /// Iniciar timer de actualización
  void _startRefreshTimer() {
    _refreshTimer?.cancel();

    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isPaused) {
        unawaited(loadOrders());
        unawaited(loadStats());
      }
    });
  }

  bool _isPaused = false;

  /// Pause background refresh when KDS view is not visible.
  void pauseRefresh() => _isPaused = true;

  /// Resume background refresh when KDS view becomes visible again.
  void resumeRefresh() {
    _isPaused = false;
    unawaited(loadOrders());
    unawaited(loadStats());
  }

  // ============================================================
  // 🔄 ACTUALIZAR ESTADOS
  // ============================================================

  /// Iniciar preparación de item
  Future<void> startPreparingItem(String itemId) async {
    if (!_canChangeStatus()) return;
    _applyLocalItemStatus(itemId, 'preparing');
    try {
      await _kitchenRepo.startPreparingItem(itemId);
      _scheduleReload();
    } catch (e) {
      _scheduleReload(immediate: true);
      state = state.copyWith(error: 'Error al iniciar preparación: $e');
    }
  }

  /// Marcar item como listo
  Future<void> markItemReady(String itemId) async {
    if (!_canChangeStatus()) return;
    _applyLocalItemStatus(itemId, 'ready');
    try {
      await _kitchenRepo.markItemReady(itemId);
      _scheduleReload();
    } catch (e) {
      _scheduleReload(immediate: true);
      state = state.copyWith(error: 'Error al marcar como listo: $e');
    }
  }

  /// Marcar item como servido
  Future<void> markItemServed(String itemId) async {
    if (!_canChangeStatus()) return;
    _removeItemLocally(itemId);
    try {
      await _kitchenRepo.markItemServed(itemId);
      _scheduleReload();
    } catch (e) {
      _scheduleReload(immediate: true);
      state = state.copyWith(error: 'Error al marcar como servido: $e');
    }
  }

  /// Marcar toda la orden como lista
  Future<void> markOrderReady(String orderId) async {
    if (!_canChangeStatus()) return;
    _applyLocalOrderStatus(
      orderId,
      from: {'pending', 'preparing'},
      to: 'ready',
    );
    try {
      await _kitchenRepo.markOrderReady(orderId);
      _scheduleReload();
    } catch (e) {
      _scheduleReload(immediate: true);
      state = state.copyWith(error: 'Error al marcar orden como lista: $e');
    }
  }

  // ============================================================
  // 🎛️ FILTROS Y CONFIGURACIÓN
  // ============================================================

  /// Cambiar área seleccionada
  void setSelectedArea(String? areaCode) {
    state = state.copyWith(selectedArea: areaCode);
    unawaited(loadOrders(force: true));
  }

  /// Cambiar filtro de estado
  void setSelectedStatus(String? status) {
    state = state.copyWith(selectedStatus: status);
  }

  /// Toggle sonido
  void toggleSound() {
    state = state.copyWith(soundEnabled: !state.soundEnabled);
  }

  /// Toggle auto-refresh
  void toggleAutoRefresh() {
    final newValue = !state.autoRefresh;
    state = state.copyWith(autoRefresh: newValue);

    if (newValue) {
      _subscribeToOrders();
      _startRefreshTimer();
      _scheduleReload(immediate: true);
    } else {
      _reloadDebounce?.cancel();
      _rtOrderItems?.unsubscribe();
      _rtOrderItems = null;
      _refreshTimer?.cancel();
    }
  }

  void _onRealtimeOrderItemChange(PostgresChangePayload payload) {
    final newRecord = payload.newRecord;
    final oldRecord = payload.oldRecord;
    final itemId = (newRecord['id'] ?? oldRecord['id'] ?? '').toString().trim();
    if (itemId.isEmpty) {
      _scheduleReload();
      return;
    }

    final newStatus = newRecord['status']?.toString();
    final handled = _applyRealtimeItemChange(
      itemId: itemId,
      newStatus: newStatus,
      newRecord: newRecord,
    );

    // Si el item no está en memoria, hacemos reload debounced
    // para traer órdenes nuevas sin bloquear la UI.
    if (!handled) {
      if (payload.eventType != PostgresChangeEvent.insert) {
        return;
      }
      if (state.soundEnabled && newStatus == 'pending') {
        _playNotificationSound();
      }
      _scheduleReload();
      return;
    }

    // Si cambia a estado terminal, recargamos en segundo plano para consistencia total.
    if (newStatus == 'served' || newStatus == 'void') {
      _scheduleReload();
    }
  }

  void _scheduleReload({bool immediate = false}) {
    _reloadDebounce?.cancel();
    if (immediate) {
      unawaited(loadOrders(force: true));
      unawaited(loadStats());
      return;
    }

    _reloadDebounce = Timer(const Duration(milliseconds: 260), () {
      unawaited(loadOrders());
      unawaited(loadStats());
    });
  }

  bool _applyRealtimeItemChange({
    required String itemId,
    required String? newStatus,
    required Map<String, dynamic> newRecord,
  }) {
    if (state.orders.isEmpty) return false;

    final shouldRemove =
        newStatus == null ||
        newStatus == 'served' ||
        newStatus == 'paid' ||
        newStatus == 'void';
    final startedAt = DateTime.tryParse(
      newRecord['started_at']?.toString() ?? '',
    );
    final readyAt = DateTime.tryParse(newRecord['ready_at']?.toString() ?? '');

    var found = false;
    final updatedOrders = <KitchenOrder>[];

    for (final order in state.orders) {
      final updatedItems = <KitchenItem>[];
      for (final item in order.items) {
        if (item.id != itemId) {
          updatedItems.add(item);
          continue;
        }
        found = true;
        if (shouldRemove) {
          continue;
        }
        updatedItems.add(
          item.copyWith(
            status: newStatus,
            startedAt: startedAt ?? item.startedAt,
            readyAt: readyAt ?? item.readyAt,
          ),
        );
      }

      if (updatedItems.isNotEmpty) {
        updatedOrders.add(
          KitchenOrder(
            orderId: order.orderId,
            orderNumber: order.orderNumber,
            tableName: order.tableName,
            waiterName: order.waiterName,
            createdAt: order.createdAt,
            items: updatedItems,
          ),
        );
      }
    }

    if (!found) return false;

    state = state.copyWith(
      orders: updatedOrders,
      stats: _statsFromOrders(updatedOrders),
    );
    return true;
  }

  void _applyLocalItemStatus(String itemId, String toStatus) {
    final now = DateTime.now();
    var changed = false;
    final updatedOrders = <KitchenOrder>[];

    for (final order in state.orders) {
      final updatedItems = order.items
          .map((item) {
            if (item.id != itemId) return item;
            changed = true;
            return item.copyWith(
              status: toStatus,
              startedAt: toStatus == 'preparing'
                  ? (item.startedAt ?? now)
                  : item.startedAt,
              readyAt: toStatus == 'ready' ? now : item.readyAt,
            );
          })
          .toList(growable: false);

      if (updatedItems.isNotEmpty) {
        updatedOrders.add(
          KitchenOrder(
            orderId: order.orderId,
            orderNumber: order.orderNumber,
            tableName: order.tableName,
            waiterName: order.waiterName,
            createdAt: order.createdAt,
            items: updatedItems,
          ),
        );
      }
    }

    if (!changed) return;
    state = state.copyWith(
      orders: updatedOrders,
      stats: _statsFromOrders(updatedOrders),
      error: null,
    );
  }

  void _removeItemLocally(String itemId) {
    var changed = false;
    final updatedOrders = <KitchenOrder>[];

    for (final order in state.orders) {
      final updatedItems = order.items
          .where((item) {
            final keep = item.id != itemId;
            if (!keep) changed = true;
            return keep;
          })
          .toList(growable: false);

      if (updatedItems.isNotEmpty) {
        updatedOrders.add(
          KitchenOrder(
            orderId: order.orderId,
            orderNumber: order.orderNumber,
            tableName: order.tableName,
            waiterName: order.waiterName,
            createdAt: order.createdAt,
            items: updatedItems,
          ),
        );
      }
    }

    if (!changed) return;
    state = state.copyWith(
      orders: updatedOrders,
      stats: _statsFromOrders(updatedOrders),
      error: null,
    );
  }

  void _applyLocalOrderStatus(
    String orderId, {
    required Set<String> from,
    required String to,
  }) {
    final now = DateTime.now();
    var changed = false;
    final updatedOrders = <KitchenOrder>[];

    for (final order in state.orders) {
      final updatedItems = order.items
          .map((item) {
            if (item.orderId != orderId || !from.contains(item.status)) {
              return item;
            }
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

      if (updatedItems.isNotEmpty) {
        updatedOrders.add(
          KitchenOrder(
            orderId: order.orderId,
            orderNumber: order.orderNumber,
            tableName: order.tableName,
            waiterName: order.waiterName,
            createdAt: order.createdAt,
            items: updatedItems,
          ),
        );
      }
    }

    if (!changed) return;
    state = state.copyWith(
      orders: updatedOrders,
      stats: _statsFromOrders(updatedOrders),
      error: null,
    );
  }

  Map<String, int> _statsFromOrders(List<KitchenOrder> orders) {
    final items = orders.expand((o) => o.items);
    var pending = 0;
    var preparing = 0;
    var ready = 0;
    var total = 0;

    for (final item in items) {
      total++;
      if (item.isPending) pending++;
      if (item.isPreparing) preparing++;
      if (item.isReady) ready++;
    }

    return {
      'pending': pending,
      'preparing': preparing,
      'ready': ready,
      'total': total,
    };
  }

  // ============================================================
  // 🔧 UTILIDADES
  // ============================================================

  /// Reproducir sonido de notificación
  void _playNotificationSound() {
    // En producción, usar package como audioplayers
    // AudioPlayer().play(AssetSource('sounds/notification.mp3'));
  }

  /// Limpiar recursos
  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _rtOrderItems?.unsubscribe();
    _rtOrderItems = null;
    _refreshTimer?.cancel();
    super.dispose();
  }
}
