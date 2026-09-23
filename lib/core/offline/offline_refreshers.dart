import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show ChangeNotifierProvider;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/repositories/zones_repository.dart';
import 'package:mangopos/services/fiscal/fiscal_service.dart';
import 'package:mangopos/services/session/session_controller.dart';

import 'package:mangopos/data/repositories/sales_repository.dart';

import 'catalog_refresh_service.dart';
import 'offline_catalog_service.dart';
import '../auth/offline_auth_service.dart';
import 'offline_cache_pruner.dart';
import 'ncf_offline_allocator.dart' show kOfflineNcfEnabled;
import 'ncf_range_service.dart';
import 'offline_sync_coordinator.dart';
import 'pos_lookup_offline_cache.dart';

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
  Future<void> Function(String businessId)? refreshPosLookups,
  Future<void> Function(String businessId)? refreshAuth,
}) {
  // Resuelto perezosamente: solo se toca Supabase.instance si de verdad corre
  // un refresher por defecto (en test se inyectan todos y no se toca).
  SupabaseClient resolveClient() => client ?? Supabase.instance.client;
  final catalog =
      refreshCatalog ??
      (String b) => CatalogRefreshService(resolveClient()).refresh(b);
  // Zonas + las MESAS de cada zona. Bajar solo las zonas dejaba el floor map y
  // el modal de asignar a mesa sin geometría en un arranque en frío: el cajero
  // veía sus zonas pero ninguna mesa dentro. Son pocas zonas por local (una
  // consulta por zona), y ambas lecturas cachean como efecto secundario.
  final zones =
      refreshZones ??
      (String b) async {
        final repo = ZonesRepository(resolveClient());
        final list = await repo.fetchZones(b, includeVirtualSalesZones: true);
        var failed = false;
        for (final zone in list) {
          try {
            await repo.fetchTablesByZone(zone.id);
          } catch (e) {
            failed = true;
            debugPrint('[offline] mesas de la zona ${zone.id} no bajaron: $e');
          }
        }
        if (failed) throw StateError('No se descargaron todas las mesas.');
      };
  final inventory =
      refreshInventory ??
      (String b) => _refreshInventoryMainWarehouse(resolveClient(), b);
  final config =
      refreshConfig ??
      (String b) =>
          PosSettingsRepository(resolveClient()).refreshBusinessSettings(b);
  // Impresoras por área: sin este prewarm periódico, un área configurada
  // DESPUÉS del login (típico: asignar la USB y probar) no tenía cache y
  // "Enviar a cocina" offline fallaba con "No hay impresora asignada".
  final printers =
      refreshPrinters ??
      (String b) async {
        await PrintingService(
          resolveClient(),
        ).prewarmPrinterCache(businessId: b, failOnError: true);
      };
  // Secuencias NCF: getSequences cachea en disco como efecto secundario;
  // sin esto el modal de cobro offline decía "no hay secuencias fiscales
  // activas" si nunca se había abierto una orden online en este device.
  final fiscalSequences =
      refreshFiscalSequences ??
      (String b) async {
        await FiscalService().getSequences(b);
      };

  // Impuestos + modificadores de todos los productos: el POS los pide ANTES de
  // dejar agregar un producto o cobrar. Sin copia en disco, la caída de red
  // del 2026-09-19 dejó productos que no entraban y cobros bloqueados por
  // "error de impuestos". Ver [PosLookupOfflineCache].
  final posLookups =
      refreshPosLookups ?? (String b) => _refreshPosLookups(resolveClient(), b);

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
    guard(posLookups),
    if (refreshAuth != null) guard(refreshAuth),
  ];

  // Semilla NCF (F4): cachea la serie central offline para que el Hub conozca
  // current_number al caer la red. Solo se agrega con F4 encendido (o si el
  // test lo inyecta), así no añade tráfico cuando la emisión offline está off.
  if (kOfflineNcfEnabled || refreshNcfSeed != null) {
    final ncfSeed =
        refreshNcfSeed ??
        (String b) => NcfRangeService(resolveClient()).refreshAllSeries(b);
    refreshers.add(guard(ncfSeed));
  }

  return refreshers;
}

