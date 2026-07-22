import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/zones_repository.dart';
import 'package:mangopos/services/fiscal/fiscal_service.dart';
import 'package:mangopos/services/session/session_controller.dart';

import 'catalog_refresh_service.dart';
import 'ncf_offline_allocator.dart' show kOfflineNcfEnabled;
import 'ncf_range_service.dart';
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
/// - config    → [PosSettingsRepository.refreshBusinessSettings] (F6-3)
///
/// El roster ya baja por su cuenta (OfflineAuthService.startBackgroundSync).
/// Fiscal/seed NCF quedan para más adelante (aún sin cache offline propio).
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
  Future<void> Function(String businessId)? refreshConfig,
  Future<void> Function(String businessId)? refreshPrinters,
  Future<void> Function(String businessId)? refreshFiscalSequences,
  Future<void> Function(String businessId)? refreshNcfSeed,
}) {
  // Resuelto perezosamente: solo se toca Supabase.instance si de verdad corre
  // un refresher por defecto (en test se inyectan todos y no se toca).
  SupabaseClient resolveClient() => client ?? Supabase.instance.client;
  final catalog = refreshCatalog ??
      (String b) => CatalogRefreshService(resolveClient()).refresh(b);
  final zones = refreshZones ??
      (String b) async {
        await ZonesRepository(resolveClient()).fetchZones(b);
      };
  final inventory = refreshInventory ??
      (String b) => _refreshInventoryMainWarehouse(resolveClient(), b);
  final config = refreshConfig ??
      (String b) =>
          PosSettingsRepository(resolveClient()).refreshBusinessSettings(b);
  // Impresoras por área: sin este prewarm periódico, un área configurada
  // DESPUÉS del login (típico: asignar la USB y probar) no tenía cache y
  // "Enviar a cocina" offline fallaba con "No hay impresora asignada".
  final printers = refreshPrinters ??
      (String b) async {
        await PrintingService(resolveClient()).prewarmPrinterCache(
          businessId: b,
        );
      };
  // Secuencias NCF: getSequences cachea en disco como efecto secundario;
  // sin esto el modal de cobro offline decía "no hay secuencias fiscales
  // activas" si nunca se había abierto una orden online en este device.
  final fiscalSequences = refreshFiscalSequences ??
      (String b) async {
        await FiscalService().getSequences(b);
      };

  Future<void> Function() guard(Future<void> Function(String) fn) {
    return () async {
      final businessId = resolveBusinessId();
      if (businessId == null || businessId.isEmpty) return;
      await fn(businessId);
    };
  }

  final refreshers = [
    guard(catalog),
    guard(zones),
    guard(inventory),
    guard(config),
    guard(printers),
    guard(fiscalSequences),
  ];

  // Semilla NCF (F4): cachea la serie central offline para que el Hub conozca
  // current_number al caer la red. Solo se agrega con F4 encendido (o si el
  // test lo inyecta), así no añade tráfico cuando la emisión offline está off.
  if (kOfflineNcfEnabled || refreshNcfSeed != null) {
    final ncfSeed = refreshNcfSeed ??
        (String b) => NcfRangeService(resolveClient()).refreshAllSeries(b);
    refreshers.add(guard(ncfSeed));
  }

  return refreshers;
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
