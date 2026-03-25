// lib/core/tenant/tenant_resolver.dart
import 'package:flutter/foundation.dart' show kIsWeb;

enum AppMode { appShell, tenant }

/// Detecta en qué subdominio corre la app Flutter en este momento.
///
/// - `app.mangopos.do` → [AppMode.appShell] (portal de login / registro)
/// - `*.mangopos.do`   → [AppMode.tenant]   (POS de un negocio específico)
class TenantResolver {
  static String get currentHost {
    if (!kIsWeb) return 'localhost';
    return Uri.base.host; // ej: "tropella.mangopos.do"
  }

  static AppMode get mode {
    final host = currentHost;
    if (host == 'app.mangopos.do' ||
        host == 'localhost' ||
        host.startsWith('127.0.0.1')) {
      return AppMode.appShell;
    }
    return AppMode.tenant;
  }

  /// Solo válido cuando [mode] == [AppMode.tenant].
  /// Devuelve la parte del subdominio antes del primer punto.
  /// Ej: "tropella.mangopos.do" → "tropella"
  static String? get tenantSubdomain {
    if (mode != AppMode.tenant) return null;
    return currentHost.split('.').first;
  }

  static bool get isAppShell => mode == AppMode.appShell;
  static bool get isTenant   => mode == AppMode.tenant;
}
