import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/lan_mac_recovery.dart';

class _Lan {
  List<String> localAddresses = ['192.168.1.10'];
  final openHosts = <String>{};
  final neighbors = <String, String>{};
  final snmp = <String, List<String>>{};
  final probes = <(String, int)>[];
  final neighborQueries = <String>[];
  int concurrentProbes = 0;
  int maximumConcurrentProbes = 0;
  int? hangAfterProbe;
  bool hangIdentity = false;
  Duration? probeDelay;
  final never = Completer<void>();

  LanMacRecoveryIo get io => LanMacRecoveryIo(
    localIpv4Addresses: (timeout) async => localAddresses,
    probePort: (ip, port, timeout) async {
      probes.add((ip, port));
      concurrentProbes++;
      if (concurrentProbes > maximumConcurrentProbes) {
        maximumConcurrentProbes = concurrentProbes;
      }
      try {
        if (hangAfterProbe != null && probes.length > hangAfterProbe!) {
          await never.future;
        }
        if (probeDelay != null) await Future<void>.delayed(probeDelay!);
        return openHosts.contains(ip);
      } finally {
        concurrentProbes--;
      }
    },
    neighborMac: (ip, timeout) async {
      neighborQueries.add(ip);
      if (hangIdentity) await never.future;
      return neighbors[ip];
    },
    snmpMacs: (ip, timeout) async {
      if (hangIdentity) await never.future;
      return snmp[ip] ?? const [];
    },
  );
}

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

    test('rejects broadcast, multicast and malformed identity text', () {
      for (final invalid in [
        'ff:ff:ff:ff:ff:ff',
        '01:00:5e:00:00:01',
        '33:33:00:00:00:01',
        '11:22:33:44:55:66',
        'zz001162aabbcc',
        '00/11/62/aa/bb/cc',
        '00:11-62:aa:bb:cc',
        '0:11:62:aa:bb:cc',
        '00:11:62:aa:bb:cc:dd',
      ]) {
        expect(LanMacRecovery.normalizeMac(invalid), isNull, reason: invalid);
      }
      expect(
        LanMacRecovery.normalizeMac(' 001162AABBCC '),
        '00:11:62:aa:bb:cc',
      );
      expect(
        LanMacRecovery.normalizeMac('02:11:62:aa:bb:cc'),
        '02:11:62:aa:bb:cc',
      );
    });
  });

  group('LanMacRecovery.parseIpNeighOutput', () {
    test('extrae lladdr de una entrada REACHABLE', () {
      const output =
          '192.168.1.50 dev wlan0 lladdr 00:11:62:AA:BB:CC REACHABLE\n';
      expect(LanMacRecovery.parseIpNeighOutput(output), '00:11:62:aa:bb:cc');
    });

    test('devuelve null cuando la entrada no tiene lladdr (FAILED)', () {
      const output = '192.168.1.50 dev wlan0 FAILED\n';
      expect(LanMacRecovery.parseIpNeighOutput(output), isNull);
    });

    test('devuelve null con salida vacía', () {
      expect(LanMacRecovery.parseIpNeighOutput(''), isNull);
    });

    test('matches the exact address and rejects stale/failed neighbors', () {
      const entries = '''
192.168.1.50 dev wlan0 lladdr 00:11:62:aa:bb:cc REACHABLE
192.168.1.5 dev wlan0 lladdr 00:11:62:aa:bb:dd REACHABLE
''';
      expect(
        LanMacRecovery.parseIpNeighOutput(entries, ip: '192.168.1.5'),
        '00:11:62:aa:bb:dd',
      );
      expect(LanMacRecovery.parseIpNeighOutput(entries), isNull);
      for (final status in [
        'STALE',
        'FAILED',
        'INCOMPLETE',
        'DELAY',
        'PROBE',
      ]) {
        expect(
          LanMacRecovery.parseIpNeighOutput(
            '192.168.1.5 dev wlan0 lladdr 00:11:62:aa:bb:cc $status',
            ip: '192.168.1.5',
          ),
          isNull,
        );
      }
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
  192.168.1.5           12-22-33-44-55-66     dinamico
''';
      expect(
        LanMacRecovery.parseArpOutput(output, '192.168.1.5'),
        '12:22:33:44:55:66',
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

    test('conflicting interfaces and truncated MACs are not identities', () {
      const duplicate = '''
192.168.1.50 ether 00:11:62:aa:bb:cc C eth0
192.168.1.50 ether 00:11:62:aa:bb:dd C eth1
''';
      expect(LanMacRecovery.parseArpOutput(duplicate, '192.168.1.50'), isNull);
      for (final invalid in [
        '00:11:62:aa:bb:cc:dd',
        'ff:ff:ff:ff:ff:ff',
        '00:11-62:aa:bb:cc',
      ]) {
        expect(
          LanMacRecovery.parseArpOutput(
            '192.168.1.50 ether $invalid C eth0',
            '192.168.1.50',
          ),
          isNull,
        );
      }
    });
  });

  group('fresh endpoint identity', () {
    const mac = '00:11:62:aa:bb:cc';
    const ip = '192.168.1.50';

    test(
      'TCP port and matching neighbor are verified without print data',
      () async {
        final lan = _Lan()
          ..openHosts.add(ip)
          ..neighbors[ip] = mac;
        expect(
          await LanMacRecovery.captureMacForIp(ip, tcpPort: 9200, io: lan.io),
          mac,
        );
        expect(lan.probes, [(ip, 9200)]);
      },
    );

    test('SNMP contradicting a cached DHCP neighbor fails closed', () async {
      final lan = _Lan()
        ..openHosts.add(ip)
        ..neighbors[ip] = mac
        ..snmp[ip] = ['00:11:62:aa:bb:dd'];
      expect(await LanMacRecovery.captureMacForIp(ip, io: lan.io), isNull);
    });

    test(
      'a closed TCP port cannot authenticate a stale neighbor entry',
      () async {
        final lan = _Lan()..neighbors[ip] = mac;
        expect(await LanMacRecovery.captureMacForIp(ip, io: lan.io), isNull);
        expect(lan.neighborQueries, isEmpty);
        lan.snmp[ip] = [mac];
        expect(await LanMacRecovery.captureMacForIp(ip, io: lan.io), mac);
      },
    );

    test('SNMP-only capture rejects ambiguous interface identities', () async {
      final lan = _Lan()..snmp[ip] = [mac, '00:11:62:aa:bb:dd'];
      expect(await LanMacRecovery.captureMacForIp(ip, io: lan.io), isNull);
      lan.snmp[ip] = [mac, '00-11-62-AA-BB-CC', '00:00:00:00:00:00'];
      expect(await LanMacRecovery.captureMacForIp(ip, io: lan.io), mac);
    });

    test('known MAC can identify one of several SNMP interfaces', () async {
      final lan = _Lan()
        ..openHosts.add(ip)
        ..snmp[ip] = ['00:11:62:aa:bb:dd', mac];
      expect(
        await LanMacRecovery.captureMacForIp(
          ip,
          expectedMac: '00-11-62-AA-BB-CC',
          io: lan.io,
        ),
        mac,
      );
      expect(await LanMacRecovery.captureMacForIp(ip, io: lan.io), isNull);
      expect(
        await LanMacRecovery.captureMacForIp(
          ip,
          expectedMac: '00:11:62:aa:bb:ee',
          io: lan.io,
        ),
        isNull,
      );
    });

    test('known SNMP MAC cannot override a different fresh neighbor', () async {
      const other = '00:11:62:aa:bb:dd';
      final lan = _Lan()
        ..openHosts.add(ip)
        ..neighbors[ip] = other
        ..snmp[ip] = [mac, other];
      expect(
        await LanMacRecovery.captureMacForIp(ip, expectedMac: mac, io: lan.io),
        other,
      );
      lan.snmp[ip] = [mac];
      expect(
        await LanMacRecovery.captureMacForIp(ip, expectedMac: mac, io: lan.io),
        isNull,
      );
      lan.neighbors.clear();
      lan.snmp[ip] = [other];
      expect(
        await LanMacRecovery.captureMacForIp(ip, expectedMac: mac, io: lan.io),
        other,
      );
    });

    test('invalid expected identity causes no network operation', () async {
      final lan = _Lan();
      for (final invalid in ['', 'ff:ff:ff:ff:ff:ff', '00:11-62:aa:bb:cc']) {
        expect(
          await LanMacRecovery.captureMacForIp(
            ip,
            expectedMac: invalid,
            io: lan.io,
          ),
          isNull,
        );
      }
      expect(lan.probes, isEmpty);
    });

    test('invalid address and port cause no network operation', () async {
      final lan = _Lan();
      for (final address in [
        'printer.local',
        '192.168.1.500',
        '224.0.0.1',
        '127.0.0.1',
        '192.168.1.50;bad',
      ]) {
        expect(
          await LanMacRecovery.captureMacForIp(address, io: lan.io),
          isNull,
        );
      }
      for (final port in [0, -1, 65536]) {
        expect(
          await LanMacRecovery.captureMacForIp(ip, tcpPort: port, io: lan.io),
          isNull,
        );
      }
      expect(lan.probes, isEmpty);
    });

    test('hung identity lookups respect one total deadline', () async {
      final lan = _Lan()
        ..openHosts.add(ip)
        ..hangIdentity = true;
      final elapsed = Stopwatch()..start();
      expect(
        await LanMacRecovery.captureMacForIp(
          ip,
          timeout: const Duration(milliseconds: 30),
          io: lan.io,
        ),
        isNull,
      );
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('bounded subnet resolution', () {
    const mac = '00:11:62:aa:bb:cc';
    const previous = '192.168.1.50';

    test(
      'ignores a different printer at the old IP and finds a second interface subnet',
      () async {
        final lan = _Lan()
          ..localAddresses = [
            '192.168.1.10',
            '10.2.0.10',
            '192.168.1.11',
            '127.0.0.1',
            '169.254.1.3',
          ]
          ..openHosts.addAll([previous, '10.2.0.80'])
          ..neighbors[previous] = '00:11:62:aa:bb:dd'
          ..neighbors['10.2.0.80'] = mac;
        expect(
          await LanMacRecovery.resolveIpByMac(
            mac: mac,
            previousIp: previous,
            tcpPort: 9200,
            io: lan.io,
          ),
          '10.2.0.80',
        );
        expect(lan.probes.first, (previous, 9200));
        expect(lan.probes.every((probe) => probe.$2 == 9200), isTrue);
        expect(lan.probes.where((probe) => probe.$1 == previous), hasLength(1));
        expect(
          lan.probes.any((probe) => probe.$1.startsWith('169.254.')),
          isFalse,
        );
        expect(
          lan.probes.map((probe) => probe.$1).toSet(),
          hasLength(lan.probes.length),
        );
      },
    );

    test('the previous IP is usable only with a matching fresh MAC', () async {
      final lan = _Lan()
        ..openHosts.add(previous)
        ..neighbors[previous] = mac;
      expect(
        await LanMacRecovery.resolveIpByMac(
          mac: mac,
          previousIp: previous,
          io: lan.io,
        ),
        previous,
      );
    });

    test('a later DHCP move never reuses the previous lookup result', () async {
      final lan = _Lan()
        ..openHosts.add(previous)
        ..neighbors[previous] = mac;
      expect(
        await LanMacRecovery.resolveIpByMac(mac: mac, io: lan.io),
        previous,
      );
      lan.openHosts.add('192.168.1.60');
      lan.neighbors[previous] = '00:11:62:aa:bb:dd';
      lan.neighbors['192.168.1.60'] = mac;
      expect(
        await LanMacRecovery.resolveIpByMac(
          mac: mac,
          previousIp: previous,
          io: lan.io,
        ),
        '192.168.1.60',
      );
    });

    test('two endpoints claiming the same MAC are ambiguous', () async {
      final lan = _Lan()
        ..localAddresses = ['192.168.1.10', '10.2.0.10']
        ..openHosts.addAll([previous, '10.2.0.80'])
        ..neighbors[previous] = mac
        ..neighbors['10.2.0.80'] = mac;
      expect(await LanMacRecovery.resolveIpByMac(mac: mac, io: lan.io), isNull);
    });

    test(
      'SNMP-only discovery works when the platform has no neighbor table',
      () async {
        final lan = _Lan()
          ..openHosts.add(previous)
          ..snmp[previous] = [mac];
        expect(
          await LanMacRecovery.resolveIpByMac(mac: mac, io: lan.io),
          previous,
        );
      },
    );

    test('resolves a known SNMP interface without a neighbor table', () async {
      final lan = _Lan()
        ..openHosts.add(previous)
        ..snmp[previous] = [mac, '00:11:62:aa:bb:dd'];
      expect(
        await LanMacRecovery.resolveIpByMac(mac: mac, io: lan.io),
        previous,
      );
      lan.openHosts.add('192.168.1.60');
      lan.snmp['192.168.1.60'] = [mac, '00:11:62:aa:bb:ee'];
      expect(await LanMacRecovery.resolveIpByMac(mac: mac, io: lan.io), isNull);
      lan.openHosts.remove('192.168.1.60');
      lan.neighbors[previous] = '00:11:62:aa:bb:dd';
      expect(await LanMacRecovery.resolveIpByMac(mac: mac, io: lan.io), isNull);
    });

    test(
      'hints prioritize attached subnets and never scan a remote range',
      () async {
        final lan = _Lan()..localAddresses = ['192.168.1.10', '10.2.0.10'];
        expect(
          await LanMacRecovery.resolveIpByMac(
            mac: mac,
            subnetHints: ['203.0.113.1', '10.2.0.'],
            io: lan.io,
          ),
          isNull,
        );
        expect(lan.probes.first.$1, '10.2.0.1');
        expect(
          lan.probes.any((probe) => probe.$1.startsWith('203.0.113.')),
          isFalse,
        );
      },
    );

    test('an incomplete scan never returns an early match', () async {
      final lan = _Lan()
        ..openHosts.add('192.168.1.20')
        ..neighbors['192.168.1.20'] = mac
        ..hangAfterProbe = 32;
      final elapsed = Stopwatch()..start();
      expect(
        await LanMacRecovery.resolveIpByMac(
          mac: mac,
          timeout: const Duration(milliseconds: 50),
          io: lan.io,
        ),
        isNull,
      );
      expect(lan.neighborQueries, contains('192.168.1.20'));
      expect(lan.maximumConcurrentProbes, lessThanOrEqualTo(32));
      expect(lan.probes.length, lessThanOrEqualTo(64));
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test(
      'limits responding candidate identities and excessive networks',
      () async {
        final lan = _Lan()
          ..openHosts.addAll([
            for (var host = 1; host <= 254; host++) '192.168.1.$host',
          ]);
        expect(
          await LanMacRecovery.resolveIpByMac(mac: mac, io: lan.io),
          isNull,
        );
        expect(lan.neighborQueries, hasLength(32));
        expect(lan.probes, hasLength(64));

        final manyInterfaces = _Lan()
          ..localAddresses = [
            for (var net = 1; net <= 5; net++) '192.168.$net.10',
          ];
        expect(
          await LanMacRecovery.resolveIpByMac(mac: mac, io: manyInterfaces.io),
          isNull,
        );
        expect(manyInterfaces.probes, isEmpty);
      },
    );

    test('invalid stored hardware identity does not start a scan', () async {
      final lan = _Lan();
      expect(
        await LanMacRecovery.resolveIpByMac(
          mac: 'ff:ff:ff:ff:ff:ff',
          io: lan.io,
        ),
        isNull,
      );
      expect(lan.probes, isEmpty);
    });
  });

  group('SNMP response identity', () {
    // Fixed wire fixture: SNMPv1/public, request 7, interface MAC
    // 00:11:62:aa:bb:cc at ifPhysAddress.1.
    final response = Uint8List.fromList([
      0x30,
      0x2e,
      0x02,
      0x01,
      0x00,
      0x04,
      0x06,
      0x70,
      0x75,
      0x62,
      0x6c,
      0x69,
      0x63,
      0xa2,
      0x21,
      0x02,
      0x01,
      0x07,
      0x02,
      0x01,
      0x00,
      0x02,
      0x01,
      0x00,
      0x30,
      0x16,
      0x30,
      0x14,
      0x06,
      0x0a,
      0x2b,
      0x06,
      0x01,
      0x02,
      0x01,
      0x02,
      0x02,
      0x01,
      0x06,
      0x01,
      0x04,
      0x06,
      0x00,
      0x11,
      0x62,
      0xaa,
      0xbb,
      0xcc,
    ]);

    test('reads a valid hardware-address response', () {
      final decoded = LanMacRecovery.decodeSnmpGetResponse(response, 7);
      expect(decoded?.$1, [1, 3, 6, 1, 2, 1, 2, 2, 1, 6, 1]);
      expect(decoded?.$2, [0, 0x11, 0x62, 0xaa, 0xbb, 0xcc]);
    });

    test('rejects another request, version, community and error result', () {
      expect(LanMacRecovery.decodeSnmpGetResponse(response, 8), isNull);
      expect(
        LanMacRecovery.decodeSnmpGetResponse(response, 7, community: 'private'),
        isNull,
      );
      for (final (offset, value) in [(4, 1), (20, 5), (23, 1), (39, 0x81)]) {
        final invalid = Uint8List.fromList(response)..[offset] = value;
        expect(LanMacRecovery.decodeSnmpGetResponse(invalid, 7), isNull);
      }
    });

    test('malformed/truncated BER never supplies an identity', () {
      for (var length = 0; length < response.length; length++) {
        expect(
          LanMacRecovery.decodeSnmpGetResponse(
            Uint8List.sublistView(response, 0, length),
            7,
          ),
          isNull,
        );
      }
      expect(
        LanMacRecovery.decodeSnmpGetResponse(
          Uint8List.fromList([...response, 0]),
          7,
        ),
        isNull,
      );
      expect(
        LanMacRecovery.decodeSnmpGetResponse(
          Uint8List.fromList([0x30, 0x80, 0, 0]),
          7,
        ),
        isNull,
      );
    });
  });
}
