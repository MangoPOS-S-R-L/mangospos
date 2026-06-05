import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web_version_io_stub.dart'
    if (dart.library.js_interop) 'web_version_io_web.dart';

/// `true` cuando hay un build **web** más nuevo publicado que el que está
/// corriendo en memoria.
///
/// Compara el `version.json` que Flutter genera en la raíz del build (campos
/// `version` + `build_number`, derivados de `pubspec.yaml`) contra el que se
/// leyó al iniciar. Cuando difieren, hubo un deploy nuevo y el usuario sigue
/// con el bundle viejo cargado → mostramos el banner para que recargue.
///
/// SOLO web: en desktop/móvil el helper es un stub que devuelve `null` y el
/// estado queda en `false` permanentemente (esas plataformas se actualizan por
/// `auto_updater` / tiendas, no recargando el navegador).
final webUpdateAvailableProvider = NotifierProvider<WebUpdateChecker, bool>(
  WebUpdateChecker.new,
);

class WebUpdateChecker extends Notifier<bool> {
  Timer? _timer;
  String? _baseline;

  /// Cada cuánto se relee `version.json`. Es 1 GET de ~100 bytes, así que 15
  /// min avisa razonablemente rápido sin pesar en la red.
  static const Duration _pollInterval = Duration(minutes: 15);

  @override
  bool build() {
    if (!kIsWeb) return false;
    ref.onDispose(() => _timer?.cancel());
    unawaited(_start());
    return false;
  }

  Future<void> _start() async {
    if (_timer != null) return; // ya arrancado
    // Baseline = versión del build que está corriendo ahora. Si falla (offline
    // al abrir) queda null y se fija con la primera lectura buena en _check.
    _baseline = await fetchDeployedVersion();
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(_check()));
  }

  Future<void> _check() async {
    final current = await fetchDeployedVersion();
    if (current == null) return; // sin red / fetch falló: se reintenta luego
    _baseline ??= current; // no se pudo leer al inicio → fijar sin falso positivo
    if (current != _baseline && !state) {
      state = true;
      _timer?.cancel(); // ya avisamos; no hace falta seguir sondeando
      _timer = null;
    }
  }

  /// Recarga el navegador para aplicar el build nuevo (no-op fuera de web).
  void reloadApp() => reloadWebApp();
}
