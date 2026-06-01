import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/zones_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';

import 'catalog_refresh_service.dart';
import 'offline_sync_coordinator.dart';

/// Resuelve el negocio activo en el momento de correr (no al construir).
typedef BusinessIdResolver = String? Function();

/// Composición de los refreshers de BAJADA (server → device) para F6: catálogo,
/// zonas e inventario del negocio ACTIVO. Cada uno resuelve el businessId al
/// correr, así un solo coordinador sirve aunque cambie el negocio; si no hay
/// sesión abierta el refresher es no-op.
///
/// Reusa los caminos `fetch+cache` que ya existen:
/// - catálogo  → [CatalogRefreshService]
/// - zonas     → [ZonesRepository.fetchZones] (cachea como efecto secundario)
/// - inventario→ [InventoryRepository.getItems] de la bodega principal
///
/// El roster ya baja por su cuenta (OfflineAuthService.startBackgroundSync) y
/// config/fiscal/NCF quedan para F6-3 (aún no tienen cache offline propio).
///
/// Los `refresh*` son inyectables para test; en producción usan los servicios
/// reales. El best-effort (capturar errores por refresher) lo hace el
/// [OfflineSyncCoordinator], no esta capa.
List<Future<void> Function()> buildOfflineRefreshers({
  required BusinessIdResolver resolveBusinessId,
  SupabaseClient? client,
  Future<void> Function(String businessId)? refreshCatalog,
  Future<void> Function(String businessId)? refreshZones,
  Future<void> Function(String businessId)? refreshInventory,
}) {
  // Resuelto perezosamente: solo se toca Supabase.instance si de verdad corre
  // un refresher por defecto (en test se inyectan los tres y no se toca).
  SupabaseClient resolveClient() => client ?? Supabase.instance.client;
  final catalog = refreshCatalog ??
      (String b) => CatalogRefreshService(resolveClient()).refresh(b);
  final zones = refreshZones ??
      (String b) async {
        await ZonesRepository(resolveClient()).fetchZones(b);
      };
  final inventory = refreshInventory ??
      (String b) => _refreshInventoryMainWarehouse(resolveClient(), b);

  Future<void> Function() guard(Future<void> Function(String) fn) {
    return () async {
      final businessId = resolveBusinessId();
      if (businessId == null || businessId.isEmpty) return;
      await fn(businessId);
    };
  }

  return [guard(catalog), guard(zones), guard(inventory)];
}

/// Refresca el inventario de la bodega principal (la primera que devuelve
/// [InventoryRepository.getWarehouses], ordenada `is_main` primero). Es la que
/// usa la caja; refrescar todas sería caro y de poco valor offline.
Future<void> _refreshInventoryMainWarehouse(
  SupabaseClient client,
  String businessId,
) async {
  final repo = InventoryRepository(client);
  final warehouses = await repo.getWarehouses(businessId);
  if (warehouses.isEmpty) return;
  // getItems hidrata el InventoryOfflineCache como efecto secundario.
  await repo.getItems(businessId: businessId, warehouseId: warehouses.first.id);
}

/// Coordinador de bajada vivo durante la sesión de la app. Refresca los caches
/// de lectura al reconectar (offline→online) y periódicamente. Se mantiene vivo
/// leyéndolo desde el shell (igual que `hubModeProvider`). Provider
/// no-autoDispose: se crea una vez y se limpia al cerrar el container.
final offlineSyncCoordinatorProvider =
    Provider<OfflineSyncCoordinator>((ref) {
  final coordinator = OfflineSyncCoordinator(
    connectionStream: ConnectivityService().connectionStream,
    refreshers: buildOfflineRefreshers(
      resolveBusinessId: () => ref.read(sessionProvider).activeBusinessId,
    ),
  )..start();
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
