import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/zones_offline_cache.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del snapshot de MESAS por zona — la pieza que faltaba para que el
/// modal de asignar a mesa y el floor map no salieran vacíos sin red.
///
/// Ojo con la distinción: este snapshot guarda la mesa en sí (código,
/// etiqueta, capacidad, geometría), que cambia rara vez. El de ESTADO
/// (ocupada/libre) es otro y cambia todo el rato.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final cache = ZonesOfflineCache();

  test('loadZoneTablesSnapshot → null si nunca se cacheó', () async {
    expect(await cache.loadZoneTablesSnapshot(zoneId: 'zona-x'), isNull);
  });

  test('round-trip: conserva la geometría del plano', () async {
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-1', rowsRaw: [
      {
        'id': 'mesa-1',
        'zone_id': 'zona-1',
        'code': 'A1',
        'label': 'Terraza 1',
        'shape': 'round',
        'capacity': 4,
        'pos_x': 120.5,
        'pos_y': 80.0,
        'rotation': 45,
        'is_active': true,
      },
    ]);

    final snap = await cache.loadZoneTablesSnapshot(zoneId: 'zona-1');
    expect(snap, isNotNull);
    expect(snap!.rows.length, 1);
    expect(snap.rows.first['code'], 'A1');
    expect(snap.rows.first['label'], 'Terraza 1');
    expect(snap.rows.first['capacity'], 4);
    expect(snap.rows.first['pos_x'], 120.5);
    expect(snap.rows.first['rotation'], 45);
  });

  test('las zonas no se mezclan entre sí', () async {
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-1', rowsRaw: [
      {'id': 'mesa-1', 'code': 'A1'},
    ]);
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-2', rowsRaw: [
      {'id': 'mesa-2', 'code': 'B1'},
      {'id': 'mesa-3', 'code': 'B2'},
    ]);

    expect((await cache.loadZoneTablesSnapshot(zoneId: 'zona-1'))!.rows.length, 1);
    expect((await cache.loadZoneTablesSnapshot(zoneId: 'zona-2'))!.rows.length, 2);
  });

  test('el snapshot de mesas no pisa al de estado de la misma zona', () async {
    await cache.saveZoneStatusSnapshot(zoneId: 'zona-1', rowsRaw: [
      {'table_id': 'mesa-1', 'status': 'occupied'},
    ]);
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-1', rowsRaw: [
      {'id': 'mesa-1', 'code': 'A1'},
    ]);

    final status = await cache.loadZoneStatusSnapshot(zoneId: 'zona-1');
    final tables = await cache.loadZoneTablesSnapshot(zoneId: 'zona-1');
    expect(status!.rows.first['status'], 'occupied');
    expect(tables!.rows.first['code'], 'A1');
  });

  test('guardar de nuevo reemplaza: una mesa borrada no revive', () async {
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-1', rowsRaw: [
      {'id': 'mesa-1', 'code': 'A1'},
      {'id': 'mesa-2', 'code': 'A2'},
    ]);
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-1', rowsRaw: [
      {'id': 'mesa-1', 'code': 'A1'},
    ]);

    final snap = await cache.loadZoneTablesSnapshot(zoneId: 'zona-1');
    expect(snap!.rows.length, 1);
    expect(snap.rows.first['id'], 'mesa-1');
  });

  test('lista vacía se guarda como vacía (zona sin mesas es un dato válido)',
      () async {
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-1', rowsRaw: const []);
    final snap = await cache.loadZoneTablesSnapshot(zoneId: 'zona-1');
    expect(snap, isNotNull);
    expect(snap!.rows, isEmpty);
  });

  test('savedAt permite saber qué tan viejo es el plano', () async {
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await cache.saveZoneTablesSnapshot(zoneId: 'zona-1', rowsRaw: [
      {'id': 'mesa-1'},
    ]);
    final snap = await cache.loadZoneTablesSnapshot(zoneId: 'zona-1');
    expect(snap!.savedAt.isAfter(before), isTrue);
  });

  test('cache corrupto no truena: devuelve null', () async {
    // Se escribe por el mismo canal que usa el cache: StorageService cachea
    // su instancia de SharedPreferences en un static, así que
    // setMockInitialValues a mitad de suite no la reemplazaría.
    final storage = await StorageService.getInstance();
    await storage.write('offline_zone_tables_snapshot_zona-corrupta',
        'no soy json');
    expect(
      await cache.loadZoneTablesSnapshot(zoneId: 'zona-corrupta'),
      isNull,
    );
  });
}
