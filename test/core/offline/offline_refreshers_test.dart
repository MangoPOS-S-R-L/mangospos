import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_refreshers.dart';

/// Tests de la composición de refreshers de bajada (F6-2): arma catálogo/zonas/
/// inventario y aplica el guard del negocio activo. Colaboradores inyectados
/// (sin red/BD).
void main() {
  test(
      'arma un refresher por módulo '
      '(catálogo, zonas, inventario, config, impresoras, secuencias NCF)', () {
    final refreshers = buildOfflineRefreshers(
      resolveBusinessId: () => 'biz-1',
      refreshCatalog: (_) async {},
      refreshZones: (_) async {},
      refreshInventory: (_) async {},
      refreshConfig: (_) async {},
      refreshPrinters: (_) async {},
      refreshFiscalSequences: (_) async {},
    );
    expect(refreshers.length, 6);
  });

  test('con negocio activo → corre cada refresher con ese businessId',
      () async {
    final seen = <String, String>{};
    final refreshers = buildOfflineRefreshers(
      resolveBusinessId: () => 'biz-1',
      refreshCatalog: (b) async => seen['catalog'] = b,
      refreshZones: (b) async => seen['zones'] = b,
      refreshInventory: (b) async => seen['inventory'] = b,
      refreshConfig: (b) async => seen['config'] = b,
      refreshPrinters: (b) async => seen['printers'] = b,
      refreshFiscalSequences: (b) async => seen['fiscal'] = b,
    );
    for (final r in refreshers) {
      await r();
    }
    expect(seen, {
      'catalog': 'biz-1',
      'zones': 'biz-1',
      'inventory': 'biz-1',
      'config': 'biz-1',
      'printers': 'biz-1',
      'fiscal': 'biz-1',
    });
  });

  test('sin negocio activo (null) → no-op, no llama a los servicios', () async {
    var calls = 0;
    final refreshers = buildOfflineRefreshers(
      resolveBusinessId: () => null,
      refreshCatalog: (_) async => calls++,
      refreshZones: (_) async => calls++,
      refreshInventory: (_) async => calls++,
      refreshConfig: (_) async => calls++,
      refreshPrinters: (_) async => calls++,
      refreshFiscalSequences: (_) async => calls++,
    );
    for (final r in refreshers) {
      await r();
    }
    expect(calls, 0);
  });

  test('negocio vacío ("") también es no-op', () async {
    var calls = 0;
    final refreshers = buildOfflineRefreshers(
      resolveBusinessId: () => '',
      refreshCatalog: (_) async => calls++,
      refreshZones: (_) async => calls++,
      refreshInventory: (_) async => calls++,
      refreshConfig: (_) async => calls++,
      refreshPrinters: (_) async => calls++,
      refreshFiscalSequences: (_) async => calls++,
    );
    for (final r in refreshers) {
      await r();
    }
    expect(calls, 0);
  });

  test('resuelve el businessId al correr, no al construir (negocio cambiante)',
      () async {
    var current = 'biz-A';
    final seen = <String>[];
    final refreshers = buildOfflineRefreshers(
      resolveBusinessId: () => current,
      refreshCatalog: (b) async => seen.add(b),
      refreshZones: (_) async {},
      refreshInventory: (_) async {},
      refreshConfig: (_) async {},
      refreshPrinters: (_) async {},
      refreshFiscalSequences: (_) async {},
    );
    await refreshers[0](); // catálogo con biz-A
    current = 'biz-B';
    await refreshers[0](); // catálogo con biz-B (resuelto al correr)
    expect(seen, ['biz-A', 'biz-B']);
  });
}
