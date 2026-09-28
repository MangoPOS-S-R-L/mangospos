import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_lan_token.dart';
import 'package:mangopos/core/offline/hub/hub_roster_codec.dart';

void main() {
  const token = 'private-business-token';
  final payload = {
    'business_id': 'b',
    'roster': [
      {'pin_hash': 'sensitive'},
    ],
  };

  test('round trip encrypts hashes and authenticates the business', () async {
    final envelope = await HubRosterCodec.seal(
      payload,
      businessId: 'b',
      token: token,
    );
    expect(jsonEncode(envelope), isNot(contains('sensitive')));
    expect(
      await HubRosterCodec.open(envelope, businessId: 'b', token: token),
      payload,
    );
    await expectLater(
      HubRosterCodec.open(envelope, businessId: 'other', token: token),
      throwsA(anything),
    );
    await expectLater(
      HubRosterCodec.open(envelope, businessId: 'b', token: 'wrong'),
      throwsA(anything),
    );
    final tampered = {...envelope, 'mac': base64Encode(List.filled(16, 0))};
    await expectLater(
      HubRosterCodec.open(tampered, businessId: 'b', token: token),
      throwsA(anything),
    );
  });

  test('the shared legacy token cannot download sensitive data', () async {
    await expectLater(
      HubRosterCodec.seal(payload, businessId: 'b', token: kLegacyHubLanToken),
      throwsStateError,
    );
  });

  test('signed request does not send the shared secret', () async {
    final now = DateTime.now();
    final generated = await HubRosterCodec.requestHeaders(
      businessId: 'b',
      token: token,
      now: now,
    );
    final headers = {
      for (final entry in generated.entries)
        entry.key.toLowerCase(): entry.value,
    };
    expect(jsonEncode(headers), isNot(contains(token)));
    expect(
      await HubRosterCodec.authorize(
        headers: headers,
        businessId: 'b',
        token: token,
        now: now,
      ),
      isTrue,
    );
    expect(
      await HubRosterCodec.authorize(
        headers: headers,
        businessId: 'other',
        token: token,
        now: now,
      ),
      isFalse,
    );
    expect(
      await HubRosterCodec.authorize(
        headers: headers,
        businessId: 'b',
        token: token,
        now: now.add(const Duration(minutes: 3)),
      ),
      isFalse,
    );
    expect(
      await HubRosterCodec.authorize(
        headers: {'authorization': 'Bearer $token'},
        businessId: 'b',
        token: token,
      ),
      isFalse,
    );
  });
}
