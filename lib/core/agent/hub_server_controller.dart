import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/hub/hub_config.dart' show TerminalMode, kHubPortAlt;
import '../offline/hub/hub_mode_controller.dart' show hubModeProvider;
import 'mobile_print_agent.dart';

/// Paridad Windows del Hub (H4). En Mac/tablet/móvil el agente Dart en-proceso
/// de `main.dart` ya sirve `/hub/*` en el puerto 4000. En Windows/Linux ese
/// puerto lo ocupa el agente Node de impresión, así que cuando ESTE equipo es
/// el Hub (rol=hub → modo [TerminalMode.hubHost]) levantamos un servidor Dart
/// DEDICADO en [kHubPortAlt] solo para servir el Hub. Se apaga si el equipo
/// deja de ser el Hub.
///
/// Escucha [hubModeProvider] y actúa solo en Windows/Linux; en web/Mac/tablet/
/// móvil es inerte (allí no hace falta). Se mantiene vivo desde el shell.
class HubServerController {
  HubServerController(this._ref) {
    _sub = _ref.listen<TerminalMode>(
      hubModeProvider,
      (_, next) => unawaited(_apply(next)),
      fireImmediately: true,
    );
  }

  final Ref _ref;
  ProviderSubscription<TerminalMode>? _sub;
  MobilePrintAgent? _server;
  bool _busy = false;

  Future<void> _apply(TerminalMode mode) async {
    if (_busy) return;
    _busy = true;
    try {
      if (mode == TerminalMode.hubHost) {
        await _ensureStarted();
      } else {
        await _ensureStopped();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _ensureStarted() async {
    if (_server != null || kIsWeb) return;
    // Solo Windows/Linux necesitan el servidor dedicado; en Mac/tablet/móvil el
    // agente de impresión ya sirve /hub/* en 4000. (defaultTargetPlatform es
    // web-safe; el guard kIsWeb ya cortó antes en web.)
    final p = defaultTargetPlatform;
    if (p != TargetPlatform.windows && p != TargetPlatform.linux) return;
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
    unawaited(_ensureStopped());
  }
}

final hubServerProvider = Provider<HubServerController>((ref) {
  final c = HubServerController(ref);
  ref.onDispose(c.dispose);
  return c;
});
