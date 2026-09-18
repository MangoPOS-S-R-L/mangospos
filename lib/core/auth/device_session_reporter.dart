// Reporta la sesión de este equipo a "Dispositivos conectados" y obedece el
// cierre remoto (migración 20260918_0001).
//
// Cuándo reporta:
//   - al quedar autenticado, al cambiar de negocio o de empleado (PIN);
//   - al volver la app a primer plano (si pasó más de 1 min);
//   - cada 5 min mientras la sesión siga abierta.
// Es una fracción del heartbeat de impresión (30 s): ver
// [[project_storage_wal_egress_heartbeat]] antes de acortar el intervalo.
//
// Cierre remoto: si el ping responde `revoked`, se cierra la sesión con el
// mismo signOut() del botón "Cerrar sesión" (que conserva la cola offline).
//
// Se mantiene vivo desde MainShell con `ref.read`, igual que los demás
// servicios del shell.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/session/session_controller.dart';
import '../multimesero/active_waiter_provider.dart';
import 'device_session_service.dart';

const Duration _kPingInterval = Duration(minutes: 5);
const Duration _kResumeMinGap = Duration(minutes: 1);
const Duration _kDebounce = Duration(milliseconds: 1500);
const Duration _kPingTimeout = Duration(seconds: 15);

final deviceSessionReporterProvider = Provider<DeviceSessionReporter>((ref) {
  final reporter = DeviceSessionReporter._(ref);
  ref.onDispose(reporter._dispose);

  // Solo lo que cambia la identidad de la sesión: el state de sesión se
  // re-emite por otras razones (permisos cada 45 s) y no queremos un ping
  // por cada una.
  ref.listen<(AuthStatus, String?, String?, String?)>(
    sessionProvider.select(
      (s) => (s.status, s.userId, s.activeBusinessId, s.employeeId),
    ),
    (_, next) => reporter._onSessionChanged(next.$1 == AuthStatus.authenticated),
    fireImmediately: true,
  );
  ref.listen<String?>(
    activeWaiterProvider.select((w) => w?.employeeId),
    (_, _) => reporter._schedule(),
  );

  reporter._lifecycle = AppLifecycleListener(onResume: reporter._onResume);
  return reporter;
});

class DeviceSessionReporter {
  DeviceSessionReporter._(this._ref);

  final Ref _ref;
  Timer? _timer;
  Timer? _debounce;
  AppLifecycleListener? _lifecycle;
  DateTime? _lastPingAt;
  bool _inFlight = false;
  bool _pingAgain = false;
  bool _signingOut = false;
  bool _disposed = false;

  void _onSessionChanged(bool authenticated) {
    if (!authenticated) {
      _timer?.cancel();
      _timer = null;
      _debounce?.cancel();
      _signingOut = false;
      return;
    }
    _timer ??= Timer.periodic(_kPingInterval, (_) => unawaited(_ping()));
    _schedule();
  }

  void _onResume() {
    final last = _lastPingAt;
    if (last != null && DateTime.now().difference(last) < _kResumeMinGap) {
      return;
    }
    _schedule();
  }

  /// Agrupa cambios seguidos (login → negocio → empleado) en un solo ping.
  void _schedule() {
    if (_disposed) return;
    _debounce?.cancel();
    _debounce = Timer(_kDebounce, () => unawaited(_ping()));
  }

  Future<void> _ping() async {
    if (_disposed || _signingOut) return;
    if (_inFlight) {
      _pingAgain = true;
      return;
    }

    final session = _ref.read(sessionProvider);
    final userId = session.userId;
    final businessId = session.activeBusinessId;
    if (!session.isAuthenticated ||
        userId == null ||
        userId.isEmpty ||
        businessId == null ||
        businessId.isEmpty) {
      return;
    }

    // Empleado activo: el mesero identificado por PIN (si es de este
    // negocio) o, si no hay, el empleado de la cuenta logueada.
    final waiter = _ref.read(activeWaiterProvider);
    final employeeId =
        (waiter != null && waiter.businessId == businessId)
            ? waiter.employeeId
            : session.employeeId;

    _inFlight = true;
    try {
      var result = await DeviceSessionService.ping(
        businessId: businessId,
        userId: userId,
        employeeId: employeeId,
      ).timeout(_kPingTimeout);

      // La key quedó cerrada en el servidor (logout que no llegó a borrarla
      // aquí, o un ping que se cruzó con el cierre): sesión nueva.
      if (result.closed && !result.revoked) {
        await DeviceSessionService.rotateSessionKey(userId);
        result = await DeviceSessionService.ping(
          businessId: businessId,
          userId: userId,
          employeeId: employeeId,
        ).timeout(_kPingTimeout);
      }

      _lastPingAt = DateTime.now();
      if (result.revoked) await _signOutRemotely();
    } catch (e) {
      // Sin red o sin la migración aplicada: se reintenta en el próximo
      // ciclo. Nunca interrumpe al cajero.
      debugPrint('[DeviceSession] ping falló: $e');
    } finally {
      _inFlight = false;
      if (_pingAgain && !_disposed) {
        _pingAgain = false;
        unawaited(_ping());
      }
    }
  }

  Future<void> _signOutRemotely() async {
    if (_signingOut || _disposed) return;
    _signingOut = true;
    debugPrint('[DeviceSession] cierre remoto pedido por un administrador');
    DeviceSessionService.markRevokedNotice();
    // signOut() avisa al servidor (fila → end_reason 'revoked'), conserva la
    // cola offline pendiente y deja el state en unauthenticated; el router
    // manda a login.
    await _ref.read(sessionProvider.notifier).signOut();
  }

  void _dispose() {
    _disposed = true;
    _timer?.cancel();
    _debounce?.cancel();
    _lifecycle?.dispose();
  }
}
