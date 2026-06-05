// Stub para plataformas NO-web (desktop/móvil): no hay `version.json` que leer
// ni navegador que recargar. El checker de actualizaciones usa este archivo por
// defecto y lo reemplaza por `web_version_io_web.dart` cuando se compila a web
// (ver el `if (dart.library.js_interop)` en web_version_checker.dart).

Future<String?> fetchDeployedVersion() async => null;

void reloadWebApp() {}
