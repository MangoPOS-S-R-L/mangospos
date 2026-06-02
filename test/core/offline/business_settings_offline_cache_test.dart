import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/business_settings_offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del cache offline de business_settings (F6-3): round-trip por negocio,
/// null cuando no hay cache, aislamiento entre negocios.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final cache = BusinessSettingsOfflineCache();

  test('loadRow → null si nunca se cacheó', () async {
    expect(await cache.loadRow('biz-x'), isNull);
  });

  test('round-trip: guarda y recupera la fila completa', () async {
    await cache.saveRow(businessId: 'biz-1', row: {
      'cash_close_mode': 'detailed',
      'open_drawer_on_cash': true,
      'usd_rate': '60.5',
    });
    final row = await cache.loadRow('biz-1');
    expect(row, isNotNull);
    expect(row!['cash_close_mode'], 'detailed');
    expect(row['open_drawer_on_cash'], true);
    expect(row['usd_rate'], '60.5');
  });

  test('los negocios no se mezclan', () async {
    await cache.saveRow(businessId: 'biz-1', row: {'cash_close_mode': 'detailed'});
    await cache.saveRow(businessId: 'biz-2', row: {'cash_close_mode': 'compact'});
    expect((await cache.loadRow('biz-1'))!['cash_close_mode'], 'detailed');
    expect((await cache.loadRow('biz-2'))!['cash_close_mode'], 'compact');
  });

  test('saveRow sobrescribe la fila previa del mismo negocio', () async {
    await cache.saveRow(businessId: 'biz-1', row: {'allow_recount': false});
    await cache.saveRow(businessId: 'biz-1', row: {'allow_recount': true});
    expect((await cache.loadRow('biz-1'))!['allow_recount'], true);
  });
}
