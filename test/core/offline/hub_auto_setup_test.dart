import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_auto_setup.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/core/offline/hub/hub_lan_token.dart';
import 'package:mangopos/core/offline/hub/hub_lease_service.dart';

void main() {
  late Map<String, HubDeviceRole> roles;
  late int claims;
  late HubLeaseStatus leaseStatus;
  late String token;
  late HubAutoSetup setup;
  setUp(() {
    roles = {};
    claims = 0;
    leaseStatus = HubLeaseStatus.held;
    token = 'private-business-token';
    setup = HubAutoSetup(
      readRole: (biz) async => roles[biz] ?? HubDeviceRole.pos,
      writeRole: (biz, role) async {
        roles[biz] = role;
      },
      acquireLease: (biz) async {
        claims++;
        return HubLeaseResult(status: leaseStatus);
      },
      readToken: (_) async => token,
    );
  });

  test(
    'an unconfigured cashier prepares itself and survives WAN loss',
    () async {
      expect(
        await setup.prepare('biz', online: true, canHost: true),
        HubDeviceRole.hub,
      );
      expect(roles['biz'], HubDeviceRole.hub);
      expect(
        await setup.prepare('biz', online: false, canHost: true),
        HubDeviceRole.hub,
      );
      expect(claims, 1);
    },
  );

  test('a waiter never promotes itself', () async {
    expect(
      await setup.prepare('biz', online: true, canHost: false),
      HubDeviceRole.pos,
    );
    expect(claims, 0);
  });

  test('never elects blindly during an outage', () async {
    expect(
      await setup.prepare('biz', online: false, canHost: true),
      HubDeviceRole.pos,
    );
    expect(claims, 0);
    expect(setup.status, isNotNull);
  });

  test('a cashier cannot displace an assigned Hub', () async {
    leaseStatus = HubLeaseStatus.heldByOther;
    expect(
      await setup.prepare('biz', online: true, canHost: true),
      HubDeviceRole.pos,
    );
    expect(roles, isEmpty);
    await setup.prepare('biz', online: true, canHost: true);
    expect(claims, 1, reason: 'avoid querying the cloud every controller tick');
  });

  test(
    'a private business token is required, no shared-secret fallback',
    () async {
      token = kLegacyHubLanToken;
      expect(
        await setup.prepare('biz', online: true, canHost: true),
        HubDeviceRole.pos,
      );
      expect(claims, 0);
    },
  );

  for (final failure in [HubLeaseStatus.unavailable, HubLeaseStatus.error]) {
    test('no promotion when lease result is $failure', () async {
      leaseStatus = failure;
      expect(
        await setup.prepare('biz', online: true, canHost: true),
        HubDeviceRole.pos,
      );
      expect(roles, isEmpty);
      expect(setup.status, isNotNull);
    });
  }

  test('a demoted backup stays a backup even after reconnecting', () async {
    roles['biz'] = HubDeviceRole.hubBackup;
    expect(
      await setup.prepare('biz', online: true, canHost: true),
      HubDeviceRole.hubBackup,
    );
    expect(claims, 0);
  });

  test('businesses do not share the prepared role', () async {
    await setup.prepare('first', online: true, canHost: true);
    expect(
      await setup.prepare('second', online: false, canHost: true),
      HubDeviceRole.pos,
    );
    expect(roles.keys, ['first']);
  });

  test('a disk failure does not report that the device became Hub', () async {
    setup = HubAutoSetup(
      readRole: (_) async => HubDeviceRole.pos,
      writeRole: (_, _) async => throw StateError('disk full'),
      acquireLease: (_) async =>
          const HubLeaseResult(status: HubLeaseStatus.held),
      readToken: (_) async => token,
    );
    expect(
      await setup.prepare('biz', online: true, canHost: true),
      HubDeviceRole.pos,
    );
    expect(setup.status, isNotNull);
  });
}
