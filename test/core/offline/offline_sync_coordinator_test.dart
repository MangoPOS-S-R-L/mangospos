import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_sync_coordinator.dart';

/// Tests del coordinador de bajada (F6): refresca en reconexión, guard de
/// solapamiento, best-effort ante fallos.
void main() {
  test('refresca al pasar offline→online (no en cada tick)', () async {
    final conn = StreamController<bool>();
    var calls = 0;
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [() async => calls++],
    )..start();

    conn.add(false); // sigue offline → no refresca
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);

    conn.add(true); // offline→online → refresca
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    conn.add(true); // ya estaba online → NO vuelve a refrescar
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    c.dispose();
    await conn.close();
  });

  test('corre todos los refreshers; uno que falla no frena a los demás',
      () async {
    final conn = StreamController<bool>();
    final ran = <String>[];
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [
        () async => ran.add('a'),
        () async => throw Exception('boom'),
        () async => ran.add('c'),
      ],
    )..start();

    conn.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(ran, ['a', 'c']); // 'c' corre aunque el del medio falle

    c.dispose();
    await conn.close();
  });

  test('guard de solapamiento: no corre dos refreshAll a la vez', () async {
    final conn = StreamController<bool>();
    final gate = Completer<void>();
    var starts = 0;
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [
        () async {
          starts++;
          await gate.future; // se queda "en vuelo"
        },
      ],
    )..start();

    final first = c.refreshAll(); // arranca y se cuelga en gate
    await Future<void>.delayed(Duration.zero);
    final second = c.refreshAll(); // debería no-op (hay uno en vuelo)
    await second;
    expect(starts, 1); // el segundo no arrancó el refresher

    gate.complete();
    await first;
    c.dispose();
    await conn.close();
  });
}
