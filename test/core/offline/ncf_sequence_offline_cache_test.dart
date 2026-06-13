import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/ncf_sequence_offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del cache offline de la serie central de NCF (F4): round-trip por
/// (negocio, tipo), null cuando no hay cache, aislamiento entre negocios y
/// entre tipos. De esta semilla depende que el Hub conozca current_number
/// cuando se cae internet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final cache = NcfSequenceOfflineCache();

  test('loadRow → null si nunca se cacheó', () async {
    expect(
      await cache.loadRow(businessId: 'biz-x', ncfType: 'B02'),
      isNull,
    );
  });

  test('round-trip: guarda y recupera la fila de la serie', () async {
    await cache.saveRow(
      businessId: 'biz-1',
      ncfType: 'B02',
      row: {
        'serie': null,
        'prefix': 'B02',
        'range_start': 1,
        'range_end': 100000,
        'current_number': 4521,
        'is_active': true,
      },
    );
    final row = await cache.loadRow(businessId: 'biz-1', ncfType: 'B02');
    expect(row, isNotNull);
    expect(row!['prefix'], 'B02');
    expect(row['current_number'], 4521);
    expect(row['range_end'], 100000);
  });

  test('los tipos no se mezclan dentro del mismo negocio', () async {
    await cache.saveRow(
      businessId: 'biz-1',
      ncfType: 'B02',
      row: {'prefix': 'B02', 'current_number': 10},
    );
    await cache.saveRow(
      businessId: 'biz-1',
      ncfType: 'B01',
      row: {'prefix': 'B01', 'current_number': 99},
    );
    expect(
      (await cache.loadRow(businessId: 'biz-1', ncfType: 'B02'))!['prefix'],
      'B02',
    );
    expect(
      (await cache.loadRow(businessId: 'biz-1', ncfType: 'B01'))!['current_number'],
      99,
    );
  });

  test('los negocios no se mezclan', () async {
    await cache.saveRow(
      businessId: 'biz-1',
      ncfType: 'B02',
      row: {'current_number': 10},
    );
    await cache.saveRow(
      businessId: 'biz-2',
      ncfType: 'B02',
      row: {'current_number': 500},
    );
    expect(
      (await cache.loadRow(businessId: 'biz-1', ncfType: 'B02'))!['current_number'],
      10,
    );
    expect(
      (await cache.loadRow(businessId: 'biz-2', ncfType: 'B02'))!['current_number'],
      500,
    );
  });

  test('saveRow sobrescribe la semilla previa del mismo (negocio, tipo)', () async {
    await cache.saveRow(
      businessId: 'biz-1',
      ncfType: 'B02',
      row: {'current_number': 10},
    );
    await cache.saveRow(
      businessId: 'biz-1',
      ncfType: 'B02',
      row: {'current_number': 11},
    );
    expect(
      (await cache.loadRow(businessId: 'biz-1', ncfType: 'B02'))!['current_number'],
      11,
    );
  });
}
