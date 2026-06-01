import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/ncf_offline_allocator.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del asignador de NCF offline (F4): secuencia, formato, seed del
/// server, agotamiento del rango y aislamiento por serie.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NcfOfflineAllocator alloc;
  late StorageService storage;
  const biz = 'biz-1';

  const range = NcfRange(
    ncfType: 'B02',
    serie: 'C1',
    prefix: 'B02',
    rangeStart: 1,
    rangeEnd: 5,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.getInstance();
    alloc = NcfOfflineAllocator(storage: storage);
    await alloc.reset(businessId: biz, ncfType: 'B02', serie: 'C1');
  });

  test('formatNcf hace prefix + LPAD(8) como generate_ncf', () {
    expect(NcfOfflineAllocator.formatNcf('B02', 1), 'B0200000001');
    expect(NcfOfflineAllocator.formatNcf('E32', 123), 'E3200000123');
  });

  test('asigna secuencial desde rangeStart', () async {
    final a = await alloc.allocate(businessId: biz, range: range);
    final b = await alloc.allocate(businessId: biz, range: range);
    expect(a!.number, 1);
    expect(a.ncf, 'B0200000001');
    expect(b!.number, 2);
    expect(b.ncf, 'B0200000002');
  });

  test('respeta seedCurrent del server (no reasigna lo ya consumido online)',
      () async {
    const seeded = NcfRange(
      ncfType: 'B02',
      serie: 'C1',
      prefix: 'B02',
      rangeStart: 1,
      rangeEnd: 100,
      seedCurrent: 40,
    );
    final a = await alloc.allocate(businessId: biz, range: seeded);
    expect(a!.number, 41);
  });

  test('agotamiento del rango devuelve null (→ recibo provisional)', () async {
    // rango 1..5: 5 asignaciones OK, la 6ta null.
    for (var i = 1; i <= 5; i++) {
      final r = await alloc.allocate(businessId: biz, range: range);
      expect(r!.number, i);
    }
    final overflow = await alloc.allocate(businessId: biz, range: range);
    expect(overflow, isNull);
  });

  test('lastConsumed y remaining reflejan el avance', () async {
    await alloc.allocate(businessId: biz, range: range); // 1
    await alloc.allocate(businessId: biz, range: range); // 2
    expect(
      await alloc.lastConsumed(businessId: biz, ncfType: 'B02', serie: 'C1'),
      2,
    );
    expect(await alloc.remaining(businessId: biz, range: range), 3); // 5-2
  });

  test('series distintas no comparten contador', () async {
    const c2 = NcfRange(
      ncfType: 'B02',
      serie: 'C2',
      prefix: 'B02',
      rangeStart: 1000,
      rangeEnd: 2000,
    );
    final a = await alloc.allocate(businessId: biz, range: range); // serie C1
    final b = await alloc.allocate(businessId: biz, range: c2); // serie C2
    expect(a!.number, 1);
    expect(b!.number, 1000);
  });

  test('reset reinicia el contador local', () async {
    await alloc.allocate(businessId: biz, range: range); // 1
    await alloc.reset(businessId: biz, ncfType: 'B02', serie: 'C1');
    final a = await alloc.allocate(businessId: biz, range: range);
    expect(a!.number, 1);
  });
}
