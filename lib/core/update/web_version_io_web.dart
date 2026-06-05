// Implementación web del checker de actualizaciones. Solo se compila cuando el
// target es web (`dart.library.js_interop` disponible). Usa `package:web` para
// resolver el base href y recargar el navegador, y `package:http` para leer el
// `version.json` que Flutter genera en cada build web.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Lee `version.json` (raíz del build web) y devuelve la huella
/// "version+build_number" derivada de `pubspec.yaml`, o `null` si falla.
///
/// Resuelve la URL contra el base href del documento (no contra la ruta
/// actual) para que funcione aunque la app esté hosteada en un subpath, y
/// agrega un query con timestamp para esquivar el cache del navegador / service
/// worker y ver siempre el deploy vivo.
Future<String?> fetchDeployedVersion() async {
  try {
    final base = web.document.baseURI;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final uri = Uri.parse('${base}version.json').replace(
      queryParameters: {'t': '$stamp'},
    );
    final res = await http
        .get(uri, headers: const {'cache-control': 'no-cache'})
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    final version = map['version']?.toString() ?? '';
    final build = map['build_number']?.toString() ?? '';
    if (version.isEmpty && build.isEmpty) return null;
    return '$version+$build';
  } catch (_) {
    return null;
  }
}

/// Hard reload del navegador para descargar y aplicar el build nuevo.
void reloadWebApp() => web.window.location.reload();
