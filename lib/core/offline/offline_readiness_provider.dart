import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/offline_auth_service.dart';
import '../storage/storage_service.dart';
import '../../services/session/session_controller.dart';
import 'offline_readiness.dart';
import 'offline_refreshers.dart';

final offlineReadinessProvider = FutureProvider<OfflineReadiness>((ref) async {
  final businessId = ref.watch(
    sessionProvider.select((s) => s.activeBusinessId),
  );
  ref.watch(offlineSyncCoordinatorProvider);
  if (businessId == null || businessId.isEmpty) {
    return OfflineReadiness(checks: const [], checkedAt: DateTime.now());
  }
  // Reevaluar caducidad de permisos y copias locales incluso sin WAN.
  final timer = Timer.periodic(
    const Duration(minutes: 1),
    (_) => ref.invalidateSelf(),
  );
  ref.onDispose(timer.cancel);
  final storage = await StorageService.getInstance();
  return OfflineReadinessInspector(
    read: storage.read,
    checkAccess: (bid) async {
      final auth = OfflineAuthService();
      if (await auth.isRosterStale(bid)) {
        return const OfflineReadinessCheck(
          'Acceso con PIN',
          false,
          'PIN pendientes de actualizar. Se descargan automáticamente con la sesión del negocio o desde la caja principal por intranet.',
        );
      }
      final users = await auth.cachedRoster(bid);
      final available = users.any(
        (u) => u.isActive && (u.pinHash?.isNotEmpty ?? false),
      );
      return OfflineReadinessCheck(
        'Acceso con PIN',
        available,
        available
            ? 'Hay usuarios con PIN guardado. Los permisos vencen a las 24 horas de su descarga.'
            : 'No hay usuarios activos con PIN descargado.',
      );
    },
  ).inspect(businessId);
});
