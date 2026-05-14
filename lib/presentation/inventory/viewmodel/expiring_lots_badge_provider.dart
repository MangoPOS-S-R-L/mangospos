// Sprint 4 (cierre) — Badge global de lotes próximos a vencer + vencidos.
//
// Emite el conteo combinado de lotes con `expiry_status` en ('critical',
// 'expired') para el negocio activo. Sigue el mismo patrón que
// low_stock_badge_provider: polling cada 60s, silencia errores, retorna
// el último valor conocido si falla.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/session/session_controller.dart';
import 'inventory_viewmodel.dart';

const _kPollingInterval = Duration(seconds: 60);

/// Conteo de lotes en estado crítico (≤7 días para vencer) o ya vencidos.
/// Útil para mostrar un badge en el header que avise al usuario sin que
/// tenga que entrar al módulo de inventario.
final expiringLotsBadgeCountProvider = StreamProvider<int>((ref) {
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
      // Sumamos lotes vencidos + críticos (≤7d). 'warning' (≤30d) NO se
      // cuenta — esos no son urgentes para el badge global.
      final expired = await repo.countLotsByExpiryStatus(
        businessId: businessId,
        expiryStatus: 'expired',
      );
      final critical = await repo.countLotsByExpiryStatus(
        businessId: businessId,
        expiryStatus: 'critical',
      );
      final total = expired + critical;
      lastValue = total;
      if (!closed) controller.add(total);
    } catch (_) {
      if (!closed) controller.add(lastValue);
    }
  }

  tick();
  timer = Timer.periodic(_kPollingInterval, (_) => tick());

  ref.onDispose(() {
    closed = true;
    timer?.cancel();
    controller.close();
  });

  return controller.stream;
});
