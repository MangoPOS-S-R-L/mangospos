import 'hub_config.dart';
import 'hub_lan_token.dart';
import 'hub_lease_service.dart';

/// Prepare a single authority while online, then retain it across WAN outages.
/// Never elect a replacement merely because the current Hub cannot be reached.
class HubAutoSetup {
  HubAutoSetup({
    required this.readRole,
    required this.writeRole,
    required this.acquireLease,
    required this.readToken,
  });

  final Future<HubDeviceRole> Function(String) readRole;
  final Future<void> Function(String, HubDeviceRole) writeRole;
  final Future<HubLeaseResult> Function(String) acquireLease;
  final Future<String> Function(String) readToken;
  String? status;
  final Map<String, DateTime> _lastAttempt = {};

  Future<HubDeviceRole> prepare(
    String businessId, {
    required bool online,
    required bool canHost,
  }) async {
    final role = await readRole(businessId);
    if (role != HubDeviceRole.pos || !canHost) return role;
    if (!online) {
      _lastAttempt.remove(businessId);
      status = 'La caja aun no ha completado su preparacion automatica.';
      return role;
    }
    final now = DateTime.now();
    final previous = _lastAttempt[businessId];
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 30)) {
      return role;
    }
    _lastAttempt[businessId] = now;
    try {
      final token = await readToken(
        businessId,
      ).timeout(const Duration(seconds: 4));
      if (token.isEmpty || token == kLegacyHubLanToken) {
        status = 'Pendiente de credencial privada de intranet.';
        return role;
      }
      final result = await acquireLease(
        businessId,
      ).timeout(const Duration(seconds: 4));
      if (result.status == HubLeaseStatus.held) {
        await writeRole(businessId, HubDeviceRole.hub);
        status = null;
        return HubDeviceRole.hub;
      }
      status = result.status == HubLeaseStatus.heldByOther
          ? null
          : 'No se pudo confirmar la caja principal; se reintentara automaticamente.';
    } catch (_) {
      status =
          'Preparacion automatica pendiente; se reintentara al recuperar conexion.';
    }
    return role;
  }
}
