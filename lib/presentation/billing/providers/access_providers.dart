// Providers del bloqueo del POS por falta de pago.
//
// El estado lo resuelve `AccountAccessRepository` (servidor con caída a
// snapshot local). Acá solo se expone a la UI y se le da un punto único de
// refresco manual — el guard lo usa al volver del background.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/account_access_state.dart';
import '../../../data/repositories/account_access_repository.dart';

/// Estado de acceso del negocio activo. Re-emite por Realtime de memberships
/// (suspensión automática) y por poll (cortes manuales del panel).
final accountAccessProvider =
    StreamProvider.family<AccountAccessState, String>((ref, businessId) {
  final repo = ref.watch(accountAccessRepositoryProvider);
  return repo.watch(businessId);
});

/// Fuerza una consulta fresca. Se llama al reanudar la app y después de que el
/// dueño registra un pago, para que el desbloqueo no espere al próximo poll.
final refreshAccountAccessProvider = Provider<void Function(String)>((ref) {
  return (String businessId) => ref.invalidate(accountAccessProvider(businessId));
});
