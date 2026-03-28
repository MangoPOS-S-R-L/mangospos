// Legacy multi-tenant stub.
// MangoPOS ahora opera centralizado bajo app.mangopos.do.
// Se conserva este archivo para evitar imports rotos mientras se termina
// la limpieza completa del código viejo.
import 'package:flutter/foundation.dart' show kIsWeb;

enum AppMode { appShell, tenant }

class TenantResolver {
  static String get currentHost {
    if (!kIsWeb) return 'localhost';
    return Uri.base.host;
  }

  // Compatibilidad: siempre trabajamos como app shell único.
  static AppMode get mode => AppMode.appShell;

  // Desactivado: ya no usamos subdominios de tenant.
  static String? get tenantSubdomain => null;

  static bool get isAppShell => true;
  static bool get isTenant => false;
}
