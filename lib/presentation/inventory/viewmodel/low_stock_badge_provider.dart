// Sprint 4 — Badge global de alertas de stock bajo.
//
// Exposición liviana del conteo de alertas para el botón de notificaciones
// del shell. Polling cada 60 segundos. Si el negocio activo cambia, se
// vuelve a emitir el primer valor.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/session/session_controller.dart';
import 'inventory_viewmodel.dart';

/// Intervalo de polling del badge. 60s balancea frescura vs. costo.
const _kPollingInterval = Duration(seconds: 60);

/// Emite el conteo de alertas activas para el negocio del SessionState.
/// - Si no hay negocio activo: emite `0` y no hace requests.
/// - Si falla la query: emite el último valor conocido (no propaga el error
///   al header, para no romper la UI con un banner).
final lowStockBadgeCountProvider = StreamProvider<int>((ref) {
  final repo = ref.watch(inventoryRepositoryProvider);
  final businessId = ref.watch(
    sessionProvider.select((s) => s.activeBusinessId),
  );

  final controller = StreamController<int>();
  int lastValue = 0;
  Timer? timer;
  bool closed = false;

  Future<void> tick() async {
    if (closed) return;
    if (businessId == null) {
      controller.add(0);
      return;
    }
    try {
      final count = await repo.getLowStockAlertsCount(businessId: businessId);
      lastValue = count;
      if (!closed) controller.add(count);
    } catch (_) {
      // Silenciar errores; el header no debe mostrar alertas técnicas.
      if (!closed) controller.add(lastValue);
    }
  }

  // Disparar inmediatamente + programar polling.
  tick();
  timer = Timer.periodic(_kPollingInterval, (_) => tick());

  ref.onDispose(() {
    closed = true;
    timer?.cancel();
    controller.close();
  });

  return controller.stream;
});
