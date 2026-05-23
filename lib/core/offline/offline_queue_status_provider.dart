import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/session/session_controller.dart';
import 'offline_pos_service.dart';

/// Snapshot del estado de la cola offline. Lo consumen el badge del topbar
/// y los snackbars post-sync. `pending` cuenta acciones con status !=
/// completed; `lastResult` se rellena cuando termina un sync para que la
/// UI pueda mostrar el resultado.
class OfflineQueueStatus {
  const OfflineQueueStatus({
    this.pending = 0,
    this.lastResult,
  });

  final int pending;
  final OfflineQueueSyncResult? lastResult;

  OfflineQueueStatus copyWith({
    int? pending,
    OfflineQueueSyncResult? lastResult,
  }) =>
      OfflineQueueStatus(
        pending: pending ?? this.pending,
        lastResult: lastResult ?? this.lastResult,
      );
}

/// Notifier que polea `pendingActionsCount` periódicamente y permite a
/// los call-sites de enqueue/sync invalidarlo manualmente para refresh
/// inmediato. El polling vive porque el resto del código encola sin
/// pasar por aquí — un Stream sería más limpio pero requiere refactor
/// invasivo del OfflinePosService.
class OfflineQueueStatusController
    extends StateNotifier<OfflineQueueStatus> {
  OfflineQueueStatusController(this._ref)
      : super(const OfflineQueueStatus()) {
    _start();
  }

  final Ref _ref;
  final OfflinePosService _offlinePos = OfflinePosService();
  Timer? _timer;

  static const Duration _pollInterval = Duration(seconds: 5);

  void _start() {
    unawaited(refreshNow());
    _timer = Timer.periodic(_pollInterval, (_) => refreshNow());
  }

  Future<void> refreshNow() async {
    final businessId = _ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      if (state.pending != 0) {
        state = state.copyWith(pending: 0);
      }
      return;
    }
    try {
      final count = await _offlinePos.pendingActionsCount(businessId);
      if (count != state.pending) {
        state = state.copyWith(pending: count);
      }
    } catch (_) {
      // Falla silenciosa: si no podemos contar la cola, dejamos el
      // último valor conocido. Próximo poll reintenta.
    }
  }

  /// Llamado por los call-sites de sync para publicar el resultado y
  /// disparar la notificación visual (consumida por el listener del shell).
  void publishSyncResult(OfflineQueueSyncResult result) {
    state = OfflineQueueStatus(
      pending: result.pending,
      lastResult: result,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final offlineQueueStatusProvider = StateNotifierProvider<
    OfflineQueueStatusController, OfflineQueueStatus>(
  (ref) => OfflineQueueStatusController(ref),
);
