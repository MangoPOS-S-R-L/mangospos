import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_mode.dart';

/// Tests de la resolución pura de modo Hub (F3a).
void main() {
  group('resolveHubMode', () {
    test('con internet → cloud (gana sobre todo)', () {
      expect(
        resolveHubMode(isConnected: true, hubReachable: true, hubEnabled: true),
        HubMode.cloud,
      );
      expect(
        resolveHubMode(
            isConnected: true, hubReachable: false, hubEnabled: false),
        HubMode.cloud,
      );
    });

    test('sin internet + hub alcanzable + feature ON → hub', () {
      expect(
        resolveHubMode(
            isConnected: false, hubReachable: true, hubEnabled: true),
        HubMode.hub,
      );
    });

    test('sin internet + hub alcanzable pero feature OFF → solo', () {
      expect(
        resolveHubMode(
            isConnected: false, hubReachable: true, hubEnabled: false),
        HubMode.solo,
      );
    });

    test('sin internet + sin hub → solo', () {
      expect(
        resolveHubMode(
            isConnected: false, hubReachable: false, hubEnabled: true),
        HubMode.solo,
      );
    });

    test('default usa kHubModeEnabled (hoy false → nunca hub sin flag)', () {
      // Con la feature apagada por defecto, sin internet siempre cae a solo
      // aunque haya hub.
      expect(
        resolveHubMode(isConnected: false, hubReachable: true),
        kHubModeEnabled ? HubMode.hub : HubMode.solo,
      );
    });
  });
}
