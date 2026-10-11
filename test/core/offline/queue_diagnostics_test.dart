// Fase 4 de la guía de cierre: diagnóstico visible de la cola. Cada
// operación dice POR QUÉ no ha subido; el visor resume la más antigua, la
// última pasada y el último avance real; la bitácora local (acotada, sin
// credenciales) permite explicar una retención larga después.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/core/offline/offline_queue_status_provider.dart';
import 'package:mangopos/core/offline/offline_queue_trace.dart';
import 'package:mangopos/core/offline/offline_queue_wait_reason.dart';
import 'package:mangopos/presentation/shell/main_shell.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoBusiness extends SessionController {
  @override
  SessionState build() => const SessionState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('motivo de espera de cada operación', () {
    final now = DateTime(2026, 10, 10, 21, 30);
    String reason(Map<String, dynamic> a, {bool online = true}) =>
        offlineQueueWaitReason(a, online: online, now: now);

    test('lo que se resuelve solo vs. lo que necesita a una persona', () {
      expect(reason({'status': 'processing'}), 'Subiendo ahora');
      expect(
        reason({'status': 'dead', 'kitchen_uncertain': true}),
        'Revisión necesaria: no se confirmó si salió la comanda',
      );
      expect(
        reason({'status': 'dead', 'payment_resolution': 'closed_session'}),
        'Revisión necesaria: cobro por decidir',
      );
      expect(reason({'status': 'dead'}), 'Revisión necesaria');
      expect(
        reason({
          'status': 'failed',
          'kitchen_hold': true,
          OfflinePosService.kitchenHoldWaitingItemsKey: ['tmp_1'],
        }),
        'Esperando que suba el producto',
      );
      expect(
        reason({
          'status': 'failed',
          'kitchen_hold': true,
          'last_error':
              'Falta actualizar el servidor (migración 20261010_0002)',
        }),
        'Esperando actualización del servidor',
      );
      expect(reason({'status': 'pending'}, online: false), 'Sin conexión');
      expect(
        reason({
          'status': 'failed',
          'next_retry_at': DateTime(2026, 10, 10, 21, 35, 7).toIso8601String(),
        }),
        'Reintento programado a las 21:35:07',
      );
      expect(
        reason({
          'status': 'failed',
          'next_retry_at': DateTime(2026, 10, 10, 21).toIso8601String(),
        }),
        'Error del servidor',
      );
      expect(reason({'status': 'pending'}), 'En cola para subir');
    });
  });

  test('resumen del visor: más antigua, última pasada y último avance', () {
    final now = DateTime(2026, 10, 10, 22, 27);
    final line = offlineQueueSummaryLine(
      [
        {'queued_at': DateTime(2026, 10, 10, 21, 15, 6).toIso8601String()},
        {'queued_at': DateTime(2026, 10, 10, 21, 51, 36).toIso8601String()},
      ],
      OfflineQueueStatus(
        pending: 2,
        lastPassAt: DateTime(2026, 10, 10, 22, 26, 59),
        lastProgressAt: DateTime(2026, 10, 10, 21, 2),
      ),
      now: now,
    );
    expect(line, contains('Más antigua: hace 71 min'));
    expect(line, contains('Última pasada 22:26:59'));
    expect(line, contains('Último avance 21:02:00'));

    expect(
      offlineQueueSummaryLine(const [], const OfflineQueueStatus(), now: now),
      'Sin avance en esta sesión',
    );
  });

  test('la pasada automática anota la hora; el avance solo si subió algo, '
      'y sin cambiar el resultado que avisa el shell', () {
    final c = ProviderContainer(
      overrides: [sessionProvider.overrideWith(_NoBusiness.new)],
    );
    addTearDown(c.dispose);
    final status = c.read(offlineQueueStatusProvider.notifier);
    status.publishSyncResult(
      const OfflineQueueSyncResult(pending: 1, skipped: 1),
      automatic: true,
    );
    var s = c.read(offlineQueueStatusProvider);
    expect(s.lastPassAt, isNotNull);
    expect(s.lastProgressAt, isNull, reason: 'saltar no es avanzar');
    expect(s.lastResult, isNull, reason: 'automática: sin aviso');

    status.publishSyncResult(
      const OfflineQueueSyncResult(processed: 1, completed: 1),
      automatic: true,
    );
    s = c.read(offlineQueueStatusProvider);
    expect(s.lastProgressAt, isNotNull);
    expect(s.lastResult, isNull);
  });

  group('bitácora local de la cola', () {
    test('guarda los eventos en orden, acotada a los más recientes', () async {
      const biz = 'trace-bounded';
      final trace = OfflineQueueTrace.instance;
      for (var i = 0; i < OfflineQueueTrace.maxEvents + 15; i++) {
        trace.record(biz, 'guardada', op: 'op-$i', type: 'add_item');
      }
      final events = await trace.read(biz);
      expect(events, hasLength(OfflineQueueTrace.maxEvents));
      expect(events.first['op'], 'op-15');
      expect(events.last['op'], 'op-${OfflineQueueTrace.maxEvents + 14}');
    });

    test('recorta el detalle y lo deja legible para compartir', () async {
      const biz = 'trace-format';
      OfflineQueueTrace.instance.record(
        biz,
        'error',
        op: 'round-1',
        type: 'confirm_local_order',
        order: '114e58fc-1234-4000-8000-000000000001',
        detail: 'x' * 400,
      );
      final events = await OfflineQueueTrace.instance.read(biz);
      final detail = events.single['detail']! as String;
      expect(detail.length, lessThanOrEqualTo(161));
      final text = OfflineQueueTrace.format(events);
      expect(text, contains('error · confirm_local_order · orden 114e58fc'));
      expect(text, contains('op round-1'));
    });
  });
}
