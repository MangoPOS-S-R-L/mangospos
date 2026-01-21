import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/kitchen_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/kds_state.dart';

// Provider
final kitchenRepositoryProvider = Provider<KitchenRepository>(
  (ref) => KitchenRepository(Supabase.instance.client),
);

final kdsViewModelProvider = StateNotifierProvider<KdsViewModel, KdsState>(
  (ref) => KdsViewModel(ref.read(kitchenRepositoryProvider)),
);

/// 🍳 ViewModel del KDS
class KdsViewModel extends StateNotifier<KdsState> {
  final KitchenRepository _kitchenRepo;
  StreamSubscription? _ordersSubscription;
  Timer? _refreshTimer;
  String? _businessId;

  KdsViewModel(this._kitchenRepo) : super(const KdsState());

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
  Future<void> loadOrders() async {
    try {
      final orders = await _kitchenRepo.getActiveOrders(
        businessId: _businessId,
        areaCode: state.selectedArea,
      );

      state = state.copyWith(orders: orders);
    } catch (e) {
      state = state.copyWith(error: 'Error al cargar órdenes: $e');
    }
  }

  /// Cargar estadísticas
  Future<void> loadStats() async {
    try {
      final stats = await _kitchenRepo.getKitchenStats(
        businessId: _businessId,
      );
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
    _ordersSubscription?.cancel();

    _ordersSubscription = _kitchenRepo
        .subscribeToNewOrders(areaCode: state.selectedArea)
        .listen(
          (newOrder) {
            // Agregar nueva orden a la lista
            final updatedOrders = [...state.orders];

            // Verificar si ya existe
            final existingIndex = updatedOrders.indexWhere(
              (o) => o.orderId == newOrder.orderId,
            );

            if (existingIndex >= 0) {
              updatedOrders[existingIndex] = newOrder;
            } else {
              updatedOrders.insert(0, newOrder);

              // Reproducir sonido si está habilitado
              if (state.soundEnabled) {
                _playNotificationSound();
              }
            }

            state = state.copyWith(orders: updatedOrders);

            // Actualizar estadísticas
            loadStats();
          },
          onError: (error) {
            state = state.copyWith(error: 'Error en suscripción: $error');
          },
        );
  }

  /// Iniciar timer de actualización
  void _startRefreshTimer() {
    _refreshTimer?.cancel();

    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      loadOrders();
      loadStats();
    });
  }

  // ============================================================
  // 🔄 ACTUALIZAR ESTADOS
  // ============================================================

  /// Iniciar preparación de item
  Future<void> startPreparingItem(String itemId) async {
    try {
      await _kitchenRepo.startPreparingItem(itemId);
      await loadOrders();
    } catch (e) {
      state = state.copyWith(error: 'Error al iniciar preparación: $e');
    }
  }

  /// Marcar item como listo
  Future<void> markItemReady(String itemId) async {
    try {
      await _kitchenRepo.markItemReady(itemId);
      await loadOrders();
    } catch (e) {
      state = state.copyWith(error: 'Error al marcar como listo: $e');
    }
  }

  /// Marcar item como servido
  Future<void> markItemServed(String itemId) async {
    try {
      await _kitchenRepo.markItemServed(itemId);
      await loadOrders();
    } catch (e) {
      state = state.copyWith(error: 'Error al marcar como servido: $e');
    }
  }

  /// Marcar toda la orden como lista
  Future<void> markOrderReady(String orderId) async {
    try {
      await _kitchenRepo.markOrderReady(orderId);
      await loadOrders();
    } catch (e) {
      state = state.copyWith(error: 'Error al marcar orden como lista: $e');
    }
  }

  // ============================================================
  // 🎛️ FILTROS Y CONFIGURACIÓN
  // ============================================================

  /// Cambiar área seleccionada
  void setSelectedArea(String? areaCode) {
    state = state.copyWith(selectedArea: areaCode);
    loadOrders();
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
    } else {
      _ordersSubscription?.cancel();
      _refreshTimer?.cancel();
    }
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
    _ordersSubscription?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }
}
