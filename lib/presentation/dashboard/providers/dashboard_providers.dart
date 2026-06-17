// Providers Riverpod para los widgets de la Fase A del dashboard.
//
// Convención:
//   - Cada widget tiene su propio FutureProvider scoped al business activo.
//   - Si no hay business activo, el provider devuelve lista vacía (no error)
//     para que el dashboard renderice "Sin datos" en vez de crashear.
//   - Datos derivados de session via `sessionProvider.activeBusinessId`.
//   - Auto-refresca cuando el usuario cambia de business (la family invalida).

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline/dashboard_kpis_offline_cache.dart';
import '../../../core/offline/offline_pos_service.dart';
import '../../../data/models/dashboard_models.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../inventory/viewmodel/inventory_viewmodel.dart'
    show inventoryRepositoryProvider;
import '../../sales/viewmodel/sales_viewmodel.dart'
    show salesRepositoryProvider;
import '../../../services/session/session_controller.dart';

/// Rango "hoy" (00:00 AST hasta ahora) — el dashboard de la Fase A
/// muestra métricas del día actual. Mantenemos el cálculo aquí para que
/// si el usuario abre el dashboard cruzando medianoche, el provider
/// se reinvalide con el nuevo "hoy".
({DateTime from, DateTime to}) _todayRange() {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  return (from: start, to: start.add(const Duration(days: 1)));
}

/// Top N productos vendidos hoy. N viaja como argumento del family.
final dashboardTopProductsProvider =
    FutureProvider.autoDispose.family<List<DashboardTopProduct>, int>(
  (ref, limit) async {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return const [];
    final range = _todayRange();
    final repo = ref.watch(salesRepositoryProvider);
    final rows = await repo.getTopSellingProducts(
      businessId: businessId,
      from: range.from,
      to: range.to,
      limit: limit,
    );
    return rows.map(DashboardTopProduct.fromMap).toList(growable: false);
  },
);

/// Últimas N órdenes del business. N viaja como argumento del family.
final dashboardRecentOrdersProvider =
    FutureProvider.autoDispose.family<List<DashboardRecentOrder>, int>(
  (ref, limit) async {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return const [];
    final repo = ref.watch(salesRepositoryProvider);
    final rows = await repo.getRecentOrders(
      businessId: businessId,
      limit: limit,
    );
    return rows.map(DashboardRecentOrder.fromMap).toList(growable: false);
  },
);

/// Alertas de stock bajo. Reusa `InventoryRepository.getLowStockAlerts`
/// que ya existe (lee vista `v_inventory_low_stock`). Limitamos por
/// default a 4 — más de eso satura el card.
final dashboardInventoryAlertsProvider =
    FutureProvider.autoDispose.family<List<DashboardInventoryAlert>, int>(
  (ref, limit) async {
    final businessId = ref.watch(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return const [];
    final InventoryRepository repo = ref.watch(inventoryRepositoryProvider);
    final rows = await repo.getLowStockAlerts(
      businessId: businessId,
      limit: limit,
    );
    return rows.map(DashboardInventoryAlert.fromMap).toList(growable: false);
  },
);

/// KPIs del "Order Summary" — hoy vs ayer (mismo tramo del día). El
/// rango de "ayer" se calcula como `[ayer 00:00, ayer 00:00 + elapsed)`
/// donde `elapsed = ahora - hoy 00:00`. De esa forma la comparación
/// nunca incluye horas futuras de ayer (ej. si son las 2pm, compara
/// 0-2pm hoy vs 0-2pm ayer).
final dashboardKpisProvider =
    FutureProvider.autoDispose<DashboardKpis>((ref) async {
  final businessId = ref.watch(sessionProvider).activeBusinessId;
  if (businessId == null || businessId.isEmpty) return DashboardKpis.empty;

  final now = DateTime.now();
  final todayFrom = DateTime(now.year, now.month, now.day);
  final todayTo = now;
  final yesterdayFrom = todayFrom.subtract(const Duration(days: 1));
  final yesterdayTo = yesterdayFrom.add(now.difference(todayFrom));

  final repo = ref.watch(salesRepositoryProvider);
  final cache = DashboardKpisOfflineCache();

  try {
    // Online: fuente de verdad (RPC). Cacheamos el snapshot para servirlo sin
    // conexión más adelante.
    final rows = await repo.getDashboardKpis(
      businessId: businessId,
      todayFrom: todayFrom,
      todayTo: todayTo,
      yesterdayFrom: yesterdayFrom,
      yesterdayTo: yesterdayTo,
    );
    final kpis = DashboardKpis.fromRpcRows(rows);
    await cache.save(businessId: businessId, kpisMap: kpis.toCacheMap());
    return kpis;
  } catch (e) {
    // Sin conexión (o RPC falló): último snapshot sincronizado + las ventas
    // hechas offline hoy (cola local). Así la tira no se rompe y refleja la
    // actividad offline. Si no hay snapshot, partimos de cero y mostramos solo
    // lo offline.
    debugPrint('dashboardKpisProvider offline fallback: $e');
    final cached = await cache.load(businessId: businessId);
    final base = cached != null
        ? DashboardKpis.fromCacheMap(cached.kpisMap)
        : DashboardKpis.empty;

    final delta = await OfflinePosService().todayPendingSalesDelta(
      businessId: businessId,
      dayStart: todayFrom,
      dayEnd: todayFrom.add(const Duration(days: 1)),
    );

    final mergedToday = base.today.plus(
      income: delta.income,
      itemsSold: delta.itemsSold,
      ordersTotal: delta.ordersTotal,
      ordersCompleted: delta.ordersCompleted,
      ordersInProgress: delta.ordersInProgress,
    );

    return DashboardKpis(
      today: mergedToday,
      yesterday: base.yesterday,
      cachedAt: cached?.savedAt ?? now,
    );
  }
});
