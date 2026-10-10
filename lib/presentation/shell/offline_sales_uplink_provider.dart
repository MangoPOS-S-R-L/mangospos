import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/offline/offline_pos_service.dart';
import '../../core/offline/offline_sales_uplink.dart';
import '../../core/offline/session_release_responder.dart';
import '../../services/session/session_controller.dart';
import '../sales/viewmodel/sales_viewmodel.dart';

/// Un disparo del uplink: corre una pasada automática SOLO si hay algo listo
/// para subir, con las mismas reglas que la pasada (backoff, dead-letter,
/// entregas al Hub y órdenes detenidas por un fallo anterior no despiertan
/// una pasada cada 5 s). Si el negocio cambió mientras se revisaba, no corre.
@visibleForTesting
Future<void> drainReadyOfflineSales({
  required String? Function() activeBusinessId,
  required Future<bool> Function(String businessId) hasReady,
  required Future<void> Function() sync,
}) async {
  final businessId = activeBusinessId();
  if (businessId == null || businessId.isEmpty) return;
  if (!await hasReady(businessId)) return;
  if (activeBusinessId() != businessId) return;
  await sync();
}

final offlineSalesUplinkProvider = Provider<OfflineSalesUplink>((ref) {
  final connectivity = ConnectivityService();
  unawaited(connectivity.initialize());
  // T02: con red, este equipo responde los pedidos de liberación de mesa de
  // las cuentas en las que participa (como mucho cada 30 s), después de
  // intentar subir lo suyo.
  final releaseResponder = SessionReleaseResponder(
    repository: () => ref.read(salesRepositoryProvider),
  );
  final uplink = OfflineSalesUplink(
    connectionStream: connectivity.connectionStream,
    isConnected: () => connectivity.isConnected,
    drain: () async {
      await drainReadyOfflineSales(
        activeBusinessId: () => ref.read(sessionProvider).activeBusinessId,
        hasReady: OfflinePosService().hasActionsReadyToSync,
        // Pasada automática (sin force): silenciosa, solo contadores.
        sync: () =>
            ref.read(currentOrderProvider.notifier).syncPendingOfflineActions(),
      );
      final businessId = ref.read(sessionProvider).activeBusinessId;
      if (businessId != null && businessId.isNotEmpty) {
        await releaseResponder.respond(businessId);
      }
    },
  );
  ref.listen(sessionProvider.select((s) => s.activeBusinessId), (_, next) {
    if (next != null) unawaited(uplink.trigger());
  });
  ref.onDispose(uplink.dispose);
  return uplink;
});
