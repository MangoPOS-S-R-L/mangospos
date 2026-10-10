import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_sales_uplink.dart';
import 'package:mangopos/presentation/shell/offline_sales_uplink_provider.dart';

void main() {
  test('sube al arrancar online sin emitir reconexión', () async {
    final connection = StreamController<bool>();
    var calls = 0;
    final uplink = OfflineSalesUplink(
      connectionStream: connection.stream,
      isConnected: () => true,
      drain: () async {
        calls++;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    uplink.dispose();
    await connection.close();
  });

  test('espera conexión y drena al recuperarla', () async {
    final connection = StreamController<bool>();
    var online = false;
    var calls = 0;
    final uplink = OfflineSalesUplink(
      connectionStream: connection.stream,
      isConnected: () => online,
      drain: () async {
        calls++;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    online = true;
    connection.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    uplink.dispose();
    await connection.close();
  });

  test('recupera fallo transitorio con el timer sin otra reconexión', () async {
    final connection = StreamController<bool>();
    final completed = Completer<void>();
    var attempts = 0;
    final uplink = OfflineSalesUplink(
      connectionStream: connection.stream,
      isConnected: () => true,
      interval: const Duration(milliseconds: 10),
      drain: () async {
        attempts++;
        if (attempts == 1) throw TimeoutException('red intermitente');
        if (!completed.isCompleted) completed.complete();
      },
    );
    await completed.future.timeout(const Duration(seconds: 2));
    expect(attempts, greaterThanOrEqualTo(2));
    uplink.dispose();
    await connection.close();
  });

  test(
    'cambio de negocio durante subida corre después sin solaparse',
    () async {
      final connection = StreamController<bool>();
      final gate = Completer<void>();
      var businessId = 'a';
      final businesses = <String>[];
      final uplink = OfflineSalesUplink(
        connectionStream: connection.stream,
        isConnected: () => true,
        drain: () async {
          businesses.add(businessId);
          if (businesses.length == 1) await gate.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      businessId = 'b';
      await uplink.trigger();
      expect(businesses, ['a']);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(businesses, ['a', 'b']);
      uplink.dispose();
      await connection.close();
    },
  );

  test('disponer detiene timers y reconexiones', () async {
    final connection = StreamController<bool>();
    var calls = 0;
    final uplink = OfflineSalesUplink(
      connectionStream: connection.stream,
      isConnected: () => true,
      drain: () async {
        calls++;
      },
    );
    uplink.dispose();
    connection.add(true);
    await uplink.trigger();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    await connection.close();
  });

  group('drenaje solo con acciones listas', () {
    test('nada listo: no corre pasada; listo: una sola', () async {
      var syncs = 0;
      var ready = false;
      Future<void> drain() => drainReadyOfflineSales(
        activeBusinessId: () => 'a',
        hasReady: (_) async => ready,
        sync: () async => syncs++,
      );
      await drain();
      expect(syncs, 0);
      ready = true;
      await drain();
      expect(syncs, 1);
    });

    test('sin negocio activo no pregunta ni sincroniza', () async {
      var asked = 0;
      var syncs = 0;
      for (final business in [null, '']) {
        await drainReadyOfflineSales(
          activeBusinessId: () => business,
          hasReady: (_) async {
            asked++;
            return true;
          },
          sync: () async => syncs++,
        );
      }
      expect(asked, 0);
      expect(syncs, 0);
    });

    test('cambio de negocio durante la revisión: no sincroniza', () async {
      var business = 'a';
      final asked = <String>[];
      var syncs = 0;
      await drainReadyOfflineSales(
        activeBusinessId: () => business,
        hasReady: (id) async {
          asked.add(id);
          business = 'b';
          return true;
        },
        sync: () async => syncs++,
      );
      expect(asked, ['a']);
      expect(syncs, 0);
    });

    test('el timer del uplink no despierta pasadas sin nada listo', () async {
      final connection = StreamController<bool>();
      var ready = false;
      var checks = 0;
      var syncs = 0;
      final uplink = OfflineSalesUplink(
        connectionStream: connection.stream,
        isConnected: () => true,
        interval: const Duration(milliseconds: 10),
        drain: () => drainReadyOfflineSales(
          activeBusinessId: () => 'a',
          hasReady: (_) async {
            checks++;
            return ready;
          },
          sync: () async => syncs++,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(checks, greaterThan(1));
      expect(syncs, 0);
      ready = true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(syncs, greaterThanOrEqualTo(1));
      uplink.dispose();
      await connection.close();
    });
  });
}
