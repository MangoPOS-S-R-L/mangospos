// Stub de conexión drift para web.
//
// MangoPOS no usa drift en web — la cola offline cae a SharedPreferences
// vía `OfflinePosService` (que tiene guard `kIsWeb`). Si por algún
// motivo se intenta abrir la DB en web, este stub tira UnsupportedError
// inmediato para que sea obvio que algo en el flujo no respetó el guard.
//
// Esto NO importa `dart:ffi` (no existe en web), por lo que la app
// compila para Chrome/Edge sin problemas.

import 'package:drift/drift.dart';

LazyDatabase openConnection() {
  return LazyDatabase(() async {
    throw UnsupportedError(
      'Drift no está habilitado en web para MangoPOS. '
      'La cola offline usa SharedPreferences en esta plataforma. '
      'Si ves este error, falta un guard `kIsWeb` en el caller.',
    );
  });
}
