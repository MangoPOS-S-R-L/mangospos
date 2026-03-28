// Legacy multi-tenant bridge stub.
// MangoPOS ya no transfiere sesión entre subdominios.
// Este archivo queda neutralizado por compatibilidad temporal.

class SessionBridge {
  static void redirectToTenant(String domain) {
    // No-op: el sistema ya no usa subdominios por negocio.
  }

  static Future<bool> handleIncoming() async {
    // No-op: ya no consumimos tokens cross-domain.
    return false;
  }

  static Future<bool> restoreFromTokens({
    required String accessToken,
    required String refreshToken,
    bool cleanUrlOnSuccess = false,
  }) async {
    // No-op: el flujo cross-domain quedó desactivado.
    return false;
  }
}
