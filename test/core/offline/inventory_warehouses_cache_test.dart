// Copia local de las bodegas: es el primer eslabón del arranque cache-first.
//
// Los snapshots de items se guardan por (negocio, bodega), así que sin saber
// qué bodegas existen no se pueden leer. Si esta copia falla o devuelve
// basura, Insumos vuelve a esperar la red y el esqueleto se queda largo.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/inventory_offline_cache.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = InventoryOfflineCache();
  const businessId = 'biz-1';

  final rows = <Map<String, dynamic>>[
    {'id': 'w1', 'name': 'Bodega Principal', 'is_main': true},
    {'id': 'w2', 'name': 'Bar', 'is_main': false},
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('sin copia guardada devuelve null, no una lista vacía', () async {
    expect(await cache.loadWarehousesSnapshot('negocio-sin-copia'), isNull);
  });

  test('ida y vuelta conserva id, nombre y is_main', () async {
    await cache.saveWarehousesSnapshot(businessId: businessId, rows: rows);
    final loaded = await cache.loadWarehousesSnapshot(businessId);

    expect(loaded, isNotNull);
    expect(loaded!.length, 2);
    expect(loaded[0]['id'], 'w1');
    expect(loaded[0]['name'], 'Bodega Principal');
    expect(loaded[0]['is_main'], true);
    expect(loaded[1]['id'], 'w2');
  });

  test('la copia es por negocio: otro negocio no la ve', () async {
    await cache.saveWarehousesSnapshot(businessId: businessId, rows: rows);
    expect(await cache.loadWarehousesSnapshot('otro-negocio'), isNull);
  });

  test('un valor corrupto devuelve null en vez de tirar', () async {
    final storage = await StorageService.getInstance();
    await storage.write(
      'offline_inventory_warehouses_$businessId',
      'esto no es json',
    );
    expect(await cache.loadWarehousesSnapshot(businessId), isNull);
  });

  test('un JSON válido que no es lista tampoco tira', () async {
    final storage = await StorageService.getInstance();
    await storage.write(
      'offline_inventory_warehouses_$businessId',
      '{"no":"es una lista"}',
    );
    expect(await cache.loadWarehousesSnapshot(businessId), isNull);
  });
}
