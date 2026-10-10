import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/network_printer_recovery.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const mac = '00:11:22:33:44:55';
const otherMac = '00:11:22:33:44:66';
const oldIp = '192.168.1.80';
const newIp = '192.168.1.91';

PrinterConfig printer({
  String business = 'business',
  String? identity = mac,
  int port = 9100,
}) => PrinterConfig(
  id: 'printer',
  businessId: business,
  name: 'Cocina',
  type: 'network',
  ipAddress: oldIp,
  port: port,
  mac: identity,
  isActive: true,
  createdAt: DateTime(2026),
);

class Harness {
  Harness({NetworkPrinterRecoveryState? state})
    : state = state ?? NetworkPrinterRecoveryState(persistLocally: false) {
    recovery = NetworkPrinterRecovery(
      state: this.state,
      now: () => time,
      probe: (ip, port) async {
        ports.add(port);
        return identities.containsKey(ip);
      },
      captureMac: (ip, _) async => identities[ip],
      scan: (identity, previous, port, id) async {
        scans++;
        expect(identity, mac);
        expect(previous, oldIp);
        expect(id, 'printer');
        ports.add(port);
        return scanWait == null ? scanResult : await scanWait!.future;
      },
      configuredIp: (_) async {
        reads++;
        return dbIp;
      },
      save: (_, ip, identity) async {
        writes++;
        savedIp = ip;
        expect(identity, mac);
        if (identityConflict)
          throw const NetworkPrinterIdentityException(
            'MAC changed during scan',
          );
        if (offline) throw StateError('WAN offline');
      },
    );
  }
  final NetworkPrinterRecoveryState state;
  late NetworkPrinterRecovery recovery;
  final identities = <String, String?>{};
  final ports = <int>[];
  DateTime time = DateTime(2026);
  String? dbIp;
  String? scanResult;
  String? savedIp;
  Completer<String?>? scanWait;
  bool offline = false;
  bool identityConflict = false;
  int scans = 0;
  int reads = 0;
  int writes = 0;

