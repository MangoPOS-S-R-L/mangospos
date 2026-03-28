import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/utils/web_utils/web_utils.dart';

/// Implementación personalizada de LocalStorage para Supabase
/// que guarda la sesión en una Cookie tipo wildcard (.mangopos.do)
/// en lugar del localStorage del navegador, permitiendo Single Sign-On
/// nativo para web/app shell centralizado.
class SharedCookieLocalStorage extends LocalStorage {
  const SharedCookieLocalStorage();

  static const String cookieName = 'sb-mangopos-auth';
  static final LocalStorage _mobileFallback = SharedPreferencesLocalStorage(
    persistSessionKey: 'supabase.auth.token',
  );

  @override
  Future<void> initialize() async {
    if (!kIsWeb) {
      await _mobileFallback.initialize();
    }
  }

  @override
  Future<String?> accessToken() async {
    if (!kIsWeb) return _mobileFallback.accessToken();

    final cookieStr = WebUtils.cookie;
    final cookies = cookieStr.split(';');
    for (final c in cookies) {
      final pair = c.trim().split('=');
      if (pair.length == 2 && pair[0] == cookieName) {
        return Uri.decodeComponent(pair[1]);
      }
    }
    return null;
  }

  @override
  Future<bool> hasAccessToken() async {
    final token = await accessToken();
    return token != null && token.isNotEmpty;
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    if (!kIsWeb) {
      return _mobileFallback.persistSession(persistSessionString);
    }

    final encoded = Uri.encodeComponent(persistSessionString);
    final domain = _getCookieDomain();

    // Cookie expira en 7 días (604800 segundos)
    WebUtils.cookie =
        '$cookieName=$encoded; Max-Age=604800; Domain=$domain; Path=/; Secure; SameSite=Lax';
  }

  @override
  Future<void> removePersistedSession() async {
    if (!kIsWeb) {
      return _mobileFallback.removePersistedSession();
    }

    final domain = _getCookieDomain();
    WebUtils.cookie =
        '$cookieName=; Max-Age=0; Domain=$domain; Path=/; Secure; SameSite=Lax';
  }

  String _getCookieDomain() {
    try {
      final host = WebUtils.hostname.toLowerCase();
      if (host == 'localhost' || host == '127.0.0.1') return host;

      // Si estamos en cualquier subdominio de mangopos.do,
      // establecer la cookie de forma global para todos los subdominios.
      if (host.endsWith('mangopos.do')) {
        return '.mangopos.do';
      }
      return host;
    } catch (_) {
      return '';
    }
  }
}
