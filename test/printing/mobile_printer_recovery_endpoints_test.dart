import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/agent/mobile_print_agent.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:shelf/shelf.dart' as shelf;

const _mac = 'a0:b1:c2:d3:e4:f5';
const _otherMac = 'b0:b1:c2:d3:e4:f5';

PrinterConfig _printer({String business = 'b1', bool active = true}) =>
    PrinterConfig(
      id: 'p1',
      businessId: business,
      name: 'Cocina',
      type: 'network',
      ipAddress: '192.168.1.20',
      port: 9101,
      mac: _mac,
      isActive: active,
      createdAt: DateTime.utc(2026),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobilePrintAgent agent;
  late String business;
  late List<PrinterConfig> printers;
  late Map<String, String> identities;
  late List<({String mac, String previousIp, int port})> scans;
  late List<({String ip, int port})> probes;
  late String? foundIp;
  late bool cloudFailure;
  late DateTime now;
  late List<({String ip, int port, List<int> data})> writes;

  setUp(() {
    business = 'b1';
    printers = [_printer()];
    identities = {'192.168.1.20': _mac, '192.168.1.25': _mac};
    scans = [];
    probes = [];
    foundIp = '192.168.1.25';
    cloudFailure = false;
    now = DateTime.utc(2026);
    writes = [];
    agent = MobilePrintAgent(
      activeBusinessId: () async => business,
      networkNow: () => now,
      networkWrite: (ip, port, data) async {
        writes.add((ip: ip, port: port, data: data.toList()));
      },
      networkPrinters: () async {
        if (cloudFailure) throw StateError('WAN caída');
        return printers;
      },
      networkProbe: (ip, port) async {
        probes.add((ip: ip, port: port));
        return identities.containsKey(ip);
      },
      networkMac: (ip, _) async => identities[ip],
      networkScan: (mac, previousIp, port) async {
        scans.add((mac: mac, previousIp: previousIp, port: port));
        return foundIp;
      },
    );
  });

  Future<shelf.Response> post(String path, Map<String, dynamic> body) async =>
      agent.handlerForTesting(
        shelf.Request(
          'POST',
          Uri.parse('http://localhost$path'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer MANGOPOS_SECURE_TOKEN_123',
          },
          body: jsonEncode(body),
        ),
      );

  Future<Map<String, dynamic>> jsonOf(shelf.Response response) async =>
      jsonDecode(await response.readAsString()) as Map<String, dynamic>;

  test('captura MAC solamente de dirección y puerto registrados', () async {
    final response = await post('/api/printers/mac-for-ip', {
      'ip': '192.168.1.20',
      'port': 9101,
    });
    expect(response.statusCode, 200);
    expect(await jsonOf(response), {
      'ip': '192.168.1.20',
      'port': 9101,
      'mac': _mac,
      'verified': true,
    });
    expect(
      (await post('/api/printers/mac-for-ip', {
        'ip': '192.168.1.30',
        'port': 9101,
      })).statusCode,
      403,
    );
    expect(
      (await post('/api/printers/mac-for-ip', {
        'ip': '192.168.1.20',
        'port': 9100,
      })).statusCode,
      403,
    );
    expect(scans, isEmpty);
  });

  test('rechaza MAC o ID ajenos antes de buscar por la LAN', () async {
    for (final body in [
      {'printerId': 'otro', 'mac': _mac, 'port': 9101},
      {'printerId': 'p1', 'mac': _otherMac, 'port': 9101},
      {'printerId': 'p1', 'mac': _mac, 'port': 9100},
    ]) {
      expect(
        (await post('/api/printers/resolve-by-mac', body)).statusCode,
        403,
      );
    }
    expect(scans, isEmpty);
    expect(probes, isEmpty);
  });

  test('rechaza impresora inactiva y MAC multicast', () async {
    printers = [_printer(active: false)];
    expect(
      (await post('/api/printers/resolve-by-mac', {
        'printerId': 'p1',
        'mac': _mac,
        'port': 9101,
      })).statusCode,
      403,
    );
    expect(
      (await post('/api/printers/resolve-by-mac', {
        'printerId': 'p1',
        'mac': '01:00:5e:00:00:01',
        'port': 9101,
      })).statusCode,
      400,
    );
    expect(scans, isEmpty);
  });

  test(
    'recupera DHCP conservando puerto y verifica MAC de la nueva dirección',
    () async {
      identities['192.168.1.20'] = _otherMac;
      final response = await post('/api/printers/resolve-by-mac', {
        'printerId': 'p1',
        'mac': _mac,
        'port': 9101,
      });
      expect(response.statusCode, 200);
      expect(await jsonOf(response), {
        'ip': '192.168.1.25',
        'port': 9101,
        'mac': _mac,
        'verified': true,
      });
      expect(scans, [(mac: _mac, previousIp: '192.168.1.20', port: 9101)]);
      expect(probes.every((probe) => probe.port == 9101), isTrue);
    },
  );

  test(
    'una respuesta de búsqueda con otra MAC nunca queda verificada',
    () async {
      identities['192.168.1.20'] = _otherMac;
      identities['192.168.1.25'] = _otherMac;
      final response = await post('/api/printers/resolve-by-mac', {
        'printerId': 'p1',
        'mac': _mac,
        'port': 9101,
      });
      final body = await jsonOf(response);
      expect(body['verified'], isFalse);
      expect(body['ip'], isNull);
    },
  );

  test(
    'corrección local sigue autorizada mientras no llega el guardado en nube',
    () async {
      identities['192.168.1.20'] = _otherMac;
      await post('/api/printers/resolve-by-mac', {
        'printerId': 'p1',
        'mac': _mac,
        'port': 9101,
      });
      cloudFailure = true;
      now = now.add(const Duration(seconds: 3));
      final body = await jsonOf(
        await post('/check-connectivity', {
          'printers': [
            {'ip': '192.168.1.25', 'port': 9101},
            {'ip': '192.168.1.30', 'port': 9101},
          ],
        }),
      );
      expect(body['results']['192.168.1.25:9101'], isTrue);
      expect(body['results']['192.168.1.30:9101'], isFalse);
    },
  );

  test(
    'IP corregida offline recibe bytes solo tras confirmar identidad',
    () async {
      identities['192.168.1.20'] = _otherMac;
      await post('/api/printers/resolve-by-mac', {
        'printerId': 'p1',
        'mac': _mac,
        'port': 9101,
      });
      cloudFailure = true;
      now = now.add(const Duration(seconds: 3));
      final response = await post('/api/printers/raw', {
        'ip': '192.168.1.25',
        'port': 9101,
        'data': base64Encode([1, 2, 3]),
      });
      expect(response.statusCode, 200);
      expect(writes, hasLength(1));
      expect(writes.single.ip, '192.168.1.25');
      expect(writes.single.port, 9101);
      expect(writes.single.data, [1, 2, 3]);
    },
  );

  test(
    'MAC equivocada en IP registrada impide enviar cualquier byte',
    () async {
      identities['192.168.1.20'] = _otherMac;
      final response = await post('/api/printers/raw', {
        'ip': '192.168.1.20',
        'port': 9101,
        'data': base64Encode([1, 2, 3]),
      });
      expect(response.statusCode, 500);
      expect(writes, isEmpty);
      expect(scans, isEmpty);
    },
  );

  test(
    'cambio de negocio elimina autorización del snapshot anterior',
    () async {
      await post('/api/printers/mac-for-ip', {
        'ip': '192.168.1.20',
        'port': 9101,
      });
      business = 'b2';
      cloudFailure = true;
      expect(
        (await post('/api/printers/mac-for-ip', {
          'ip': '192.168.1.20',
          'port': 9101,
        })).statusCode,
        403,
      );
    },
  );

  test('resoluciones concurrentes comparten una búsqueda', () async {
    identities['192.168.1.20'] = _otherMac;
    final responses = await Future.wait(
      List.generate(
        2,
        (_) => post('/api/printers/resolve-by-mac', {
          'printerId': 'p1',
          'mac': _mac,
          'port': 9101,
        }),
      ),
    );
    expect(scans.length, 1);
    for (final response in responses) {
      expect((await jsonOf(response))['verified'], isTrue);
    }
  });

  test('payload inválido no inicia probes ni búsqueda', () async {
    expect(
      (await post('/api/printers/mac-for-ip', {
        'ip': '192.168.1.20',
        'port': 65536,
      })).statusCode,
      400,
    );
    expect(
      (await post('/check-connectivity', {
        'printers': List.generate(33, (_) => {}),
      })).statusCode,
      400,
    );
    expect(probes, isEmpty);
    expect(scans, isEmpty);
  });
}
