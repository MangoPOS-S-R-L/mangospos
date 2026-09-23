import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/offline/offline_sync_coordinator.dart';

void main() {
  test(
    'publica progreso, conserva errores y los limpia en un reintento',
    () async {
      var fail = true;
      final observed = <int?>[];
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        refreshers: [
          () async {},
          () async {
            if (fail) throw StateError('red');
          },
        ],
      );
      coordinator.addListener(() => observed.add(coordinator.currentStep));
      await coordinator.refreshAll();
      expect(observed, containsAll([0, 1]));
      expect(coordinator.finishedSteps, 2);
      expect(coordinator.failedSteps, {1});
      expect(coordinator.isRefreshing, false);
      fail = false;
      await coordinator.refreshAll();
      expect(coordinator.failedSteps, isEmpty);
      coordinator.dispose();
    },
  );

  test(
    'una descarga colgada no deja el indicador descargando indefinidamente',
    () async {
      var nextRan = false;
      final gate = Completer<void>();
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        refreshTimeout: const Duration(milliseconds: 5),
        refreshers: [() => gate.future, () async => nextRan = true],
      );
      await coordinator.refreshAll();
      expect(coordinator.failedSteps, {0});
      expect(nextRan, true);
      expect(coordinator.isRefreshing, false);
      gate.complete();
      coordinator.dispose();
    },
  );

  test(
    'al cerrar el coordinador no inicia módulos del negocio anterior',
    () async {
      final gate = Completer<void>();
      var nextRan = false;
      final coordinator = OfflineSyncCoordinator(
        connectionStream: const Stream.empty(),
        refreshers: [() => gate.future, () async => nextRan = true],
      );
      final running = coordinator.refreshAll();
      coordinator.dispose();
      gate.complete();
      await running;
      expect(nextRan, false);
    },
  );
}
