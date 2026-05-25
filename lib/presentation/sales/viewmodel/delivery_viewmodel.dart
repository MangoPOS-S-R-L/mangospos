import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/utils/business_id_resolver.dart';
import '../state/delivery_state.dart';
import 'sales_viewmodel.dart';

final deliveryVmProvider =
    NotifierProvider<DeliveryViewModel, DeliveryState>(DeliveryViewModel.new);

class DeliveryViewModel extends Notifier<DeliveryState> {
  RealtimeChannel? _rt;
  String? _rtBusinessId;
  Timer? _debounce;

  static const _debounceDuration = Duration(milliseconds: 400);

  @override
  DeliveryState build() {
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
    state = state.copyWith(loading: true, error: null);

    try {
      final bizId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        businessId,
      );
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

      state = state.copyWith(
        orders: rows.map(DeliveryOrderSummary.fromMap).toList(),
        loading: false,
        businessId: bizId,
      );

      _subscribeRealtime(bizId);
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> refresh() async {
    final bizId = state.businessId;
    if (bizId == null) return;
    await load(bizId);
  }

  Future<Map<String, dynamic>> createOrder(String deliveryType) async {
    final result = await ref
        .read(salesRepositoryProvider)
        .openDeliveryOrder(deliveryType: deliveryType);
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
