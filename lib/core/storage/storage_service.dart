import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Keys centralizadas para el almacenamiento
class StorageKeys {
  // Prefijos por módulo
  static const String cachePrefix = 'cache_';
  static const String metadataPrefix = 'metadata_';
  static const String queuePrefix = 'queue_';
  static const String hashPrefix = 'hash_';

  // Keys del sistema
  static const String cacheVersion = 'system_cache_version';
  static const String lastCleanup = 'system_last_cleanup';
  static const String totalCacheSize = 'system_total_cache_size';

  // Generar key para datos
  static String cacheKey(String module, String key) =>
      '$cachePrefix${module}_$key';

  // Generar key para metadata
  static String metadataKey(String module, String key) =>
      '$metadataPrefix${module}_$key';

  // Generar key para queue
  static String queueKey(String module) => '$queuePrefix$module';

  // Generar key para hash
  static String hashKey(String module) => '$hashPrefix$module';
}

/// Servicio de almacenamiento con SharedPreferences
class StorageService {
  static StorageService? _instance;
  static SharedPreferences? _prefs;

  StorageService._();

  static Future<StorageService> getInstance() async {
    if (_instance == null) {
      _instance = StorageService._();
      _prefs = await SharedPreferences.getInstance();
    }
    return _instance!;
  }

  // ==================== LECTURA ====================

  /// Leer datos crudos
  Future<String?> read(String key) async {
    try {
      return _prefs?.getString(key);
    } catch (e) {
      print('Error reading key $key: $e');
      return null;
    }
  }

  /// Leer JSON
  Future<Map<String, dynamic>?> readJson(String key) async {
    try {
      final data = await read(key);
      if (data == null) return null;
      return json.decode(data) as Map<String, dynamic>;
    } catch (e) {
      print('Error reading JSON from key $key: $e');
      return null;
    }
  }

  /// Leer lista
  Future<List<dynamic>?> readList(String key) async {
    try {
      final data = await read(key);
      if (data == null) return null;
      return json.decode(data) as List<dynamic>;
    } catch (e) {
      print('Error reading list from key $key: $e');
      return null;
    }
  }

  // ==================== ESCRITURA ====================

  /// Escribir datos crudos
  Future<bool> write(String key, String value) async {
    try {
      return await _prefs?.setString(key, value) ?? false;
    } catch (e) {
      print('Error writing key $key: $e');
      return false;
    }
  }

  /// Escribir JSON
  Future<bool> writeJson(String key, Map<String, dynamic> data) async {
    try {
      final encoded = json.encode(data);
      return await write(key, encoded);
    } catch (e) {
      print('Error writing JSON to key $key: $e');
      return false;
    }
  }

  /// Escribir lista
  Future<bool> writeList(String key, List<dynamic> data) async {
    try {
      final encoded = json.encode(data);
      return await write(key, encoded);
    } catch (e) {
      print('Error writing list to key $key: $e');
      return false;
    }
  }

  // ==================== ELIMINACIÓN ====================

  /// Eliminar key específica
  Future<bool> delete(String key) async {
    try {
      return await _prefs?.remove(key) ?? false;
    } catch (e) {
      print('Error deleting key $key: $e');
      return false;
    }
  }

  /// Eliminar múltiples keys
  Future<int> deleteMultiple(List<String> keys) async {
    int deleted = 0;
    for (final key in keys) {
      if (await delete(key)) deleted++;
    }
    return deleted;
  }

  /// Eliminar por prefijo
  Future<int> deleteByPrefix(String prefix) async {
    final keys = await getKeysByPrefix(prefix);
    return await deleteMultiple(keys);
  }

  /// Limpiar todo el caché
  Future<bool> clear() async {
    try {
      return await _prefs?.clear() ?? false;
    } catch (e) {
      print('Error clearing storage: $e');
      return false;
    }
  }

  // ==================== UTILIDADES ====================

  /// Verificar si existe una key
  Future<bool> exists(String key) async {
    return _prefs?.containsKey(key) ?? false;
  }

  /// Obtener todas las keys
  Future<List<String>> getAllKeys() async {
    return _prefs?.getKeys().toList() ?? [];
  }

  /// Obtener keys por prefijo
  Future<List<String>> getKeysByPrefix(String prefix) async {
    final allKeys = await getAllKeys();
    return allKeys.where((key) => key.startsWith(prefix)).toList();
  }

  /// Obtener tamaño de una key en bytes
  Future<int> getSizeInBytes(String key) async {
    final data = await read(key);
    if (data == null) return 0;
    return utf8.encode(data).length;
  }

  /// Obtener tamaño total de keys con prefijo
  Future<int> getTotalSizeByPrefix(String prefix) async {
    final keys = await getKeysByPrefix(prefix);
    int totalSize = 0;
    for (final key in keys) {
      totalSize += await getSizeInBytes(key);
    }
    return totalSize;
  }

  /// Obtener tamaño total del caché en MB
  Future<double> getTotalSizeInMB() async {
    final allKeys = await getAllKeys();
    int totalBytes = 0;
    for (final key in allKeys) {
      totalBytes += await getSizeInBytes(key);
    }
    return totalBytes / (1024 * 1024);
  }

  /// Obtener estadísticas del storage
  Future<Map<String, dynamic>> getStats() async {
    final allKeys = await getAllKeys();
    final totalSize = await getTotalSizeInMB();

    final cacheKeys = await getKeysByPrefix(StorageKeys.cachePrefix);
    final metadataKeys = await getKeysByPrefix(StorageKeys.metadataPrefix);
    final queueKeys = await getKeysByPrefix(StorageKeys.queuePrefix);

    return {
      'totalKeys': allKeys.length,
      'cacheKeys': cacheKeys.length,
      'metadataKeys': metadataKeys.length,
      'queueKeys': queueKeys.length,
      'totalSizeMB': totalSize,
    };
  }
}
