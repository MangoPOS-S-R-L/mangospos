import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/hub/hub_config.dart'
    show HubDeviceRole, NetworkPolicy, TerminalMode, kHubPortAlt;
import '../offline/hub/hub_mode_controller.dart' show hubModeProvider;
import 'mobile_print_agent.dart';

/// ¿Este equipo tiene que levantar el servidor Dart dedicado de `/hub/*`?
///
/// Solo aplica a Windows/Linux: ahí el puerto 4000 lo ocupa el agente Node de
/// impresión, que no sabe nada del Hub. En Mac/tablet/móvil el agente Dart
/// en-proceso de `main.dart` ya sirve `/hub/*` en 4000 siempre, así que no hace
/// falta un segundo servidor.
///
/// Lo sirve:
/// - el **Hub** (modo [TerminalMode.hubHost]), que atiende a las cajas;
/// - el **respaldo** ([HubDeviceRole.hubBackup]) con la política en `hub`, que
///   RECIBE las réplicas del op-log en `/hub/replica`.
///
/// Lo segundo es el bug que corrige esta función: antes solo se miraba el modo,
/// y un respaldo resuelve a `hubClient` (habla con el Hub como cualquier caja).
/// En Windows eso significaba que el respaldo no tenía servidor, el Hub no tenía
/// dónde mandarle las réplicas, y la protección contra "el Hub se rompe y se
/// pierden las ventas de todo el local" no existía en esa plataforma.
@visibleForTesting
bool shouldServeHubServer({
  required TerminalMode mode,
  required HubDeviceRole role,
  required NetworkPolicy policy,
  required TargetPlatform platform,
  required bool isWeb,
}) {
  if (isWeb) return false;
  if (platform != TargetPlatform.windows && platform != TargetPlatform.linux) {
    return false;
  }
  if (mode == TerminalMode.hubHost) return true;
  return policy == NetworkPolicy.hub && role == HubDeviceRole.hubBackup;
}

/// Paridad Windows del Hub (H4 + H7). Levanta el servidor Dart dedicado en
/// [kHubPortAlt] cuando [shouldServeHubServer] lo pide y lo apaga cuando deja de
/// hacer falta.
///
/// Reacciona a dos cosas:
/// - cambios de modo ([hubModeProvider]), que cubren al Hub;
/// - un tic periódico, que cubre al RESPALDO: su cambio de rol no altera su
///   modo (sigue en `hubClient`), así que el provider no notifica y escuchar
///   solo el modo dejaría al respaldo sin servidor.
class HubServerController {
  HubServerController(this._ref) {
    _sub = _ref.listen<TerminalMode>(
      hubModeProvider,
      (_, _) => unawaited(_evaluate()),
      fireImmediately: true,
    );
    _timer = Timer.periodic(_recheck, (_) => unawaited(_evaluate()));
  }

  /// Algo menos que el tic de 20 s del [hubModeProvider], para que un cambio de
  /// rol en Ajustes se refleje sin esperar dos ciclos.
  static const Duration _recheck = Duration(seconds: 10);

  final Ref _ref;
  ProviderSubscription<TerminalMode>? _sub;
  Timer? _timer;
  MobilePrintAgent? _server;
  bool _busy = false;

  Future<void> _evaluate() async {
    if (_busy) return; // el próximo tic lo vuelve a intentar
    _busy = true;
    try {
      final controller = _ref.read(hubModeProvider.notifier);
      final serve = shouldServeHubServer(
        mode: _ref.read(hubModeProvider),
        role: controller.role,
        policy: controller.policy,
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      );
      if (serve) {
        await _ensureStarted();
      } else {
        await _ensureStopped();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    final agent = MobilePrintAgent();
    final url = await agent.start(port: kHubPortAlt);
    if (url != null) {
      _server = agent;
      debugPrint('[HubServer] Servidor Hub dedicado activo en $url');
    }
  }

  Future<void> _ensureStopped() async {
    final s = _server;
    _server = null;
    if (s != null) {
      await s.stop();
      debugPrint('[HubServer] Servidor Hub dedicado detenido');
    }
  }

  void dispose() {
    _sub?.close();
    _timer?.cancel();
    _timer = null;
    unawaited(_ensureStopped());
  }
}

final hubServerProvider = Provider<HubServerController>((ref) {
  final c = HubServerController(ref);
  ref.onDispose(c.dispose);
  return c;
});
