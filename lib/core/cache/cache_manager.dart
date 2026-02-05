import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../storage/storage_service.dart';
import 'cache_config.dart';
import 'models/cache_entry.dart';
import 'models/sync_status.dart';
import '../network/connectivity_service.dart';

/// Gestor principal de caché - Versión DÍA 1 (Básica pero funcional)
///
/// Características implementadas:
/// - ✅ Singleton pattern
/// - ✅ get() con cache-first/network-first
/// - ✅ set() con persistencia local
/// - ✅ Gestión de metadata y TTL
/// - ✅ Stream de estado para UI
/// - ✅ Inicialización con prioridades
///
/// Pendiente para días siguientes:
/// - ⏳ Queue de operaciones offline (DÍA 3)
/// - ⏳ Sincronización automática (DÍA 4)
/// - ⏳ Compresión de datos (DÍA 5)
class CacheManager {
  static CacheManager? _instance;

  late StorageService _storage;
  late ConnectivityService _connectivity;

  final StreamController<CacheState> _stateController =
      StreamController<CacheState>.broadcast();

  CacheState _currentState = CacheState(status: CacheStatus.initializing);

  bool _initialized = false;

  // Constructor privado
  CacheManager._();

  /// Singleton factory
  factory CacheManager() {
    _instance ??= CacheManager._();
    return _instance!;
  }

  /// Stream de estado para UI reactiva
  Stream<CacheState> get stateStream => _stateController.stream;

  /// Estado actual
  CacheState get currentState => _currentState;

  // ==================== INICIALIZACIÓN ====================

