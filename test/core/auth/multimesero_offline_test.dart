import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mangopos/core/auth/offline_auth_service.dart';
import 'package:mangopos/core/multimesero/multimesero_repository.dart';
import 'package:mangopos/core/offline/business_settings_offline_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth implements OfflineAuthService {
  OfflineRosterUser? result;
  @override
  Future<OfflineRosterUser?> verifyPin({
    required String businessId,
    required String pin,
  }) async => result;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MultimeseroRepository repo;
  late SupabaseClient client;
  late _Auth auth;
  setUpAll(() => SharedPreferences.setMockInitialValues({}));
  setUp(() {
    auth = _Auth();
    client = SupabaseClient(
      'https://example.test',
      'test',
      httpClient: MockClient((_) async {
        throw StateError('Offline waiter flow must not contact Supabase');
      }),
    );
    repo = MultimeseroRepository(
      client,
      offlineAuth: auth,
      isOnline: () => false,
    );
  });
  tearDown(() async => client.dispose());

  test(
    'offline waiter identity retains its own role and permissions',
    () async {
      auth.result = const OfflineRosterUser(
        userId: 'u',
        employeeId: 'e',
        name: 'Ana Perez',
        firstName: 'Ana',
        lastName: 'Perez',
        email: null,
        pinHash: null,
        role: 'waiter',
        permissions: ['ventas.acceso'],
        isActive: true,
      );
      final waiter = await repo.verifyPin(businessId: 'b', pin: '1234');
      expect(waiter?.employeeId, 'e');
      expect(waiter?.firstName, 'Ana');
      expect(waiter?.permissions, {'ventas.acceso'});
    },
  );
  test('an invalid PIN offline does not wait on a cloud request', () async {
    expect(await repo.verifyPin(businessId: 'b', pin: 'wrong'), isNull);
  });
  test('waiter mode and table ownership survive the WAN outage', () async {
    await BusinessSettingsOfflineCache().saveRow(
      businessId: 'b',
      row: {'multimesero_enabled': true, 'multimesero_table_owner_only': true},
    );
    expect(await repo.readModes('b'), (enabled: true, tableOwnerOnly: true));
    expect(await repo.isEnabled('b'), isTrue);
  });
}
