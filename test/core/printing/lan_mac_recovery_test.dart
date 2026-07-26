import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/lan_mac_recovery.dart';

void main() {
  group('LanMacRecovery.normalizeMac', () {
    test('normaliza separadores y mayúsculas a aa:bb:cc:dd:ee:ff', () {
      expect(
        LanMacRecovery.normalizeMac('00-11-62-AA-BB-CC'),
        '00:11:62:aa:bb:cc',
      );
      expect(
        LanMacRecovery.normalizeMac('0011.62aa.bbcc'),
        '00:11:62:aa:bb:cc',
      );
      expect(
        LanMacRecovery.normalizeMac('00:11:62:aa:bb:cc'),
        '00:11:62:aa:bb:cc',
      );
    });

    test('rechaza MACs inválidos o todo-cero', () {
      expect(LanMacRecovery.normalizeMac(null), isNull);
      expect(LanMacRecovery.normalizeMac(''), isNull);
      expect(LanMacRecovery.normalizeMac('00:11:62'), isNull);
      expect(LanMacRecovery.normalizeMac('zz:11:62:aa:bb:cc'), isNull);
      expect(LanMacRecovery.normalizeMac('00:00:00:00:00:00'), isNull);
    });
  });

  group('LanMacRecovery.parseIpNeighOutput', () {
    test('extrae lladdr de una entrada REACHABLE', () {
      const output =
          '192.168.1.50 dev wlan0 lladdr 00:11:62:AA:BB:CC REACHABLE\n';
      expect(
        LanMacRecovery.parseIpNeighOutput(output),
        '00:11:62:aa:bb:cc',
      );
    });

    test('devuelve null cuando la entrada no tiene lladdr (FAILED)', () {
      const output = '192.168.1.50 dev wlan0 FAILED\n';
      expect(LanMacRecovery.parseIpNeighOutput(output), isNull);
    });

    test('devuelve null con salida vacía', () {
      expect(LanMacRecovery.parseIpNeighOutput(''), isNull);
    });
  });
}
