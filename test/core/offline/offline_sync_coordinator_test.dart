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

  // El caso que estaba roto: el equipo nace con internet y NUNCA lo pierde.
  // `connectionStream` es un broadcast sin replay que solo emite en los
  // cambios, así que no llegaba nada y no se sembraba ni un cache — el device
  // llegaba a su primera caída de red en frío.
  test('siembra los caches al arrancar si ya está online (sin que el stream '
      'emita nunca)', () async {
    final conn = StreamController<bool>();
    var calls = 0;
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [() async => calls++],
      isConnectedNow: () => true,
      startupDelay: Duration.zero,
    )..start();

    await Future<void>.delayed(Duration.zero);
    expect(calls, 1, reason: 'debe sembrar sin depender del stream');

    c.dispose();
    await conn.close();
  });

  test('no siembra al arrancar si está offline', () async {
    final conn = StreamController<bool>();
    var calls = 0;
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [() async => calls++],
      isConnectedNow: () => false,
      startupDelay: Duration.zero,
    )..start();

    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);

    c.dispose();
    await conn.close();
  });

  // La semilla no puede comerse la detección de transición: si el device
  // arrancó online y después pierde y recupera la red, esa reconexión SÍ tiene
  // que refrescar.
  test('tras sembrar online, una caída y reconexión vuelve a refrescar',
      () async {
    final conn = StreamController<bool>();
    var online = true;
    var calls = 0;
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [() async => calls++],
      isConnectedNow: () => online,
      startupDelay: Duration.zero,
    )..start();

    await Future<void>.delayed(Duration.zero);
    expect(calls, 1); // semilla

    online = false;
    conn.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1); // caer no refresca

    online = true;
    conn.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2); // la reconexión sí
    c.dispose();
    await conn.close();
  });

  // Arrancar creyéndose online cuando en realidad no lo está (isConnected es
  // optimista hasta que corre el primer probe) no puede tragarse la primera
  // reconexión real.
  test('semilla optimista: si el probe desmiente, la reconexión sigue contando',
      () async {
    final conn = StreamController<bool>();
    var online = true; // optimista, aún sin probe
    var calls = 0;
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [() async => calls++],
      isConnectedNow: () => online,
      startupDelay: Duration.zero,
    )..start();

    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    online = false;
    conn.add(false); // el probe desmiente
    await Future<void>.delayed(Duration.zero);

    online = true;
    conn.add(true); // vuelve de verdad
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);

    c.dispose();
    await conn.close();
  });

  test('el timer periódico usa la lectura en vivo, no el último valor del '
      'stream', () async {
    final conn = StreamController<bool>();
    var calls = 0;
    final c = OfflineSyncCoordinator(
      connectionStream: conn.stream,
      refreshers: [() async => calls++],
      isConnectedNow: () => true,
      startupDelay: const Duration(days: 1), // fuera del camino
      periodic: const Duration(milliseconds: 20),
    )..start();

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, greaterThan(0),
        reason: 'el tick debe refrescar aunque el stream no haya emitido');

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