Future<void> _refreshPosLookups(
  SupabaseClient client,
  String businessId,
) async {
  final cache = PosLookupOfflineCache();
  // Mismas columnas que SalesViewModel._ensureBusinessTaxSettingsLoaded.
  final taxRows = await client
      .from('taxes')
      .select(
        'id,name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery,apply_on_takeout,include_in_ecf',
      )
      .eq('business_id', businessId)
      .eq('is_active', true);
  await cache.saveBusinessTaxes(
    businessId,
    List<Map<String, dynamic>>.from(taxRows),
  );

  final byItem = await SalesRepository(
    client,
  ).getModifierGroupsByItemForBusiness(businessId);
  final catalog = await OfflineCatalogService().loadSnapshot(businessId);
  if (catalog == null) throw StateError('Falta el catálogo local.');
  final products = catalog.products;
  await cache.replaceAllModifierGroups(
    businessId,
    byItem,
    itemsWithoutGroups: products
        .map((p) => p['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty && !byItem.containsKey(id)),
  );
  final sales = SalesRepository(client);
  for (final product in products.where((p) => p['item_type'] == 'combo')) {
    final id = product['id'].toString();
    final groups = await sales.getComboGroupsForMenuItem(id);
    await cache.saveComboGroups(businessId, id, groups);
  }

  // Razones de gastos/ingresos: la pantalla las exige para registrar uno.
  final reasons = await CashierRepository(
    client,
  ).getCashTransactionReasons(businessId: businessId);
  await cache.saveCashReasons(businessId, reasons);
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
/// Se recrea al cambiar de negocio y se limpia al cerrar el container.
const offlineDownloadLabels = [
  'Productos y precios',
  'Zonas y mesas',
  'Inventario',
  'Configuración',
  'Impresoras',
  'Secuencias fiscales',
  'Impuestos y opciones',
  'Acceso con PIN',
  'Reserva fiscal',
];

final offlineSyncCoordinatorProvider = ChangeNotifierProvider<OfflineSyncCoordinator>(
  (ref) {
    // Un ciclo pertenece a un solo negocio, incluso si la sesión cambia
    // mientras una consulta está en vuelo.
    final businessId = ref.watch(
      sessionProvider.select((s) => s.activeBusinessId),
    );
    // Poda de arranque: borra los caches de LECTURA de negocios que este equipo
    // ya no usa. Medido en campo, eran el 86% de un plist de 34 MB que
    // SharedPreferences carga entero en memoria en cada arranque. Una sola vez,
    // best-effort y fuera del camino crítico; nunca toca borradores, cola,
    // mapas, op-log ni roster. Ver [OfflineCachePruner].
    final pruneTimer = Timer(const Duration(seconds: 12), () {
      if (businessId == null ||
          businessId.isEmpty ||
          ref.read(sessionProvider).activeBusinessId != businessId) {
        return;
      }
      unawaited(OfflineCachePruner().pruneOtherBusinesses(businessId));
    });

    ref.onDispose(pruneTimer.cancel);

    final connectivity = ConnectivityService();
    final coordinator = OfflineSyncCoordinator(
      connectionStream: connectivity.connectionStream,
      // Lectura en vivo: el stream solo emite en los CAMBIOS, así que un equipo
      // que nace online y no pierde la red nunca recibía nada por él y no
      // sembraba un solo cache. Ver la nota en OfflineSyncCoordinator.
      isConnectedNow: () => connectivity.isConnected,
      refreshers: buildOfflineRefreshers(
        resolveBusinessId: () => businessId,
        refreshAuth: (bid) async {
          final auth = OfflineAuthService();
          if (!await auth.isDeviceBound() ||
              await auth.currentBoundBusinessId() != bid) {
            // Es configuración pendiente, no un fallo de descarga. El
            // inspector muestra la vinculación y su acción correspondiente.
            return;
          }
          await auth.syncRoster();
        },
      ),
    )..start();
    return coordinator;
  },
);
