import 'dart:async';
import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secure = <String, String>{};
  late StorageService storage;
  final hash = BCrypt.hashpw('1234', BCrypt.gensalt(logRounds: 4));

  Map<String, dynamic> payload({
    String business = 'b',
    DateTime? at,
    bool active = true,
    String? pinHash,
  }) => {
    'business_id': business,
    'synced_at': (at ?? DateTime.now().toUtc()).toIso8601String(),
    'roster': [
      {
        'user_id': 'u',
        'employee_id': 'e',
        'name': 'Mesero',
        'first_name': 'Mesero',
        'pin_hash': pinHash ?? hash,
        'role': 'waiter',
        'permissions': ['ventas.acceso'],
        'is_active': active,
      },
    ],
  };

  OfflineAuthService service({
    Future<Map<String, dynamic>> Function(String)? cloud,
    Future<Map<String, dynamic>?> Function(String)? lan,
    bool online = true,
  }) => OfflineAuthService.forTesting(
    cloudRoster: cloud ?? (_) async => payload(),
    lanRoster: lan ?? (_) async => null,
    isOnline: () => online,
  );

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await StorageService.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            if (call.method == 'read') return secure[args['key']];
            if (call.method == 'write') secure[args['key']] = args['value'];
            if (call.method == 'delete') secure.remove(args['key']);
            return null;
          },
        );
  });
  setUp(() async => storage.clear());

  test(
    'session downloads PINs without device registration and encrypts disk',
    () async {
      final auth = service();
      expect(await auth.isDeviceBound(), isFalse);
      final users = await auth.syncRoster(businessId: 'b');
      expect(users.single.employeeId, 'e');
      expect(await auth.isDeviceBound(), isFalse);
      final raw = await storage.read('mp_offline_roster_b');
      expect(raw, startsWith('enc:'));
      expect(raw, isNot(contains(hash)));
      expect(
        (await auth.verifyPin(businessId: 'b', pin: ' 1234 '))?.userId,
        'u',
      );
    },
  );

  test('LAN works without WAN and preserves the original timestamp', () async {
    final at = DateTime.now().toUtc().subtract(const Duration(hours: 3));
    final auth = service(
      online: false,
      lan: (_) async => payload(at: at),
      cloud: (_) async => throw StateError('WAN must not be called'),
    );
    await auth.syncRoster(businessId: 'b');
    expect(await auth.rosterSyncedAt('b'), at);
    expect(
      (await auth.verifyPin(businessId: 'b', pin: '1234'))?.employeeId,
      'e',
    );
  });

  test('another business cannot poison the local roster', () async {
    final auth = service(cloud: (_) async => payload(business: 'other'));
    await expectLater(
      auth.syncRoster(businessId: 'b'),
      throwsA(isA<OfflineRosterSyncException>()),
    );
    expect(await auth.cachedRoster('b'), isEmpty);
    expect(await auth.cachedRoster('other'), isEmpty);
  });

  test(
    'an expired LAN copy falls back to the authenticated cloud session',
    () async {
      var downloads = 0;
      final auth = service(
        lan: (_) async =>
            payload(at: DateTime.now().subtract(const Duration(days: 2))),
        cloud: (_) async {
          downloads++;
          return payload();
        },
      );
      await auth.syncRoster(businessId: 'b');
      expect(downloads, 1);
      expect(await auth.isRosterStale('b'), isFalse);
    },
  );

  test(
    'copying expired permissions offline never extends their validity',
    () async {
      final old = payload(at: DateTime.now().subtract(const Duration(days: 2)));
      await storage.write('mp_offline_roster_b', jsonEncode(old));
      final auth = service(online: false, lan: (_) async => old);
      expect(await auth.verifyPin(businessId: 'b', pin: '1234'), isNull);
      expect(await auth.isRosterStale('b'), isTrue);
    },
  );

  test(
    'an older hub cannot restore a revoked PIN from a newer local snapshot',
    () async {
      final now = DateTime.now().toUtc();
      await service(
        cloud: (_) async => payload(at: now, active: false),
      ).syncRoster(businessId: 'b');
      final auth = service(
        online: false,
        lan: (_) async => payload(at: now.subtract(const Duration(minutes: 2))),
      );
      await auth.syncRoster(businessId: 'b');
      expect((await auth.cachedRoster('b')).single.isActive, isFalse);
      expect(await auth.verifyPin(businessId: 'b', pin: '1234'), isNull);
    },
  );

  test('simultaneous refreshes share one download', () async {
    var calls = 0;
    final response = Completer<Map<String, dynamic>>();
    final auth = service(
      cloud: (_) {
        calls++;
        return response.future;
      },
    );
    final first = auth.syncRoster(businessId: 'b');
    final second = auth.syncRoster(businessId: 'b');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    response.complete(payload());
    await Future.wait([first, second]);
  });

  test('a changed PIN is refreshed immediately on a cache miss', () async {
    await service().syncRoster(businessId: 'b');
    final changed = BCrypt.hashpw('5678', BCrypt.gensalt(logRounds: 4));
    final auth = service(cloud: (_) async => payload(pinHash: changed));
    expect((await auth.verifyPin(businessId: 'b', pin: '5678'))?.userId, 'u');
    expect(await auth.verifyPin(businessId: 'b', pin: '1234'), isNull);
  });

  test('empty authoritative roster removes old cached users', () async {
    await service().syncRoster(businessId: 'b');
    final auth = service(cloud: (_) async => {...payload(), 'roster': []});
    await auth.syncRoster(businessId: 'b');
    expect(await auth.cachedRoster('b'), isEmpty);
  });
}
