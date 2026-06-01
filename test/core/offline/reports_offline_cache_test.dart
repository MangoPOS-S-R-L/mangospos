import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/reports_offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del cache offline de reportes (F5): guarda/lee el resumen de ventas
/// y solo lo sirve si el rango coincide.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = ReportsOfflineCache();
  const biz = 'biz-1';
  const from = '2026-06-01T00:00:00.000Z';
  const to = '2026-06-02T00:00:00.000Z';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('save + load del mismo rango devuelve el resumen', () async {
    await cache.saveSalesSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
      summary: {'net_sales': 1500, 'sales_by_production_area': []},
    );
    final loaded = await cache.loadSalesSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
    );
    expect(loaded, isNotNull);
    expect(loaded!.summary['net_sales'], 1500);
    expect(loaded.savedAt.isAfter(DateTime.fromMillisecondsSinceEpoch(0)),
        isTrue);
  });

  test('load con rango distinto devuelve null (no sirve data de otro periodo)',
      () async {
    await cache.saveSalesSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
      summary: {'net_sales': 1500},
    );
    final loaded = await cache.loadSalesSummary(
      businessId: biz,
      fromIso: '2026-05-01T00:00:00.000Z',
      toIso: '2026-05-02T00:00:00.000Z',
    );
    expect(loaded, isNull);
  });

  test('load sin cache previo devuelve null', () async {
    final loaded = await cache.loadSalesSummary(
      businessId: 'otro',
      fromIso: from,
      toIso: to,
    );
    expect(loaded, isNull);
  });

  test('guardar de nuevo sobrescribe (un snapshot por negocio)', () async {
    await cache.saveSalesSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
      summary: {'net_sales': 100},
    );
    await cache.saveSalesSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
      summary: {'net_sales': 999},
    );
    final loaded = await cache.loadSalesSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
    );
    expect(loaded!.summary['net_sales'], 999);
  });

  test('caja (F5-2): save/load independiente de ventas (kinds distintos)',
      () async {
    await cache.saveCashSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
      summary: {'net_cash_flow': 4200},
    );
    await cache.saveSalesSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
      summary: {'net_sales': 1},
    );
    final cash =
        await cache.loadCashSummary(businessId: biz, fromIso: from, toIso: to);
    expect(cash!.summary['net_cash_flow'], 4200);
    final sales =
        await cache.loadSalesSummary(businessId: biz, fromIso: from, toIso: to);
    expect(sales!.summary['net_sales'], 1);
  });

  test('caja: rango distinto devuelve null', () async {
    await cache.saveCashSummary(
      businessId: biz,
      fromIso: from,
      toIso: to,
      summary: {'net_cash_flow': 10},
    );
    final loaded = await cache.loadCashSummary(
      businessId: biz,
      fromIso: '2026-01-01T00:00:00.000Z',
      toIso: '2026-01-02T00:00:00.000Z',
    );
    expect(loaded, isNull);
  });
}
