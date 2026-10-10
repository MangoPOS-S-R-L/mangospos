import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PrinterConfig config({int port = 9100}) => PrinterConfig(
  id: 'delivery-guard',
  businessId: 'b',
  name: 'Cocina',
  type: 'network',
  ipAddress: '192.168.1.80',
  port: port,
  isActive: true,
  createdAt: DateTime(2026),
);

class FakePrinting extends PrintingRepository {
  FakePrinting() : super(SupabaseClient('https://example.test', 'test'));
  int tcpCalls = 0;
  int agentCalls = 0;
  int cloudCalls = 0;
  PrinterConfig? fresh;
  bool uncertainAgent = false;
  bool preWriteFirst = false;
  bool postFlush = false;

  @override
  Future<String> resolveReachableNetworkIp({
    required PrinterConfig printer,
    required String cachedIp,
    bool includeMacRecovery = true,
  }) async => cachedIp;

  @override
  Future<void> printRawDirectTcp({
    required String ip,
    int port = 9100,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
    int attempts = 2,
  }) async {
    tcpCalls++;
    if (preWriteFirst && port == 9100)
      throw const SocketException('Connection refused');
    if (postFlush)
      throw PrintLikelyDeliveredException(StateError('post-flush reset'));
    throw PrintDeliveryUncertainException(StateError('write interrupted'));
  }

  @override
  Future<bool> isAgentUp() async => true;

  @override
  Future<void> printRawViaAgent({
    required String ip,
    int port = 9100,
    required List<int> data,
    String? mac,
    String? printerId,
  }) async {
    agentCalls++;
    if (uncertainAgent)
      throw PrintDeliveryUncertainException(StateError('response lost'));
    throw StateError('Agent rejected before write');
  }

  @override
  Future<PrinterConfig?> getPrinterById(String printerId) async => fresh;

  @override
  Future<String?> recoverNetworkIpByMac({
    required PrinterConfig printer,
    required String currentIp,
  }) async => null;

  @override
  Future<PrintJob> enqueuePrintJobToCloud({
    required String businessId,
    required String dataHex,
    required String kind,
    required String areaCode,
    String? printerId,
    String? ip,
    int? port,
    String? idempotencyKey,
    int priority = 100,
  }) async {
    cloudCalls++;
    throw StateError('A delivery-uncertain ticket must never reach the cloud.');
  }

  @override
  void captureMacForPrinterIfMissing({
    required String printerId,
    String? ipAddress,
    String? existingMac,
    int port = 9100,
    bool force = false,
  }) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('partial TCP write stops agent fallback and cloud replay', () async {
    final repo = FakePrinting();
    await expectLater(
      repo.printEscPos(
        printer: config(),
        data: [27, 64],
        idempotencyKey: 'stable-ticket',
      ),
      throwsA(isA<PrintDeliveryUncertainException>()),
    );
    expect(repo.tcpCalls, 1);
    expect(repo.agentCalls, 0);
    expect(repo.cloudCalls, 0);
  });

  test('fresh-config retry must preserve delivery uncertainty', () async {
    final repo = FakePrinting()
      ..preWriteFirst = true
      ..fresh = config(port: 9102);
    await expectLater(
      repo.printEscPos(
        printer: config(),
        data: [27, 64],
        idempotencyKey: 'stable-ticket',
      ),
      throwsA(isA<PrintDeliveryUncertainException>()),
    );
    expect(repo.tcpCalls, 4); // Three safe pre-connect attempts + fresh port.
    expect(repo.agentCalls, 1);
    expect(repo.cloudCalls, 0);
  });

  test('lost agent response is not escalated to a second queue', () async {
    final repo = FakePrinting()
      ..preWriteFirst = true
      ..uncertainAgent = true;
    await expectLater(
      repo.printEscPos(
        printer: config(),
        data: [27, 64],
        idempotencyKey: 'stable-ticket',
      ),
      throwsA(isA<PrintDeliveryUncertainException>()),
    );
    expect(repo.agentCalls, 1);
    expect(repo.cloudCalls, 0);
  });

  test('post-flush disconnect keeps existing no-reprint behavior', () async {
    final repo = FakePrinting()..postFlush = true;
    expect(
      await repo.printEscPos(
        printer: config(),
        data: [27, 64],
        idempotencyKey: 'stable-ticket',
      ),
      PrintOutcome.directSuccess,
    );
    expect(repo.tcpCalls, 1);
    expect(repo.agentCalls, 0);
    expect(repo.cloudCalls, 0);
  });
}
