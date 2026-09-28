// Indicador de conexión con la caja (Hub) en el header del POS.
//
// Lo que se prueba es la regla que decide QUÉ VE el mesero, que es donde está
// el riesgo: un indicador que se apaga justo cuando la tablet perdió la caja
// es peor que no tenerlo, porque enseña a ignorarlo.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';
import 'package:mangopos/presentation/shell/hub_status_badge.dart';

void main() {
  group('hubLinkStateFor', () {
    test('el equipo que ES la caja se muestra como Hub', () {
      expect(
        hubLinkStateFor(TerminalMode.hubHost),
        HubLinkState.isHub,
      );
    });

    test('una tablet hablando con la caja se muestra conectada', () {
      expect(
        hubLinkStateFor(TerminalMode.hubClient),
        HubLinkState.connected,
      );
    });

    test('un local que NO usa Hub no dibuja nada', () {
      // Sin esto el header se llenaría de un icono que no explica nada en
      // todos los negocios que trabajan solo contra la nube.
      expect(hubLinkStateFor(TerminalMode.cloud), isNull);
      expect(hubLinkStateFor(TerminalMode.solo), isNull);
    });
  });

  group('resolveTerminalMode — lo que sostiene al indicador', () {
    test('la caja es Hub aunque NO tenga internet', () {
      // Es el caso del dueño: la caja se conecta una vez al día. Si el Hub
      // dependiera de internet, el local entero se quedaría sin red local.
      final mode = resolveTerminalMode(
        policy: NetworkPolicy.hub,
        role: HubDeviceRole.hub,
        isConnected: false,
        hubReachable: false,
      );
      expect(mode, TerminalMode.hubHost);
      expect(hubLinkStateFor(mode), HubLinkState.isHub);
    });

    test('la tablet se engancha a la caja sin internet', () {
      final mode = resolveTerminalMode(
        policy: NetworkPolicy.hub,
        role: HubDeviceRole.pos,
        isConnected: false,
        hubReachable: true,
      );
      expect(mode, TerminalMode.hubClient);
      expect(hubLinkStateFor(mode), HubLinkState.connected);
    });

    test('tablet sin caja y sin internet queda sola', () {
      final mode = resolveTerminalMode(
        policy: NetworkPolicy.hub,
        role: HubDeviceRole.pos,
        isConnected: false,
        hubReachable: false,
      );
      expect(mode, TerminalMode.solo);
      // El modo por sí solo no distingue "no usa Hub" de "perdió la caja";
      // por eso el badge además mira la IP configurada (ver más abajo).
      expect(hubLinkStateFor(mode), isNull);
    });
  });

  group('cuándo el badge debe pintarse en rojo', () {
    // Reproduce la decisión del widget: modo sin Hub + IP configurada =
    // el local SÍ usa Hub y este equipo lo perdió.
    HubLinkState? resolve(TerminalMode mode, String? configuredUrl) {
      final link = hubLinkStateFor(mode);
      if (link != null) return link;
      return configuredUrl == null ? null : HubLinkState.disconnected;
    }

    test('perdió la caja pero la tiene configurada → rojo', () {
      expect(
        resolve(TerminalMode.solo, 'http://192.168.1.50:4000'),
        HubLinkState.disconnected,
      );
    });

    test('cayó a nube con la caja configurada → rojo', () {
      // La tablet tiene internet pero no ve la caja: sus mesas NO están
      // llegando al salón de la cajera. Hay que decirlo.
      expect(
        resolve(TerminalMode.cloud, 'http://192.168.1.50:4000'),
        HubLinkState.disconnected,
      );
    });

    test('local sin Hub configurado → no se dibuja', () {
      expect(resolve(TerminalMode.cloud, null), isNull);
      expect(resolve(TerminalMode.solo, null), isNull);
    });

    test('estando conectado no se pinta rojo por tener IP guardada', () {
      expect(
        resolve(TerminalMode.hubClient, 'http://192.168.1.50:4000'),
        HubLinkState.connected,
      );
    });
  });
}
