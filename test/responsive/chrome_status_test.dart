import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/app/navigation/chrome_status.dart';

/// Prioridad del cromo global (PRD §7.1) y coste cero en reposo.
void main() {
  test('sin conexión gana sobre la cola de impresión', () {
    expect(
      resolveChromeStatus(serverReachable: false, printQueue: 6),
      ChromeStatus.offline,
    );
  });

  test('con servidor, la cola manda', () {
    expect(
      resolveChromeStatus(serverReachable: true, printQueue: 6),
      ChromeStatus.printQueue,
    );
  });

  test('todo en orden', () {
    final s = resolveChromeStatus(serverReachable: true, printQueue: 0);
    expect(s, ChromeStatus.ok);
    expect(s.isOk, isTrue);
    // Criterio 10: en reposo el estado no reserva altura.
    expect(s.needsBanner, isFalse);
  });

  test('solo hay banner fuera de ok', () {
    expect(ChromeStatus.offline.needsBanner, isTrue);
    expect(ChromeStatus.printQueue.needsBanner, isTrue);
    expect(ChromeStatus.ok.needsBanner, isFalse);
  });
}
