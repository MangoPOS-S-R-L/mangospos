import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/offline_queue_status_provider.dart';
import 'package:mangopos/core/offline/storage/offline_queue_db.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sincronización automática con internet = sin avisos: una pasada
/// automática solo mueve los contadores del badge/banner y conserva el MISMO
/// `lastResult` (el shell solo muestra snackbar cuando cambia). Solo una
/// pasada pedida por el cajero publica su resultado.
class _Session extends SessionController {
  _Session(this.businessId);
  final String businessId;

  @override
  SessionState build() => SessionState(activeBusinessId: businessId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late OfflineQueueDb db;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
    db = OfflineQueueDb.inMemory(NativeDatabase.memory());
    OfflineQueueDb.debugInstance = db;
  });
  tearDownAll(() => db.close());

  Future<OfflineQueueStatusController> controller(String biz) async {
    final c = ProviderContainer(
      overrides: [sessionProvider.overrideWith(() => _Session(biz))],
    );
    addTearDown(c.dispose);
    final notifier = c.read(offlineQueueStatusProvider.notifier);
    // Que el conteo inicial (cola vacía) no aterrice después del publish.
    await notifier.refreshNow();
    return notifier;
  }

  const noisy = [
    OfflineQueueSyncResult(pending: 3),
    OfflineQueueSyncResult(processed: 1, failed: 1, pending: 2, dead: 1),
    OfflineQueueSyncResult(processed: 2, completed: 2, pending: 1),
    OfflineQueueSyncResult(
      processed: 1,
      completed: 1,
      conflicts: [
        OfflineSyncConflict(actionType: 'delete_item', reason: 'ya no existe'),
      ],
    ),
    OfflineQueueSyncResult(dead: 4),
  ];

  test('pasada automática: nunca publica resultado, aun con fallos o dead, '
      'pero los contadores se actualizan', () async {
    final notifier = await controller('auto-silent');
    for (final result in noisy) {
      notifier.publishSyncResult(result, automatic: true);
      expect(notifier.state.lastResult, isNull);
      expect(notifier.state.pending, result.pending);
      expect(notifier.state.dead, result.dead);
    }
  });

  test('tras un resultado manual, las automáticas conservan la misma '
      'instancia (el shell no repite el aviso)', () async {
    final notifier = await controller('auto-keeps-manual');
    const manual = OfflineQueueSyncResult(
      processed: 1,
      completed: 1,
      pending: 1,
    );
    notifier.publishSyncResult(manual);
    expect(identical(notifier.state.lastResult, manual), isTrue);

    final seen = <OfflineQueueStatus>[];
    notifier.addListener(seen.add, fireImmediately: false);
    for (final result in noisy) {
      notifier.publishSyncResult(result, automatic: true);
    }
    expect(seen, isNotEmpty, reason: 'los contadores sí cambiaron');
    for (final status in seen) {
      expect(identical(status.lastResult, manual), isTrue);
    }
    expect(notifier.state.dead, 4);
  });

  test('pasada pedida por el cajero (force) sí publica su resultado, '
      'incluso sin trabajo hecho', () async {
    final notifier = await controller('manual-publishes');
    const waiting = OfflineQueueSyncResult(pending: 3);
    notifier.publishSyncResult(waiting);
    expect(identical(notifier.state.lastResult, waiting), isTrue);
    expect(notifier.state.pending, 3);
    const failed = OfflineQueueSyncResult(processed: 1, failed: 1, dead: 1);
    notifier.publishSyncResult(failed);
    expect(identical(notifier.state.lastResult, failed), isTrue);
    expect(notifier.state.dead, 1);
  });
}
