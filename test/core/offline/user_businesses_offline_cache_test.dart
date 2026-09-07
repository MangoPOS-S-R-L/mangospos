import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/user_businesses_offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests del cache de accesos del usuario — la pieza que saca a
/// `SelectBusinessView` del callejón sin salida cuando no hay red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final cache = UserBusinessesOfflineCache();

  test('load → null si nunca se cacheó', () async {
    expect(await cache.load('user-x'), isNull);
  });

  test('round-trip: conserva el negocio anidado tal como vino de PostgREST',
      () async {
    await cache.save(userId: 'user-1', rows: [
      {
        'business_id': 'biz-1',
        'role': 'cashier',
        'businesses': {
          'business_name': 'Cocina Mexicana',
          'branch_name': 'Ágora',
          'domain': 'cocina',
        },
      },
    ]);

    final rows = await cache.load('user-1');
    expect(rows, isNotNull);
    expect(rows!.length, 1);
    expect(rows.first['business_id'], 'biz-1');
    expect(rows.first['role'], 'cashier');
    final business = rows.first['businesses'] as Map;
    expect(business['branch_name'], 'Ágora');
    expect(business['business_name'], 'Cocina Mexicana');
  });

  test('los usuarios no se mezclan en un terminal compartido', () async {
    await cache.save(userId: 'user-1', rows: [
      {'business_id': 'biz-1', 'role': 'owner'},
    ]);
    await cache.save(userId: 'user-2', rows: [
      {'business_id': 'biz-2', 'role': 'cashier'},
    ]);

    expect((await cache.load('user-1'))!.first['business_id'], 'biz-1');
    expect((await cache.load('user-2'))!.first['business_id'], 'biz-2');
  });

  test('save sobrescribe los accesos previos del mismo usuario', () async {
    await cache.save(userId: 'user-1', rows: [
      {'business_id': 'biz-1', 'role': 'owner'},
      {'business_id': 'biz-2', 'role': 'owner'},
    ]);
    await cache.save(userId: 'user-1', rows: [
      {'business_id': 'biz-1', 'role': 'owner'},
    ]);

    final rows = await cache.load('user-1');
    expect(rows!.length, 1, reason: 'un acceso revocado no debe sobrevivir');
  });

  test('descarta filas sin business_id', () async {
    await cache.save(userId: 'user-1', rows: [
      {'business_id': 'biz-1', 'role': 'owner'},
      {'role': 'cashier'}, // basura
      {'business_id': '', 'role': 'cashier'},
    ]);
    expect((await cache.load('user-1'))!.length, 1);
  });

  test('lista vacía → load devuelve null (no una lista vacía engañosa)',
      () async {
    await cache.save(userId: 'user-1', rows: const []);
    expect(await cache.load('user-1'), isNull);
  });

  test('cache corrupto no truena: devuelve null', () async {
    SharedPreferences.setMockInitialValues({
      'offline_user_businesses_user-1': '{esto no es json',
    });
    expect(await cache.load('user-1'), isNull);
  });

  test('payload sin la llave rows → null', () async {
    SharedPreferences.setMockInitialValues({
      'offline_user_businesses_user-1': '{"saved_at":"2026-09-06T10:00:00.000"}',
    });
    expect(await cache.load('user-1'), isNull);
  });

  test('userId vacío no escribe ni lee', () async {
    await cache.save(userId: '', rows: [
      {'business_id': 'biz-1'},
    ]);
    expect(await cache.load(''), isNull);
  });

  test('savedAt registra cuándo se cacheó', () async {
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await cache.save(userId: 'user-1', rows: [
      {'business_id': 'biz-1'},
    ]);
    final at = await cache.savedAt('user-1');
    expect(at, isNotNull);
    expect(at!.isAfter(before), isTrue);
  });

  test('clear borra solo al usuario indicado', () async {
    await cache.save(userId: 'user-1', rows: [
      {'business_id': 'biz-1'},
    ]);
    await cache.save(userId: 'user-2', rows: [
      {'business_id': 'biz-2'},
    ]);

    await cache.clear('user-1');
    expect(await cache.load('user-1'), isNull);
    expect(await cache.load('user-2'), isNotNull);
  });
}
