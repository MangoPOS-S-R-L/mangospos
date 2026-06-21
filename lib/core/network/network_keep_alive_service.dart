import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Mantiene viva la conectividad de red en plataformas que apagan el radio
/// o suspenden el sistema cuando el dispositivo queda "ocioso".
///
/// Equivalencia por plataforma del WifiLock de Android:
///   - Android : NO se toca aquí. El WifiLock nativo (LOW_LATENCY) ya
///               mantiene el radio. Este servicio lo deja pasar.
///   - iOS     : iOS no expone el radio WiFi. Se mantiene la pantalla viva
///               (isIdleTimerDisabled vía wakelock) para que el WiFi no baje
///               a ahorro, y se dispara [onResume] al volver a foreground
///               para revalidar el LAN Agent y reabrir sockets.
///   - Windows : Evita que el sistema entre en suspensión
///               (SetThreadExecutionState por debajo de wakelock_plus).
///
/// Uso:
///   final keepAlive = NetworkKeepAliveService();
///   await keepAlive.enable(onResume: () => printAgent.revalidate());
///   ...
///   await keepAlive.disable();
class NetworkKeepAliveService with WidgetsBindingObserver {
  bool _enabled = false;
  bool _observerAttached = false;

  /// Callback que se invoca cuando la app vuelve a foreground.
  /// Pensado para revalidar el LAN Print Agent y reabrir conexiones
  /// (cascada de discovery, sockets TCP:9100, Supabase Realtime).
  VoidCallback? _onResume;

  bool get isEnabled => _enabled;

  /// Activa el keep-alive. Idempotente.
  Future<void> enable({VoidCallback? onResume}) async {
    _onResume = onResume;

    if (_enabled) {
      await _apply();
      return;
    }

    _enabled = true;

    if (!_observerAttached) {
      WidgetsBinding.instance.addObserver(this);
      _observerAttached = true;
    }

    await _apply();
  }

  /// Libera el keep-alive. Idempotente.
  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;

    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAttached = false;
    }

    // Solo desactivamos el wakelock en las plataformas donde lo activamos.
    // En Android nunca lo encendimos, así que no pisamos nada.
    if (_usesWakelock) {
      try {
        await WakelockPlus.disable();
      } catch (_) {
        // No bloqueamos el shutdown por un fallo del plugin.
      }
    }
  }

  /// Plataformas donde wakelock_plus es la estrategia correcta.
  bool get _usesWakelock => Platform.isIOS || Platform.isWindows;

  Future<void> _apply() async {
    if (!_enabled) return;
    if (!_usesWakelock) return; // Android u otras: no-op.

    try {
      final already = await WakelockPlus.enabled;
      if (!already) {
        await WakelockPlus.enable();
      }
    } catch (_) {
      // Si el plugin falla, no tumbamos la app; la red sigue, solo
      // perdemos la garantía de no-sleep.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled) return;

    switch (state) {
      case AppLifecycleState.resumed:
        // iOS puede haber soltado el wakelock al ir a background:
        // lo re-aplicamos al volver.
        _apply();

        // En iOS los sockets se suspenden en background. Al volver,
        // revalidamos el agente de impresión y reabrimos conexiones.
        // En Windows normalmente no hace falta, pero el callback es
        // idempotente del lado del consumidor, así que lo dejamos pasar
        // solo en iOS para no forzar reconexiones innecesarias.
        if (Platform.isIOS) {
          _onResume?.call();
        }
        break;

      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // No liberamos el wakelock aquí a propósito: en iOS la app se
        // suspende sola y en Windows queremos seguir vivos si la dejan
        // minimizada. La liberación real es responsabilidad de disable().
        break;
    }
  }
}
