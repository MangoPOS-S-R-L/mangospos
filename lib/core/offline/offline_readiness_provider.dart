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
      if (!await auth.isDeviceBound() ||
          await auth.currentBoundBusinessId() != bid) {
        return const OfflineReadinessCheck(
          'Acceso con PIN',
          false,
          'Vincula este equipo con una cuenta de propietario o administrador para poder entrar con PIN sin internet.',
          action: OfflineReadinessAction.bindDevice,
        );
      }
      if (await auth.isRosterStale(bid)) {
        return const OfflineReadinessCheck(
          'Acceso con PIN',
          false,
          'Permisos ausentes o vencidos. Actualízalos con internet.',
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
