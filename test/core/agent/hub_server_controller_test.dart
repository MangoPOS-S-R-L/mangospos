import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/agent/hub_server_controller.dart';
import 'package:mangopos/core/offline/hub/hub_config.dart';

/// Cuándo un equipo levanta el servidor Dart dedicado de `/hub/*`.
///
/// El bug que fija: la regla miraba solo el MODO, y un respaldo resuelve a
/// `hubClient`. En Windows eso dejaba al respaldo sin servidor, el Hub no tenía
/// dónde mandarle las réplicas, y la protección contra "el Hub se rompe y se
/// pierden las ventas de todo el local" no existía en esa plataforma.
void main() {
  bool serve({
    TerminalMode mode = TerminalMode.hubClient,
    HubDeviceRole role = HubDeviceRole.pos,
    NetworkPolicy policy = NetworkPolicy.hub,
    TargetPlatform platform = TargetPlatform.windows,
    bool isWeb = false,
  }) =>
      shouldServeHubServer(
        mode: mode,
        role: role,
        policy: policy,
        platform: platform,
        isWeb: isWeb,
      );

  group('Windows / Linux', () {
    test('el Hub levanta el servidor', () {
      expect(serve(mode: TerminalMode.hubHost, role: HubDeviceRole.hub), isTrue);
    });

    // EL BUG.
    test('el respaldo TAMBIÉN lo levanta, aunque su modo sea hubClient', () {
      expect(
        serve(mode: TerminalMode.hubClient, role: HubDeviceRole.hubBackup),
        isTrue,
      );
    });

    test('el respaldo lo levanta aunque el Hub esté caído (modo solo)', () {
      expect(
        serve(mode: TerminalMode.solo, role: HubDeviceRole.hubBackup),
        isTrue,
      );
    });

    test('una caja normal NO', () {
      expect(serve(role: HubDeviceRole.pos), isFalse);
    });

    // Rol viejo de cuando el local estaba en modo Hub: no tiene sentido tener
    // un servidor escuchando que nadie usa.
    test('respaldo con la política en cloud NO', () {
      expect(
        serve(
          mode: TerminalMode.cloud,
          role: HubDeviceRole.hubBackup,
          policy: NetworkPolicy.cloud,
        ),
        isFalse,
      );
    });

    test('Linux se comporta igual que Windows', () {
      expect(
        serve(platform: TargetPlatform.linux, role: HubDeviceRole.hubBackup),
        isTrue,
      );
    });
  });

  // En estas plataformas el agente Dart en-proceso ya sirve /hub/* en 4000
  // siempre. Un segundo servidor sería redundante.
  group('Mac / tablet / móvil / web', () {
    test('macOS nunca levanta el dedicado, ni siendo Hub', () {
      expect(
        serve(
          platform: TargetPlatform.macOS,
          mode: TerminalMode.hubHost,
          role: HubDeviceRole.hub,
        ),
        isFalse,
      );
    });

    test('Android nunca, ni siendo respaldo', () {
      expect(
        serve(
          platform: TargetPlatform.android,
          role: HubDeviceRole.hubBackup,
        ),
        isFalse,
      );
    });

    test('iOS nunca', () {
      expect(
        serve(platform: TargetPlatform.iOS, mode: TerminalMode.hubHost),
        isFalse,
      );
    });

    test('web nunca', () {
      expect(serve(isWeb: true, mode: TerminalMode.hubHost), isFalse);
    });
  });
}
