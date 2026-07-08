import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';

/// H1: resolución PURA del modo operativo del terminal (LAN-first). El corazón
/// de la decisión D2 — con política `hub` una caja habla al Hub AUNQUE tenga
/// internet.
void main() {
  group('resolveTerminalMode', () {
    test('feature apagada → cloud/solo por conexión (ignora política/rol)', () {
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.hub,
          role: HubDeviceRole.hub,
          isConnected: true,
          hubReachable: true,
          hubEnabled: false,
        ),
        TerminalMode.cloud,
      );
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.hub,
          role: HubDeviceRole.pos,
          isConnected: false,
          hubReachable: true,
          hubEnabled: false,
        ),
        TerminalMode.solo,
      );
    });

    test('política cloud (feature ON) → cloud/solo por conexión', () {
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.cloud,
          role: HubDeviceRole.pos,
          isConnected: true,
          hubReachable: true,
          hubEnabled: true,
        ),
        TerminalMode.cloud,
      );
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.cloud,
          role: HubDeviceRole.pos,
          isConnected: false,
          hubReachable: false,
          hubEnabled: true,
        ),
        TerminalMode.solo,
      );
    });

    test('política hub + este equipo ES el Hub → hubHost', () {
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.hub,
          role: HubDeviceRole.hub,
          isConnected: true, // aunque haya internet
          hubReachable: false,
          hubEnabled: true,
        ),
        TerminalMode.hubHost,
      );
    });

    test('política hub + caja + Hub alcanzable → hubClient AUNQUE haya internet',
        () {
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.hub,
          role: HubDeviceRole.pos,
          isConnected: true, // LAN-first: el WAN sale del camino
          hubReachable: true,
          hubEnabled: true,
        ),
        TerminalMode.hubClient,
      );
    });

    test('política hub + caja + Hub caído + internet → cloud', () {
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.hub,
          role: HubDeviceRole.pos,
          isConnected: true,
          hubReachable: false,
          hubEnabled: true,
        ),
        TerminalMode.cloud,
      );
    });

    test('política hub + caja + Hub caído + sin internet → solo', () {
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.hub,
          role: HubDeviceRole.pos,
          isConnected: false,
          hubReachable: false,
          hubEnabled: true,
        ),
        TerminalMode.solo,
      );
    });

    test('backup se comporta como cliente hasta el failover (H7)', () {
      expect(
        resolveTerminalMode(
          policy: NetworkPolicy.hub,
          role: HubDeviceRole.hubBackup,
          isConnected: false,
          hubReachable: true,
          hubEnabled: true,
        ),
        TerminalMode.hubClient,
      );
    });
  });

  group('serialización', () {
    test('NetworkPolicy round-trip + default', () {
      expect(networkPolicyFromString('hub'), NetworkPolicy.hub);
      expect(networkPolicyFromString('cloud'), NetworkPolicy.cloud);
      expect(networkPolicyFromString(null), NetworkPolicy.cloud);
      expect(networkPolicyFromString('basura'), NetworkPolicy.cloud);
      expect(networkPolicyToString(NetworkPolicy.hub), 'hub');
      expect(networkPolicyToString(NetworkPolicy.cloud), 'cloud');
    });

    test('HubDeviceRole round-trip + default', () {
      expect(hubDeviceRoleFromString('hub'), HubDeviceRole.hub);
      expect(hubDeviceRoleFromString('hub_backup'), HubDeviceRole.hubBackup);
      expect(hubDeviceRoleFromString('pos'), HubDeviceRole.pos);
      expect(hubDeviceRoleFromString(null), HubDeviceRole.pos);
      expect(hubDeviceRoleToString(HubDeviceRole.hub), 'hub');
      expect(hubDeviceRoleToString(HubDeviceRole.hubBackup), 'hub_backup');
      expect(hubDeviceRoleToString(HubDeviceRole.pos), 'pos');
    });
  });
}
