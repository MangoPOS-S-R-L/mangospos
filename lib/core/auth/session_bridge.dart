// lib/core/auth/session_bridge.dart
//
// Responsable de:
//  1. Al hacer login en app.mangopos.do -> redirigir al tenant con tokens en el fragmento.
//  2. Al arrancar en *.mangopos.do      -> consumir esos tokens, restaurar sesion y limpiar URL.

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mangopos/core/utils/web_utils/web_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../tenant/tenant_resolver.dart';
import '../utils/logger.dart';

class SessionBridge {
  /// Redirige al usuario al subdominio del tenant despues de un login exitoso.
  /// Pasa los tokens de Supabase como parametros del fragmento de URL.
  ///
  /// Ejemplo:
  ///   `https://tropella.mangopos.do/#/auth?at=<accessToken>&rt=<refreshToken>`
  static void redirectToTenant(String domain) {
    if (!kIsWeb) return;

    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      AppLogger.w(
        '[SessionBridge] No hay sesion activa para transferir al tenant.',
      );
      return;
    }

    final at = session.accessToken;
    final rt = session.refreshToken;

    if (at.isEmpty || rt == null || rt.isEmpty) {
      AppLogger.w('[SessionBridge] Access token o refresh token vacios.');
      return;
    }

    final cleanDomain = domain
        .replaceAll(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    final targetUrl =
        'https://$cleanDomain/#/auth?at=${Uri.encodeComponent(at)}&rt=${Uri.encodeComponent(rt)}';

    AppLogger.i(
      '[SessionBridge] -> Redirigiendo al tenant: https://$cleanDomain/',
    );
    WebUtils.assign(targetUrl);
  }

  /// Llamado en [main()] antes de montar la app.
  ///
  /// Si la URL contiene tokens en el fragmento (#/auth?at=...&rt=...),
  /// intenta reconstruir la sesion sin forzar un refresh inmediato.
  static Future<bool> handleIncoming() async {
    if (!kIsWeb) return false;
    if (!TenantResolver.isTenant) return false;

    try {
      final uri = Uri.parse(WebUtils.href);
      final fragment = uri.fragment;

      if (!fragment.contains('at=')) return false;

      final queryPart = fragment.contains('?')
          ? fragment.split('?').last
          : fragment;
      final params = Uri.splitQueryString(queryPart);
      final at = params['at'];
      final rt = params['rt'];

      if (at == null || rt == null || at.isEmpty || rt.isEmpty) {
        AppLogger.w('[SessionBridge] Fragmento con at/rt pero valores vacios.');
        return false;
      }

      AppLogger.i(
        '[SessionBridge] Tokens encontrados en URL. Restaurando sesion...',
      );
      return restoreFromTokens(
        accessToken: at,
        refreshToken: rt,
        cleanUrlOnSuccess: true,
      );
    } catch (e) {
      AppLogger.e('[SessionBridge] Error restaurando sesion desde URL: $e');
      return false;
    }
  }

  /// Reconstruye la sesion local usando el access token para obtener el usuario
  /// y evitando un refresh inmediato contra `/token`.
  static Future<bool> restoreFromTokens({
    required String accessToken,
    required String refreshToken,
    bool cleanUrlOnSuccess = false,
  }) async {
    final auth = Supabase.instance.client.auth;

    try {
      final userResponse = await auth.getUser(accessToken);
      final user = userResponse.user;
      if (user == null) {
        AppLogger.w(
          '[SessionBridge] No se pudo obtener el usuario desde access token.',
        );
        return false;
      }

      final sessionJson = jsonEncode({
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'token_type': 'bearer',
        'expires_in': _expiresInFromJwt(accessToken),
        'user': user.toJson(),
      });

      final response = await auth.recoverSession(sessionJson);
      final session = response.session ?? auth.currentSession;
      if (session == null) {
        AppLogger.w(
          '[SessionBridge] recoverSession no devolvio sesion activa.',
        );
        return false;
      }

      if (cleanUrlOnSuccess) {
        _cleanUrl();
      }

      AppLogger.i('[SessionBridge] Sesion restaurada: uid=${session.user.id}');
      return true;
    } catch (e) {
      AppLogger.e('[SessionBridge] Error restaurando sesion con tokens: $e');
      return false;
    }
  }

  static int _expiresInFromJwt(String accessToken) {
    try {
      final parts = accessToken.split('.');
      if (parts.length < 2) return 3600;

      final payload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! num) return 3600;

      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final expiresIn = exp.toInt() - nowSeconds;
      return expiresIn > 0 ? expiresIn : 0;
    } catch (_) {
      return 3600;
    }
  }

  static void _cleanUrl() {
    try {
      final currentUri = Uri.parse(WebUtils.href);
      final port = currentUri.port;
      final portStr = (port != 0 && port != 80 && port != 443) ? ':$port' : '';
      final cleanPath = '${currentUri.scheme}://${currentUri.host}$portStr/#/';
      WebUtils.replaceState(null, '', cleanPath);
      AppLogger.d('[SessionBridge] URL limpiada -> $cleanPath');
    } catch (e) {
      AppLogger.w('[SessionBridge] No se pudo limpiar la URL: $e');
    }
  }
}
