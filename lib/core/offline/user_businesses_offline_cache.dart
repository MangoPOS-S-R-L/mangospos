import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Cache local de los ACCESOS del usuario (las filas de `user_businesses` con
/// el negocio embebido) para que el arranque no dependa de la red.
///
/// Por qué existe: `SelectBusinessView` consultaba `user_businesses` a red con
/// timeout de 10s y sin ningún fallback. Sin internet mostraba "No pudimos
/// cargar tus accesos" y el botón Reintentar repetía LA MISMA consulta a red →
/// callejón sin salida. Hasta un cajero de un solo negocio quedaba varado en
/// esa pantalla, con la app instalada, la sesión válida y todo el resto del
/// modo offline funcionando detrás.
///
/// Se guarda por `userId` (no por negocio): la pregunta que responde es "¿a
/// qué negocios entra ESTE usuario?", y en un terminal compartido cada quien
/// tiene su propia respuesta.
///
/// **En claro, a propósito.** El roster (que sí lleva `pin_hash` y PII) se
/// cifra con `SecureBlobCipher`; esto no. Aquí solo hay ids de negocio,
/// nombres de sucursal y un string de rol — nada que no esté ya visible en la
/// pantalla. Y el cifrado tiene un modo de falla conocido en el que la clave
/// del keychain se pierde y el blob queda ilegible para siempre; cifrar
/// justamente el cache que existe para ser el último recurso cuando nada más
/// funciona reintroduciría el callejón sin salida que vino a cerrar.
class UserBusinessesOfflineCache {
  UserBusinessesOfflineCache._();

  static final UserBusinessesOfflineCache _instance =
      UserBusinessesOfflineCache._();
  factory UserBusinessesOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _key(String userId) => 'offline_user_businesses_$userId';

  /// Persiste las filas tal como las devolvió PostgREST (con el `businesses`
  /// anidado), para que el camino offline pueda reusar sin traducción la misma
  /// lógica de auto-selección que corre online.
  Future<void> save({
    required String userId,
    required List<Map<String, dynamic>> rows,
  }) async {
    if (userId.isEmpty) return;
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'rows': rows,
      });
      await storage.write(_key(userId), payload);
    } catch (e) {
      debugPrint('UserBusinessesOfflineCache.save error: $e');
    }
  }

  /// Accesos cacheados del usuario, o `null` si nunca se cachearon.
  Future<List<Map<String, dynamic>>?> load(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final storage = await _storage;
      final raw = await storage.read(_key(userId));
      if (raw == null || raw.isEmpty) return null;
      final payload = jsonDecode(raw);
      if (payload is! Map) return null;
      final rows = payload['rows'];
      if (rows is! List) return null;
      final parsed = rows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .where((row) => (row['business_id']?.toString() ?? '').isNotEmpty)
          .toList(growable: false);
      return parsed.isEmpty ? null : parsed;
    } catch (e) {
      debugPrint('UserBusinessesOfflineCache.load error: $e');
      return null;
    }
  }

  /// Cuándo se guardó el cache. Útil para diagnóstico; el arranque no lo
  /// bloquea por antigüedad — un acceso viejo es infinitamente mejor que
  /// quedarse varado en la pantalla de selección.
  Future<DateTime?> savedAt(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final storage = await _storage;
      final raw = await storage.read(_key(userId));
      if (raw == null || raw.isEmpty) return null;
      final payload = jsonDecode(raw);
      if (payload is! Map) return null;
      return DateTime.tryParse(payload['saved_at']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String userId) async {
    if (userId.isEmpty) return;
    try {
      final storage = await _storage;
      await storage.delete(_key(userId));
    } catch (e) {
      debugPrint('UserBusinessesOfflineCache.clear error: $e');
    }
  }
}