  /// Inicializar el sistema de caché
  ///
  /// [priorityOrder] - Orden de carga de módulos por prioridad
  /// [onProgress] - Callback de progreso (moduleName, percentage)
  static Future<void> initialize({
    List<CachePriority>? priorityOrder,
    Function(String module, int progress)? onProgress,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final manager = CacheManager();

    if (manager._initialized) {
      debugPrint('⚠️ CacheManager already initialized');
      return;
    }

    debugPrint('🚀 Initializing CacheManager...');
    manager._updateState(CacheStatus.initializing);

    try {
      // 1. Inicializar servicios base
      manager._storage = await StorageService.getInstance();
      manager._connectivity = ConnectivityService();
      await manager._connectivity.initialize();

      // 2. Verificar versión del caché
      await manager._checkCacheVersion();

      // 3. Cargar módulos por prioridad
      final loadOrder =
          priorityOrder ?? [CachePriority.critical, CachePriority.high];

      for (final priority in loadOrder) {
        final modules = CacheConfig.getModulesByPriority(priority);

        for (int i = 0; i < modules.length; i++) {
          final module = modules[i];
          final progress = ((i + 1) / modules.length * 100).round();

          debugPrint('Loading $module ($priority) - $progress%');
          onProgress?.call(module, progress);

          // Precarga: Solo verificar que existan las keys
          await manager._preloadModule(module);
        }
      }

      manager._initialized = true;
      manager._updateState(CacheStatus.cached);

      debugPrint('✅ CacheManager initialized successfully');
    } catch (e) {
      debugPrint('❌ Error initializing CacheManager: $e');
      manager._updateState(CacheStatus.error, errorMessage: e.toString());
      rethrow;
    }
  }

  /// Verificar versión del caché (migración futura)
  Future<void> _checkCacheVersion() async {
    final storedVersion = await _storage.read('system_cache_version');
    final currentVersion = CacheConfig.cacheVersion.toString();

    if (storedVersion == null) {
      // Primera vez, guardar versión actual
      await _storage.write('system_cache_version', currentVersion);
      debugPrint('Cache version set to $currentVersion');
    } else if (storedVersion != currentVersion) {
      // Migración futura
      debugPrint('Cache version mismatch. Migration needed.');
      // TODO DÍA 5: Implementar migración
    }
  }

  /// Precarga de un módulo
  Future<void> _preloadModule(String module) async {
    final config = CacheConfig.getModuleConfig(module);
    if (config == null || !config.enabled) return;

    // Por ahora solo verificar que las keys existan
    final cacheKey = 'cache_${module}_main';
    final exists = await _storage.exists(cacheKey);

    if (exists) {
      debugPrint('  ✓ $module cache found');
    } else {
      debugPrint('  ○ $module cache empty');
    }
  }

  // ==================== OPERACIONES DE LECTURA ====================

  /// Obtener datos del caché con fallback a API
  ///
  /// [key] - Identificador único del dato
  /// [fromJson] - Deserialización de JSON a objeto T
  /// [fetchFromApi] - Función para obtener datos frescos de la API
  /// [strategy] - Estrategia de caché (cacheFirst, networkFirst, etc.)
  /// [useStaleCacheOnError] - Usar caché expirado si la API falla
  /// [syncInBackground] - Actualizar caché en background si es stale
  /// [ttl] - Time to live personalizado
  Future<T?> get<T>({
    required String key,
    required T Function(dynamic) fromJson,
    required Future<T> Function() fetchFromApi,
    CacheStrategy strategy = CacheStrategy.cacheFirst,
    bool useStaleCacheOnError = true,
    bool syncInBackground = false,
    Duration? ttl,
  }) async {
    _updateState(CacheStatus.loading);

    try {
      switch (strategy) {
        case CacheStrategy.cacheFirst:
          return await _getCacheFirst(
            key: key,
            fromJson: fromJson,
            fetchFromApi: fetchFromApi,
            useStaleCacheOnError: useStaleCacheOnError,
            syncInBackground: syncInBackground,
            ttl: ttl,
          );

        case CacheStrategy.networkFirst:
          return await _getNetworkFirst(
            key: key,
            fromJson: fromJson,
            fetchFromApi: fetchFromApi,
            useStaleCacheOnError: useStaleCacheOnError,
            ttl: ttl,
          );

        case CacheStrategy.cacheOnly:
          return await _getCacheOnly(key: key, fromJson: fromJson);

        case CacheStrategy.networkOnly:
          return await _getNetworkOnly(
            key: key,
            fromJson: fromJson,
            fetchFromApi: fetchFromApi,
            ttl: ttl,
          );
      }
    } catch (e) {
      debugPrint('Error in get($key): $e');
      _updateState(CacheStatus.error, errorMessage: e.toString());
      return null;
    }
  }

  /// Estrategia: Cache primero
  Future<T?> _getCacheFirst<T>({
    required String key,
    required T Function(dynamic) fromJson,
    required Future<T> Function() fetchFromApi,
    required bool useStaleCacheOnError,
    required bool syncInBackground,
    Duration? ttl,
  }) async {
    // 1. Intentar obtener del caché
    final cached = await _getCacheOnly(key: key, fromJson: fromJson);

    if (cached != null) {
      final metadata = await _getMetadata(key);

      // Cache válido y no expirado
      if (metadata != null && !metadata.isExpired) {
        _updateState(CacheStatus.cached);

        // Sincronizar en background si está stale
        if (syncInBackground && metadata.isStale) {
          _syncInBackground(key, fetchFromApi, fromJson, ttl);
        }

        return cached;
      }

      // Cache expirado pero disponible
      if (useStaleCacheOnError) {
        debugPrint('Cache expired for $key, trying API with fallback...');

        try {
          final fresh = await _getNetworkOnly(
            key: key,
            fromJson: fromJson,
            fetchFromApi: fetchFromApi,
            ttl: ttl,
          );
          return fresh;
        } catch (e) {
          debugPrint('API failed, using stale cache for $key');
          _updateState(CacheStatus.stale);
          return cached;
        }
      }
    }

    // 2. No hay caché, obtener de la API
    if (_connectivity.isConnected) {
      return await _getNetworkOnly(
        key: key,
        fromJson: fromJson,
        fetchFromApi: fetchFromApi,
        ttl: ttl,
      );
    } else {
      _updateState(CacheStatus.offline);
      return null;
    }
  }

  /// Estrategia: Network primero
  Future<T?> _getNetworkFirst<T>({
    required String key,
    required T Function(dynamic) fromJson,
    required Future<T> Function() fetchFromApi,
    required bool useStaleCacheOnError,
    Duration? ttl,
  }) async {
    if (!_connectivity.isConnected) {
      debugPrint('Offline, using cache for $key');
      return await _getCacheOnly(key: key, fromJson: fromJson);
    }

    try {
      return await _getNetworkOnly(
        key: key,
        fromJson: fromJson,
        fetchFromApi: fetchFromApi,
        ttl: ttl,
      );
    } catch (e) {
      if (useStaleCacheOnError) {
        debugPrint('Network failed, falling back to cache for $key');
        return await _getCacheOnly(key: key, fromJson: fromJson);
      }
      rethrow;
    }
  }

  /// Estrategia: Solo caché
  Future<T?> _getCacheOnly<T>({
    required String key,
    required T Function(dynamic) fromJson,
  }) async {
    final data = await _storage.read(key);
    if (data == null) return null;

    try {
      final decoded = json.decode(data);
      return fromJson(decoded);
    } catch (e) {
      debugPrint('Error deserializing cache for $key: $e');
      return null;
    }
  }

  /// Estrategia: Solo network
  Future<T?> _getNetworkOnly<T>({
    required String key,
    required T Function(dynamic) fromJson,
    required Future<T> Function() fetchFromApi,
    Duration? ttl,
  }) async {
    _updateState(CacheStatus.syncing);

    final data = await fetchFromApi();

    // Guardar en caché
    await _saveToCache(key, data, ttl: ttl);

    _updateState(CacheStatus.synced);
    return data;
  }

  /// Sincronizar en background sin bloquear
  void _syncInBackground<T>(
    String key,
    Future<T> Function() fetchFromApi,
    T Function(dynamic) fromJson,
    Duration? ttl,
  ) {
    Future.microtask(() async {
      try {
        debugPrint('Background sync for $key...');
        await _getNetworkOnly(
          key: key,
          fromJson: fromJson,
          fetchFromApi: fetchFromApi,
          ttl: ttl,
        );
        debugPrint('Background sync completed for $key');
      } catch (e) {
        debugPrint('Background sync failed for $key: $e');
      }
    });
  }

  // ==================== OPERACIONES DE ESCRITURA ====================

  /// Guardar datos en caché con soporte de sincronización
  ///
  /// [key] - Identificador único del dato
  /// [data] - Datos a guardar
  /// [syncToServer] - Función opcional para sincronizar con servidor
  /// [updateLocalCache] - Actualizar caché local inmediatamente
  /// [ttl] - Time to live personalizado
  Future<bool> set<T>({
    required String key,
    required T data,
    Future<void> Function()? syncToServer,
    bool updateLocalCache = true,
    Duration? ttl,
  }) async {
    try {
      // 1. Guardar en caché local
      if (updateLocalCache) {
        await _saveToCache(key, data, ttl: ttl);
      }

      // 2. Sincronizar con servidor si hay función y conexión
      if (syncToServer != null && _connectivity.isConnected) {
        _updateState(CacheStatus.syncing);

        try {
          await syncToServer();
          _updateState(CacheStatus.synced);
        } catch (e) {
          debugPrint('Sync to server failed for $key: $e');
          // TODO DÍA 3: Agregar a queue si queueIfOffline = true
          _updateState(CacheStatus.error, errorMessage: e.toString());
        }
      }

      return true;
    } catch (e) {
      debugPrint('Error in set($key): $e');
      return false;
    }
  }

  /// Guardar datos en caché con metadata
  Future<void> _saveToCache<T>(String key, T data, {Duration? ttl}) async {
    final module = _extractModuleName(key);
    final config = CacheConfig.getModuleConfig(module);
    final effectiveTTL = ttl ?? config?.ttl ?? CacheConfig.defaultTTL;

    // Serializar datos
    final encoded = json.encode(data);
    final bytes = utf8.encode(encoded);

    // Crear metadata
    final metadata = CacheMetadata(
      cachedAt: DateTime.now(),
      expiresAt: DateTime.now().add(effectiveTTL),
      lastSyncedAt: DateTime.now(),
      hash: _generateHash(encoded),
      sizeInBytes: bytes.length,
      module: module,
      version: CacheConfig.cacheVersion,
    );

    // Guardar datos y metadata
    await _storage.write(key, encoded);
    await _storage.writeJson('metadata_$key', metadata.toJson());

    debugPrint(
      'Cached $key (${bytes.length} bytes, TTL: ${effectiveTTL.inMinutes}min)',
    );
  }

  // ==================== UTILIDADES ====================

  /// Obtener metadata de una entrada
  Future<CacheMetadata?> _getMetadata(String key) async {
    final metadataJson = await _storage.readJson('metadata_$key');
    if (metadataJson == null) return null;

    try {
      return CacheMetadata.fromJson(metadataJson);
    } catch (e) {
      debugPrint('Error deserializing metadata for $key: $e');
      return null;
    }
  }

  /// Extraer nombre del módulo desde la key
  String _extractModuleName(String key) {
    if (key.startsWith('cache_')) {
      final parts = key.split('_');
      if (parts.length >= 2) return parts[1];
    }
    return 'unknown';
  }

  /// Generar hash de datos
  String _generateHash(String data) {
    return md5.convert(utf8.encode(data)).toString();
  }

  /// Actualizar estado
  void _updateState(CacheStatus status, {String? errorMessage}) {
    _currentState = _currentState.copyWith(
      status: status,
      errorMessage: errorMessage,
    );
    _stateController.add(_currentState);
  }

  /// Limpiar recursos
  void dispose() {
    _stateController.close();
    _connectivity.dispose();
  }
}
