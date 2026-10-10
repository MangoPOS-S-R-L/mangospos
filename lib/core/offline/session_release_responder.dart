import 'package:flutter/foundation.dart';

import '../../data/repositories/sales_repository.dart';
import '../utils/device_utils.dart';
import 'offline_pos_service.dart';

/// T02 (20261010_0030): responde los pedidos de liberación de mesa de las
/// cuentas en las que participa este equipo. Para cada una confirma la versión
/// pedida diciendo si tiene algo de esas órdenes sin subir (cola local y, en el
/// Hub, su op-log). El servidor libera solo cuando todas las terminales
/// participantes confirmaron sin pendientes la misma versión; un equipo que no
/// responde (sin red) retiene la cuenta.
class SessionReleaseResponder {
  SessionReleaseResponder({
    required SalesRepository Function() repository,
    OfflinePosService? offline,
    Future<String> Function()? deviceId,
    this.interval = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _repository = repository,
       _offline = offline ?? OfflinePosService(),
       _deviceId = deviceId ?? DeviceUtils.getDeviceId,
       _clock = clock ?? DateTime.now;

  final SalesRepository Function() _repository;
  final OfflinePosService _offline;
  final Future<String> Function() _deviceId;
  final DateTime Function() _clock;

  /// Mínimo entre dos consultas al servidor.
  final Duration interval;

  /// Sin la migración (PGRST202) se vuelve a probar después de esto.
  static const missingMigrationPause = Duration(minutes: 10);

  DateTime? _lastRun;
  DateTime? _pausedUntil;
  bool _busy = false;

  /// Responde lo que haya para [businessId]. Devuelve cuántas confirmaciones
  /// envió. Nunca lanza.
  Future<int> respond(String businessId, {bool force = false}) async {
    if (businessId.isEmpty || _busy) return 0;
    final now = _clock();
    final paused = _pausedUntil;
    if (!force && paused != null && now.isBefore(paused)) return 0;
    final last = _lastRun;
    if (!force && last != null && now.difference(last) < interval) return 0;
    _busy = true;
    _lastRun = now;
    var sent = 0;
    try {
      final repository = _repository();
      final deviceId = await _deviceId();
      final requests = await repository.pendingReleaseRequests(
        businessId,
        deviceId,
      );
      if (requests.isEmpty) return 0;
      final includeHub = await _offline.isHubHostDevice(businessId);
      for (final request in requests) {
        final hasPending = await _offline.hasPendingWorkForOrders(
          businessId,
          request.orderIds.toSet(),
          includeHubOpLog: includeHub,
        );
        await repository.ackSessionRelease(
          sessionId: request.sessionId,
          deviceId: deviceId,
          version: request.version,
          hasPendingWork: hasPending,
        );
        sent++;
      }
    } catch (e) {
      if (e.toString().contains('PGRST202')) {
        _pausedUntil = now.add(missingMigrationPause);
      }
      debugPrint('[SessionReleaseResponder] $e');
    } finally {
      _busy = false;
    }
    return sent;
  }
}
