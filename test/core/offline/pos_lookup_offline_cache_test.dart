import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_cache_pruner.dart';
import 'package:mangopos/core/offline/pos_lookup_offline_cache.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _group(String id, List<Map<String, dynamic>> mods) => {
      'id': id,
      'name': 'Grupo $id',
      'min_select': 0,
      'max_select': 1,
      'is_active': true,
      'modifiers': mods,
    };

Map<String, dynamic> _row(String groupId, int position,
        Map<String, dynamic> group) =>
    {'group_id': groupId, 'position': position, 'modifier_groups': group};

void main() {
  late PosLookupOfflineCache cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    cache = PosLookupOfflineCache.forTesting(await StorageService.getInstance());
  });

  group('impuestos', () {
    test('guarda y devuelve la última lista buena', () async {
      await cache.saveBusinessTaxes('biz', [
        {'id': 't1', 'name': 'ITBIS', 'rate': 18, 'is_active': true},
      ]);
      final rows = await cache.loadBusinessTaxes('biz');
      expect(rows, hasLength(1));
      expect(rows!.first['rate'], 18);
    });

    test('nunca guardado → null; negocio sin impuestos → lista vacía', () async {
      // Id propio: StorageService retiene sus SharedPreferences entre tests.
      expect(await cache.loadBusinessTaxes('biz-sin-tax'), isNull);
      await cache.saveBusinessTaxes('biz-sin-tax', const []);
      expect(await cache.loadBusinessTaxes('biz-sin-tax'), isEmpty);
    });
  });

  group('modificadores', () {
    test('un grupo compartido se guarda una vez y sirve a cada producto',
        () async {
      final salsas = _group('g1', [
        {'id': 'm1', 'name': 'Ajo', 'sort_order': 1},
      ]);
      await cache.saveModifierGroups('biz', 'pizza', [_row('g1', 0, salsas)]);
      await cache.saveModifierGroups('biz', 'pasta', [_row('g1', 2, salsas)]);

      final pizza = await cache.loadModifierGroups('biz', 'pizza');
      final pasta = await cache.loadModifierGroups('biz', 'pasta');
      expect(pizza!.single['group_id'], 'g1');
      expect(pasta!.single['position'], 2);
      expect(
        (pasta.single['modifier_groups'] as Map)['modifiers'],
        hasLength(1),
      );
    });

    test('producto nunca bajado → null (distinto de "sin modificadores")',
        () async {
      expect(await cache.loadModifierGroups('biz', 'nunca-bajado'), isNull);
      await cache.saveModifierGroups('biz', 'agua', const []);
      expect(await cache.loadModifierGroups('biz', 'agua'), isEmpty);
    });

    test('la bajada en bloque reemplaza lo anterior', () async {
      await cache.saveModifierGroups(
        'biz-bloque',
        'viejo',
        [_row('g0', 0, _group('g0', const []))],
      );
      await cache.replaceAllModifierGroups('biz-bloque', {
        'pizza': [_row('g1', 0, _group('g1', const []))],
      });
      expect(await cache.loadModifierGroups('biz-bloque', 'viejo'), isNull);
      expect(
        await cache.loadModifierGroups('biz-bloque', 'pizza'),
        hasLength(1),
      );
    });

    test('lo devuelto es una copia: mutarlo no toca el caché', () async {
      await cache.saveModifierGroups('biz', 'pizza', [
        _row('g1', 0, _group('g1', [
          {'id': 'm1', 'name': 'Ajo'},
        ])),
      ]);
      final first = await cache.loadModifierGroups('biz', 'pizza');
      (first!.single['modifier_groups'] as Map)['modifiers'] = const [];
      final again = await cache.loadModifierGroups('biz', 'pizza');
      expect(
        (again!.single['modifier_groups'] as Map)['modifiers'],
        hasLength(1),
      );
    });

    test('escrituras simultáneas no se pisan', () async {
      await Future.wait([
        for (var i = 0; i < 20; i++)
          cache.saveModifierGroups(
            'biz',
            'p$i',
            [_row('g$i', 0, _group('g$i', const []))],
          ),
      ]);
      for (var i = 0; i < 20; i++) {
        expect(await cache.loadModifierGroups('biz', 'p$i'), hasLength(1));
      }
    });

    test('combos por producto', () async {
      await cache.saveComboGroups('biz', 'combo1', [
        {'id': 'cg1', 'name': 'Bebida', 'combo_group_items': const []},
      ]);
      expect(await cache.loadComboGroups('biz', 'combo1'), hasLength(1));
      expect(await cache.loadComboGroups('biz', 'otro'), isNull);
    });
  });

  test('encabezado del recibo y razones de caja', () async {
    await cache.saveReceiptBusinessRow('biz', {'fiscal_rnc': '101010101'});
    expect(
      (await cache.loadReceiptBusinessRow('biz'))!['fiscal_rnc'],
      '101010101',
    );
    await cache.saveCashReasons('biz', [
      {'code': 'gas', 'label': 'Gasolina'},
    ]);
    expect(await cache.loadCashReasons('biz'), hasLength(1));
  });

  test('todas las claves son podables por negocio', () {
    const prefixes = [
      PosLookupOfflineCache.taxesPrefix,
      PosLookupOfflineCache.itemOptionsPrefix,
      PosLookupOfflineCache.receiptBusinessPrefix,
      PosLookupOfflineCache.cashReasonsPrefix,
    ];
    for (final prefix in prefixes) {
      expect(OfflineCachePruner.readCachePrefixes, contains(prefix));
    }
  });
}
