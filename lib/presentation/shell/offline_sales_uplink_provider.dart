import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/connectivity_service.dart';
import '../../core/offline/offline_pos_service.dart';
import '../../core/offline/offline_queue_work.dart';
import '../../core/offline/offline_sales_uplink.dart';
import '../../core/offline/session_release_responder.dart';
import '../../services/session/session_controller.dart';
import '../sales/viewmodel/sales_viewmodel.dart';

/// Un disparo del uplink: corre una pasada automática SOLO si hay algo listo
/// para subir, con las mismas reglas que la pasada (backoff, dead-letter,
/// entregas al Hub y órdenes detenidas por un fallo anterior no despiertan
/// una pasada cada 5 s). Si el negocio cambió mientras se revisaba, no corre.
///
/// [whenIdle] espera a que termine una pasada en curso antes de preguntar:
/// mientras corre, la cola responde «nada listo», y lo guardado después de
/// que esa pasada leyó la cola se perdía hasta el siguiente timer.
@visibleForTesting
Future<void> drainReadyOfflineSales({
  required String? Function() activeBusinessId,
  required Future<bool> Function(String businessId) hasReady,
  required Future<void> Function() sync,
  Future<void> Function(String businessId)? whenIdle,
}) async {
  final businessId = activeBusinessId();
  if (businessId == null || businessId.isEmpty) return;
  if (whenIdle != null) {
    await whenIdle(businessId);
    if (activeBusinessId() != businessId) return;
  }
  if (!await hasReady(businessId)) return;
  if (activeBusinessId() != businessId) return;
  await sync();
}

/// Avisos de trabajo nuevo que despiertan al uplink: solo los del negocio
/// activo. El aviso trae el negocio de la operación; el de otro negocio sigue
/// en su cola y sube al volver a él (el cambio de negocio dispara), sin tocar
/// las cuentas del negocio abierto.
@visibleForTesting
Stream<OfflineQueueWork> queueWorkForActiveBusiness(
  Stream<OfflineQueueWork> work,
  String? Function() activeBusinessId,
) => work.where((event) => event.businessId == activeBusinessId());

final offlineSalesUplinkProvider = Provider<OfflineSalesUplink>((ref) {
  final connectivity = ConnectivityService();
  unawaited(connectivity.initialize());
  final offline = OfflinePosService();
  // T02: con red, este equipo responde los pedidos de liberación de mesa de
  // las cuentas en las que participa (como mucho cada 30 s), después de
  // intentar subir lo suyo.
  final releaseResponder = SessionReleaseResponder(
    repository: () => ref.read(salesRepositoryProvider),
  );
  // Al volver al primer plano los timers pudieron no correr (el sistema
  // suspende el proceso): se revisa la cola durable en el acto.
  final resumes = StreamController<void>.broadcast();
  final lifecycle = AppLifecycleListener(onResume: () => resumes.add(null));
  final uplink = OfflineSalesUplink(
    connectionStream: connectivity.connectionStream,
    isConnected: () => connectivity.isConnected,
    wakeups: [
      queueWorkForActiveBusiness(
        offline.queueWork,
        () => ref.read(sessionProvider).activeBusinessId,
      ),
      resumes.stream,
    ],
    drain: () async {
      await drainReadyOfflineSales(
        activeBusinessId: () => ref.read(sessionProvider).activeBusinessId,
        whenIdle: offline.whenQueueIdle,
        hasReady: offline.hasActionsReadyToSync,
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
  ref.onDispose(() {
    uplink.dispose();
    lifecycle.dispose();
    unawaited(resumes.close());
  });
  return uplink;
});
