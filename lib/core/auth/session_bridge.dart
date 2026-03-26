// lib/core/auth/session_bridge.dart
//
// Responsable de:
//  1. Al hacer login en app.mangopos.do → redirigir al tenant con tokens en el fragmento.
//  2. Al arrancar en *.mangopos.do      → consumir esos tokens, restaurar sesión y limpiar URL.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/utils/web_utils/web_utils.dart';

import '../tenant/tenant_resolver.dart';
import '../utils/logger.dart';

class SessionBridge {
  // ────────────────────────────────────────────────────────────
  // LADO PORTAL (app.mangopos.do)
  // ────────────────────────────────────────────────────────────

  /// Redirige al usuario al subdominio del tenant después de un login exitoso.
  /// Pasa los tokens de Supabase como parámetros del fragmento de URL.
  ///
  /// Ejemplo de URL resultante:
  ///   https://tropella.mangopos.do/#/auth?at=<accessToken>&rt=<refreshToken>
  static void redirectToTenant(String domain) {
    if (!kIsWeb) return;

    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      AppLogger.w('[SessionBridge] No hay sesión activa para transferir al tenant.');
      return;
    }

    final at = session.accessToken;
    final rt = session.refreshToken;

    if (at.isEmpty || rt == null || rt.isEmpty) {
      AppLogger.w('[SessionBridge] Access token o refresh token vacíos.');
      return;
    }

    // Garantizar que el dominio tenga scheme
    final cleanDomain = domain.replaceAll(RegExp(r'^https?://'), '').split('/').first;
    final targetUrl = 'https://$cleanDomain/#/auth?at=${Uri.encodeComponent(at)}&rt=${Uri.encodeComponent(rt)}';

    AppLogger.i('[SessionBridge] → Redirigiendo al tenant: https://$cleanDomain/');
    WebUtils.assign(targetUrl);
  }

  // ────────────────────────────────────────────────────────────
  // LADO TENANT (*.mangopos.do)
  // ────────────────────────────────────────────────────────────

  /// Llamado en [main()] ANTES de montar la app.
  /// Si la URL contiene tokens en el fragmento (#/auth?at=...&rt=...),
  /// los consume para restaurar la sesión de Supabase y limpia la URL.
  ///
  /// Retorna `true` si se restauró una sesión satisfactoriamente.
  static Future<bool> handleIncoming() async {
    if (!kIsWeb) return false;
    if (!TenantResolver.isTenant) return false;

    try {
      final href = WebUtils.href;
      final uri = Uri.parse(href);
      final fragment = uri.fragment; // "/auth?at=...&rt=..."

      if (!fragment.contains('at=')) return false;

      // Extraer los query params del fragmento
      final String queryPart;
      if (fragment.contains('?')) {
        queryPart = fragment.split('?').last;
      } else {
        queryPart = fragment;
      }

      final params = Uri.splitQueryString(queryPart);
      final at = params['at'];
      final rt = params['rt'];

      if (at == null || rt == null || at.isEmpty || rt.isEmpty) {
        AppLogger.w('[SessionBridge] Fragmento con at/rt pero valores vacíos.');
        return false;
      }

      AppLogger.i('[SessionBridge] Tokens encontrados en URL. Restaurando sesión...');

      // Limpiar los tokens de la URL ANTES de llamar a Supabase
      // para que no queden expuestos en el historial del browser.
      _cleanUrl();

      // Restaurar la sesión usando el refresh token (más robusto que setSession directo)
      final response = await Supabase.instance.client.auth.setSession(rt);

      if (response.session != null) {
        AppLogger.i('[SessionBridge] ✅ Sesión restaurada: uid=${response.session!.user.id}');
        return true;
      } else {
        AppLogger.w('[SessionBridge] setSession no devolvió sesión activa.');
        return false;
      }
    } catch (e) {
      AppLogger.e('[SessionBridge] Error restaurando sesión desde URL: $e');
      return false;
    }
  }

  static void _cleanUrl() {
    try {
      final currentUri = Uri.parse(WebUtils.href);
      final port = currentUri.port;
      final portStr = (port != 0 && port != 80 && port != 443) ? ':$port' : '';
      final cleanPath = '${currentUri.scheme}://${currentUri.host}$portStr/#/';
      WebUtils.replaceState(null, '', cleanPath);
      AppLogger.d('[SessionBridge] URL limpiada → $cleanPath');
    } catch (e) {
      AppLogger.w('[SessionBridge] No se pudo limpiar la URL: $e');
    }
  }
}
