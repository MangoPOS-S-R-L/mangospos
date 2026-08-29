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

  group('LanMacRecovery.parseArpOutput', () {
    test('Windows: MAC con guiones y encabezado en español', () {
      const output = '''
Interfaz: 192.168.1.10 --- 0x5
  Direccion de Internet     Direccion fisica      Tipo
  192.168.1.50          00-11-62-aa-bb-cc     dinamico
  192.168.1.1           aa-bb-cc-dd-ee-ff     dinamico
''';
      expect(
        LanMacRecovery.parseArpOutput(output, '192.168.1.50'),
        '00:11:62:aa:bb:cc',
      );
    });

    test('macOS: rellena los ceros que omite en cada grupo', () {
      const output =
          '? (192.168.1.50) at 0:11:62:a:bb:c on en0 ifscope [ethernet]';
      expect(
        LanMacRecovery.parseArpOutput(output, '192.168.1.50'),
        '00:11:62:0a:bb:0c',
      );
    });

    test('Linux: formato ether', () {
      const output = '192.168.1.50  ether  00:11:62:aa:bb:cc  C  eth0';
      expect(
        LanMacRecovery.parseArpOutput(output, '192.168.1.50'),
        '00:11:62:aa:bb:cc',
      );
    });

    test('no confunde 192.168.1.5 con la fila de 192.168.1.50', () {
      const output = '''
  192.168.1.50          00-11-62-aa-bb-cc     dinamico
  192.168.1.5           11-22-33-44-55-66     dinamico
''';
      expect(
        LanMacRecovery.parseArpOutput(output, '192.168.1.5'),
        '11:22:33:44:55:66',
      );
    });

    test('sin entrada para esa IP devuelve null', () {
      expect(
        LanMacRecovery.parseArpOutput(
          '192.168.1.50 -- no entry',
          '192.168.1.50',
        ),
        isNull,
      );
      expect(LanMacRecovery.parseArpOutput('', '192.168.1.50'), isNull);
    });

    test('descarta el MAC nulo 00:00:00:00:00:00', () {
      const output = '192.168.1.50  ether  00:00:00:00:00:00  C  eth0';
      expect(LanMacRecovery.parseArpOutput(output, '192.168.1.50'), isNull);
    });
  });
}
