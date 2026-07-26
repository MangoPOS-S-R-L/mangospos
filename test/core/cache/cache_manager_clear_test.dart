import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/cache/cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Contrato de "Limpiar caché del sistema":
///   - borra datos cacheados Y configuración cacheada (impresoras asignadas,
///     nombre del negocio, secuencias NCF, ajustes del negocio, caja),
///   - NO toca sesión, cola offline, snapshots de órdenes, roster de
///     empleados ni configuración de Hub (eso rompería offline / LAN).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const clearedKeys = [
    // Datos genéricos del CacheManager.
    'cache_products_main',
    'metadata_cache_products_main',
    'hash_products',
    'offline_catalog_biz1',
    'printing_cached_printers_biz1',
    // Configuración cacheada (lo nuevo).
    'printing_assigned_printer_biz1|kitchen_hot',
    'printing_business_name_biz1',
    'fiscal_sequences_cache_biz1',
    'offline_business_settings_biz1',
    'cashier_register_biz1',
    'print_agent_url',
  ];

  const preservedKeys = [
    'active_business_id',
    'offline_queue_biz1',
    'offline_snapshot_biz1_mesa4',
    'offline_order_map_biz1',
    'mp_offline_roster_biz1',
    'hub_primary_url_biz1',
    'hub_device_role_biz1',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({
      for (final k in clearedKeys) k: 'valor',
      for (final k in preservedKeys) k: 'valor',
    });
  });

  test('borra cache + configuración cacheada y preserva sesión/offline/hub',
      () async {
    final result = await CacheManager().clearSystemCache();

    final prefs = await SharedPreferences.getInstance();
    for (final key in clearedKeys) {
      expect(prefs.getString(key), isNull, reason: 'debió borrar $key');
    }
    for (final key in preservedKeys) {
      expect(
        prefs.getString(key),
        'valor',
        reason: 'NO debió borrar $key',
      );
    }
    expect(result.deletedCount, greaterThanOrEqualTo(clearedKeys.length));
  });
}
