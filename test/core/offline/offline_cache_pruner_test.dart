import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_cache_pruner.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del podador de caches de lectura.
///
/// Lo que protege es más importante que lo que borra: SharedPreferences guarda
/// juntos los caches reconstruibles y el trabajo NO SUBIDO. Podar de más aquí
/// es literalmente el bug de "las cuentas desaparecen".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const activo = 'biz-activo';
  const otro = 'biz-viejo';

  late StorageService storage;
  late OfflineCachePruner pruner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.getInstance();
    pruner = OfflineCachePruner(storage: storage);
    // Limpia lo que haya quedado: StorageService es singleton entre tests.
    for (final p in [
      ...OfflineCachePruner.readCachePrefixes,
      ...OfflineCachePruner.neverPrunePrefixes,
    ]) {
      await storage.deleteByPrefix(p);
    }
  });

  test('borra el catálogo de otro negocio y conserva el del activo', () async {
    await storage.write('offline_catalog_$activo', '{"items":[]}');
    await storage.write('offline_catalog_$otro', '{"items":[]}');

    final n = await pruner.pruneOtherBusinesses(activo);

    expect(n, 1);
    expect(await storage.read('offline_catalog_$activo'), isNotNull);
    expect(await storage.read('offline_catalog_$otro'), isNull);
  });

  // Las tres familias que pesaban el 86% del plist de 34 MB medido en campo.
  test('poda las familias pesadas: catálogo, fiscal e inventario', () async {
    for (final p in [
      'offline_catalog_',
      'offline_reports_fiscal_summary_',
      'offline_inventory_snapshot_',
    ]) {
      await storage.write('$p$otro', 'x');
      await storage.write('$p$activo', 'x');
    }

    expect(await pruner.pruneOtherBusinesses(activo), 3);
    for (final p in [
      'offline_catalog_',
      'offline_reports_fiscal_summary_',
      'offline_inventory_snapshot_',
    ]) {
      expect(await storage.read('$p$activo'), isNotNull);
      expect(await storage.read('$p$otro'), isNull);
    }
  });

  // ── Lo que NUNCA se puede borrar ────────────────────────────────────────
  //
  // Son datos que pueden no haber subido a Supabase. Perderlos no cuesta una
  // consulta: cuesta ventas.
  group('no toca el trabajo no subido, ni de otros negocios', () {
    test('borradores de orden sobreviven', () async {
      await storage.write('offline_snapshot_${otro}_slot1', 'borrador');
      await pruner.pruneOtherBusinesses(activo);
      expect(await storage.read('offline_snapshot_${otro}_slot1'), isNotNull);
    });

    test('la cola offline sobrevive', () async {
      await storage.write('offline_queue_$otro', '[]');
      await storage.write('offline_print_queue_$otro', '[]');
      await pruner.pruneOtherBusinesses(activo);
      expect(await storage.read('offline_queue_$otro'), isNotNull);
      expect(await storage.read('offline_print_queue_$otro'), isNotNull);
    });

    test('los mapas de ids sobreviven', () async {
      await storage.write('offline_order_map_$otro', '{}');
      await storage.write('offline_item_map_$otro', '{}');
      await storage.write('offline_cash_session_map_$otro', '{}');
      await pruner.pruneOtherBusinesses(activo);
      expect(await storage.read('offline_order_map_$otro'), isNotNull);
      expect(await storage.read('offline_item_map_$otro'), isNotNull);
      expect(await storage.read('offline_cash_session_map_$otro'), isNotNull);
    });

    test('el op-log del Hub sobrevive', () async {
      await storage.write('hub_oplog_$otro', '[]');
      await pruner.pruneOtherBusinesses(activo);
      expect(await storage.read('hub_oplog_$otro'), isNotNull);
    });

    // Sin roster no hay login offline: borrarlo dejaría al equipo fuera.
    test('el roster sobrevive', () async {
      await storage.write('mp_offline_roster_$otro', '[]');
      await pruner.pruneOtherBusinesses(activo);
      expect(await storage.read('mp_offline_roster_$otro'), isNotNull);
    });

    test(
      'las marcas de completado sobreviven (idempotencia del sync)',
      () async {
        await storage.write('offline_completed_ops_$otro', '[]');
        await storage.write('offline_completed_fingerprints_$otro', '[]');
        await pruner.pruneOtherBusinesses(activo);
        expect(await storage.read('offline_completed_ops_$otro'), isNotNull);
        expect(
          await storage.read('offline_completed_fingerprints_$otro'),
          isNotNull,
        );
      },
    );
  });

  group('bordes', () {
    test('sin negocio activo no borra NADA', () async {
      await storage.write('offline_catalog_$otro', 'x');
      expect(await pruner.pruneOtherBusinesses(''), 0);
      expect(await storage.read('offline_catalog_$otro'), isNotNull);
    });

    test('correrlo dos veces es idempotente', () async {
      await storage.write('offline_catalog_$otro', 'x');
      expect(await pruner.pruneOtherBusinesses(activo), 1);
      expect(await pruner.pruneOtherBusinesses(activo), 0);
    });

    test('sin nada que podar devuelve 0', () async {
      await storage.write('offline_catalog_$activo', 'x');
      expect(await pruner.pruneOtherBusinesses(activo), 0);
    });
  });

  // Guardarraíl de diseño: si alguien agrega una familia al podador que
  // también está protegida, este test lo caza antes que el campo.
  test('ninguna familia podable colisiona con una protegida', () {
    for (final podable in OfflineCachePruner.readCachePrefixes) {
      for (final protegida in OfflineCachePruner.neverPrunePrefixes) {
        expect(
          podable.startsWith(protegida) || protegida.startsWith(podable),
          isFalse,
          reason: '"$podable" se solapa con la protegida "$protegida"',
        );
      }
    }
  });
}
