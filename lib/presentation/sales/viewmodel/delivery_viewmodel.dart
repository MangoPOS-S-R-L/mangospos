import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/utils/business_id_resolver.dart';
import '../state/delivery_state.dart';
import '../../../services/session/session_controller.dart';
import 'sales_viewmodel.dart';

final deliveryVmProvider = NotifierProvider<DeliveryViewModel, DeliveryState>(
  DeliveryViewModel.new,
);

class DeliveryViewModel extends Notifier<DeliveryState> {
  RealtimeChannel? _rt;
  String? _rtBusinessId;
  Timer? _debounce;
  int _loadGeneration = 0;

  static const _debounceDuration = Duration(milliseconds: 400);

  @override
  DeliveryState build() {
    ref.listen(sessionProvider.select((s) => s.activeBusinessId), (
      previous,
      next,
    ) {
      if (previous == next) return;
      ++_loadGeneration;
      _debounce?.cancel();
      _rt?.unsubscribe();
      _rt = null;
      _rtBusinessId = null;
      state = const DeliveryState();
      if (next != null && next.isNotEmpty) unawaited(load(next));
    });
    ref.onDispose(() {
      _rt?.unsubscribe();
      _rt = null;
      _rtBusinessId = null;
      _debounce?.cancel();
      _debounce = null;
    });
    return const DeliveryState();
  }

  Future<void> load(String businessId) async {
    final generation = ++_loadGeneration;
    state = state.copyWith(loading: true, error: null);

    try {
      final bizId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        businessId,
      );
      if (generation != _loadGeneration) return;
      if (bizId == null) {
        state = state.copyWith(
          loading: false,
          error: 'No se pudo resolver el negocio.',
        );
        return;
      }

      final rows = await ref
          .read(salesRepositoryProvider)
          .listDeliveryOrders(businessId: bizId);

      if (generation != _loadGeneration) return;

      state = state.copyWith(
        orders: rows.map(DeliveryOrderSummary.fromMap).toList(),
        loading: false,
        businessId: bizId,
      );

      _subscribeRealtime(bizId);
    } catch (e) {
      if (generation != _loadGeneration) return;
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> refresh() async {
    final bizId = state.businessId;
    if (bizId == null) return;
    await load(bizId);
  }

  Future<Map<String, dynamic>> createOrder(String deliveryType) async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      throw StateError('No se pudo identificar el negocio del delivery.');
    }
    // Sin la migración 20261009_0004, solo un usuario con un único negocio
    // puede usar la firma vieja: el servidor no tiene otro que elegir.
    final businesses = session.availableBusinesses;
    final singleBusiness =
        businesses.length == 1 && businesses.single.id == businessId;
    final result = await ref
        .read(salesRepositoryProvider)
        .openDeliveryOrder(
          deliveryType: deliveryType,
          businessId: businessId,
          allowLegacyBusinessFallback: singleBusiness,
        );
    // Refrescar la lista tras crear
    unawaited(refresh());
    return result;
  }

  Future<void> closeOrder(String orderId, {String status = 'paid'}) async {
    await ref
        .read(salesRepositoryProvider)
        .closeDeliveryOrder(orderId: orderId, status: status);
    unawaited(refresh());
  }

  void _subscribeRealtime(String businessId) {
    if (_rt != null && _rtBusinessId == businessId) return;
    _rt?.unsubscribe();

    // PRD 7 Fase 4.1 — `filter: business_id=eq.X` server-side donde la
    // columna existe (table_sessions). `orders` y `order_items` no
    // tienen business_id directo; el aislamiento depende de RLS + el
    // nombre del channel scoped por businessId.
    _rt = Supabase.instance.client
        .channel('delivery_orders_$businessId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'table_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'business_id',
            value: businessId,
          ),
          callback: (_) => _queueRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          // orders.business_id no existe — scope vía session_id → RLS.
          callback: (_) => _queueRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_items',
          // order_items.business_id no existe — scope vía order_id → RLS.
          callback: (_) => _queueRefresh(),
        )
        .subscribe();

    _rtBusinessId = businessId;
  }

  void _queueRefresh() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () => unawaited(refresh()));
  }
}