  Future<String> resolve({PrinterConfig? config}) =>
      recovery.resolve(printer: config ?? printer(), cachedIp: oldIp);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'healthy identity needs neither subnet scan nor database lookup',
    () async {
      final h = Harness()..identities[oldIp] = mac;
      expect(await h.resolve(), oldIp);
      expect(h.scans, 0);
      expect(h.reads, 0);
      expect(h.writes, 0);
    },
  );

  test(
    'DHCP recovery skips a reachable old IP belonging to another printer',
    () async {
      final h = Harness()
        ..identities[oldIp] = otherMac
        ..identities[newIp] = mac
        ..scanResult = newIp;
      final events = <PrinterAddressChange>[];
      final subscription = h.state.changes.listen(events.add);
      expect(await h.resolve(config: printer(port: 9102)), newIp);
      await Future<void>.delayed(Duration.zero);
      expect(h.scans, 1);
      expect(h.savedIp, newIp);
      expect(h.ports.every((port) => port == 9102), isTrue);
      expect(events.single.ipAddress, newIp);
      expect(events.single.businessId, 'business');
      await subscription.cancel();
    },
  );

  test(
    'resolver candidate with the wrong MAC never becomes a print target',
    () async {
      final h = Harness()
        ..identities[oldIp] = otherMac
        ..identities[newIp] = otherMac
        ..scanResult = newIp;
      await expectLater(
        h.resolve(),
        throwsA(isA<NetworkPrinterIdentityException>()),
      );
      expect(h.state.knownIp(printer()), isNull);
      expect(h.writes, 0);
    },
  );

  test('fresh database IP also requires the saved MAC', () async {
    final h = Harness()
      ..dbIp = newIp
      ..identities[newIp] = otherMac;
    await expectLater(
      h.resolve(),
      throwsA(isA<NetworkPrinterIdentityException>()),
    );
    expect(h.writes, 0);
  });

  test(
    'verified local IP survives failed WAN save and is reused next ticket',
    () async {
      final h = Harness()
        ..offline = true
        ..identities[newIp] = mac
        ..scanResult = newIp;
      expect(await h.resolve(), newIp);
      h.scanResult = null;
      expect(await h.resolve(), newIp);
      expect(h.scans, 1);
      expect(h.writes, 1);
      h.time = h.time.add(const Duration(seconds: 31));
      h.offline = false;
      expect(await h.resolve(), newIp);
      expect(h.writes, 2);
    },
  );

  test(
    'persisted verified address is a candidate after restart, checked again',
    () async {
      final h = Harness(state: NetworkPrinterRecoveryState())
        ..offline = true
        ..identities[newIp] = mac
        ..scanResult = newIp;
      expect(await h.resolve(), newIp);
      final restarted = Harness(state: NetworkPrinterRecoveryState())
        ..offline = true
        ..identities[newIp] = mac;
      expect(await restarted.resolve(), newIp);
      expect(restarted.scans, 0);
      restarted.identities[newIp] = otherMac;
      await expectLater(
        restarted.resolve(),
        throwsA(isA<NetworkPrinterIdentityException>()),
      );
    },
  );

  test('concurrent heartbeat and tickets share one identity scan', () async {
    final h = Harness()
      ..identities[newIp] = mac
      ..scanWait = Completer<String?>();
    final first = h.resolve();
    final second = h.resolve();
    await Future<void>.delayed(Duration.zero);
    expect(h.scans, 1);
    h.scanWait!.complete(newIp);
    expect(await Future.wait([first, second]), [newIp, newIp]);
    expect(h.writes, 1);
  });

  test(
    'failed scans have a cooldown that expires for the next recovery',
    () async {
      final h = Harness();
      for (var i = 0; i < 2; i++) {
        await expectLater(
          h.resolve(),
          throwsA(isA<NetworkPrinterIdentityException>()),
        );
      }
      expect(h.scans, 1);
      h.time = h.time.add(const Duration(seconds: 31));
      h.identities[newIp] = mac;
      h.scanResult = newIp;
      expect(await h.resolve(), newIp);
      expect(h.scans, 2);
    },
  );

  test('business and changed MAC isolate stored network addresses', () async {
    final h = Harness()
      ..identities[newIp] = mac
      ..scanResult = newIp;
    expect(await h.resolve(), newIp);
    expect(h.state.knownIp(printer(business: 'other')), isNull);
    expect(h.state.knownIp(printer(identity: otherMac)), isNull);
    expect(h.state.knownIp(printer(port: 9102)), isNull);
  });

  test(
    'legacy printer captures its MAC and retains it during WAN outage',
    () async {
      final h = Harness()
        ..identities[oldIp] = mac
        ..offline = true;
      final config = printer(identity: null);
      expect(await h.resolve(config: config), oldIp);
      expect(h.state.knownMac(config), mac);
      h.identities.remove(oldIp);
      h.identities[newIp] = mac;
      h.scanResult = newIp;
      expect(await h.resolve(config: config), newIp);
      expect(h.scans, 1);
    },
  );

  test('manual identity changes can clear the durable IP override', () async {
    final h = Harness(state: NetworkPrinterRecoveryState())
      ..identities[newIp] = mac
      ..scanResult = newIp;
    expect(await h.resolve(), newIp);
    await h.state.forgetPrinter('printer');
    expect(h.state.knownIp(printer()), isNull);
    final restarted = Harness(state: NetworkPrinterRecoveryState());
    await expectLater(
      restarted.resolve(),
      throwsA(isA<NetworkPrinterIdentityException>()),
    );
    expect(restarted.scans, 1);
  });

  test(
    'returning to configured IP replaces an obsolete pending WAN write',
    () async {
      final h = Harness()
        ..offline = true
        ..identities[newIp] = mac
        ..scanResult = newIp;
      expect(await h.resolve(), newIp);
      h.identities.remove(newIp);
      h.identities[oldIp] = mac;
      h.offline = false;
      expect(await h.resolve(), oldIp);
      expect(h.savedIp, oldIp);
      expect(h.state.knownIp(printer()), oldIp);
    },
  );

  test(
    'stale callers do not repeat an acknowledged WAN address update',
    () async {
      final h = Harness()
        ..identities[newIp] = mac
        ..scanResult = newIp;
      expect(await h.resolve(), newIp);
      expect(await h.resolve(), newIp);
      expect(h.writes, 1);
    },
  );

  test(
    'successful DHCP round trip corrects remote IP despite stale caller',
    () async {
      final h = Harness()
        ..identities[newIp] = mac
        ..scanResult = newIp;
      expect(await h.resolve(), newIp);
      h.identities.remove(newIp);
      h.identities[oldIp] = mac;
      expect(await h.resolve(), oldIp);
      expect(h.savedIp, oldIp);
      expect(h.writes, 2);
    },
  );

  test(
    'manual configuration change invalidates a pending subnet scan',
    () async {
      final h = Harness()
        ..identities[newIp] = mac
        ..scanWait = Completer<String?>();
      final pending = h.resolve();
      final checked = expectLater(
        pending,
        throwsA(isA<NetworkPrinterIdentityException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await h.state.forgetPrinter('printer');
      h.scanWait!.complete(newIp);
      await checked;
      expect(h.state.knownIp(printer()), isNull);
      expect(h.writes, 0);
    },
  );

  test(
    'remote identity conflict stops printing instead of being treated as WAN outage',
    () async {
      final h = Harness()
        ..identities[newIp] = mac
        ..scanResult = newIp
        ..identityConflict = true;
      await expectLater(
        h.resolve(),
        throwsA(isA<NetworkPrinterIdentityException>()),
      );
      expect(h.state.knownIp(printer()), isNull);
    },
  );
}
