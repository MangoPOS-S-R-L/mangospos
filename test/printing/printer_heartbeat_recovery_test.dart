import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/printing/printer_heartbeat_provider.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PrinterConfig _printer(
  String id, {
  String type = 'network',
  bool active = true,
  String? ip = '192.168.1.20',
  Map<String, dynamic> connection = const {},
}) => PrinterConfig(
  id: id,
  businessId: 'b1',
  name: id,
  type: type,
  ipAddress: ip,
  isActive: active,
  createdAt: DateTime.utc(2026),
  connectionConfig: connection,
);

class _FakeRepository extends PrintingRepository {
  _FakeRepository()
    : super(
        SupabaseClient(
          'https://example.invalid',
          'key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );

  final knownIps = <String, String>{};
  final resolutions = <String, String>{};
  final failures = <String>{};
  final resolved = <({String id, String cachedIp})>[];
  final probed = <({String ip, int port})>[];
  bool probeResult = true;
  Completer<List<PrinterConfig>>? pendingLoad;
  var loadCalls = 0;

  @override
  Future<List<PrinterConfig>> getActivePrinters(String businessId) async {
    loadCalls++;
    return pendingLoad?.future ?? [_printer('p1')];
  }

  @override
  String? getKnownNetworkIp(PrinterConfig printer) => knownIps[printer.id];

  @override
  Future<String> resolveReachableNetworkIp({
    required PrinterConfig printer,
    required String cachedIp,
    bool includeMacRecovery = true,
  }) async {
    resolved.add((id: printer.id, cachedIp: cachedIp));
    if (failures.contains(printer.id)) throw StateError('MAC distinta');
    return resolutions.containsKey(printer.id)
        ? resolutions[printer.id]!
        : cachedIp;
  }

  @override
  Future<bool> probePrinter({
    String? ip,
    int port = 9100,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    probed.add((ip: ip ?? '', port: port));
    return probeResult;
  }
}

void main() {
  testWidgets('ticks largos no se solapan y el siguiente sondeo se agrupa', (
    tester,
  ) async {
    final repo = _FakeRepository()
      ..pendingLoad = Completer<List<PrinterConfig>>();
    final container = ProviderContainer(
      overrides: [printingPrintersRepositoryProvider.overrideWithValue(repo)],
    );
    container.listen(
      printerHeartbeatProvider('b1'),
      (_, _) {},
      fireImmediately: true,
    );
    await tester.pump();
    expect(repo.loadCalls, 1);
    await tester.pump(const Duration(seconds: 60));
    expect(repo.loadCalls, 1);
    final pending = repo.pendingLoad!;
    repo.pendingLoad = null;
    pending.complete([_printer('p1')]);
    await tester.pump();
    await tester.pump();
    expect(repo.loadCalls, 2);
    container.dispose();
    await tester.pump();
  });

  testWidgets('un fetch que termina después de dispose no inicia recovery', (
    tester,
  ) async {
    final repo = _FakeRepository()
      ..pendingLoad = Completer<List<PrinterConfig>>();
    final container = ProviderContainer(
      overrides: [printingPrintersRepositoryProvider.overrideWithValue(repo)],
    );
    container.listen(
      printerHeartbeatProvider('b1'),
      (_, _) {},
      fireImmediately: true,
    );
    await tester.pump();
    container.dispose();
    repo.pendingLoad!.complete([_printer('p1')]);
    await tester.pump();
    expect(repo.resolved, isEmpty);
  });

  test(
    'resuelve por identidad antes de sondear y muestra la IP corregida',
    () async {
      final repo = _FakeRepository()..resolutions['p1'] = '192.168.1.25';
      final status = await probeNetworkPrinterStatus(
        repo,
        _printer('p1', connection: {'port': '9101'}),
      );
      expect(repo.resolved, [(id: 'p1', cachedIp: '192.168.1.20')]);
      expect(repo.probed, [(ip: '192.168.1.25', port: 9101)]);
      expect(status.online, isTrue);
      expect(status.ipAddress, '192.168.1.25');
    },
  );

  test(
    'override local corregido se usa aunque la nube aún tenga la IP vieja',
    () async {
      final repo = _FakeRepository()..knownIps['p1'] = '192.168.1.25';
      final status = await probeNetworkPrinterStatus(repo, _printer('p1'));
      expect(repo.resolved.single.cachedIp, '192.168.1.25');
      expect(status.ipAddress, '192.168.1.25');
    },
  );

  test(
    'MAC equivocada sin recuperación marca offline sin sondear esa IP',
    () async {
      final repo = _FakeRepository()..failures.add('p1');
      final status = await probeNetworkPrinterStatus(repo, _printer('p1'));
      expect(status.online, isFalse);
      expect(repo.probed, isEmpty);
    },
  );

  test('resolución vacía no marca online optimista', () async {
    final repo = _FakeRepository()..resolutions['p1'] = '';
    final status = await probeNetworkPrinterStatus(
      repo,
      _printer('p1', ip: null),
    );
    expect(status.online, isFalse);
    expect(repo.probed, isEmpty);
  });

  test('probe fallido conserva dirección resuelta y marca offline', () async {
    final repo = _FakeRepository()
      ..resolutions['p1'] = '192.168.1.25'
      ..probeResult = false;
    final status = await probeNetworkPrinterStatus(repo, _printer('p1'));
    expect(status.online, isFalse);
    expect(status.ipAddress, '192.168.1.25');
  });

  test(
    'fallo individual no oculta otras impresoras ni sondea inactivas o USB',
    () async {
      final repo = _FakeRepository()..failures.add('p1');
      final statuses = await probeNetworkPrinters(repo, [
        _printer('p1'),
        _printer('p2'),
        _printer('p3', active: false),
        _printer('p4', type: 'usb'),
      ]);
      expect(statuses.keys, ['p1', 'p2']);
      expect(statuses['p1']!.online, isFalse);
      expect(statuses['p2']!.online, isTrue);
      expect(repo.resolved.map((p) => p.id), ['p1', 'p2']);
    },
  );
}
