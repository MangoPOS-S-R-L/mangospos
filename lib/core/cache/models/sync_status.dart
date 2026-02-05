/// Estados de caché para la UI
enum CacheStatus {
  initializing, // Inicializando cache
  loading, // Cargando desde cache/servidor
  cached, // Datos desde cache local
  syncing, // Sincronizando con servidor
  synced, // Sincronizado con servidor
  offline, // Sin conexión, usando cache
  error, // Error al cargar
  empty, // Sin datos disponibles
  stale, // Cache expirado pero disponible
}

/// Resultado de sincronización
enum SyncResult {
  success, // Sincronización exitosa
  noChanges, // Sin cambios detectados
  partial, // Sincronización parcial
  failed, // Falló completamente
  offline, // Sin conexión
}

/// Estado del caché
class CacheState {
  final CacheStatus status;
  final String? errorMessage;
  final DateTime? lastSync;
  final int pendingOperations;
  final double cacheUsagePercent;
  final Map<String, ModuleSyncStatus> moduleStatus;

  const CacheState({
    required this.status,
    this.errorMessage,
    this.lastSync,
    this.pendingOperations = 0,
    this.cacheUsagePercent = 0.0,
    this.moduleStatus = const {},
  });

  CacheState copyWith({
    CacheStatus? status,
    String? errorMessage,
    DateTime? lastSync,
    int? pendingOperations,
    double? cacheUsagePercent,
    Map<String, ModuleSyncStatus>? moduleStatus,
  }) {
    return CacheState(
      status: status ?? this.status,
      errorMessage: errorMessage,
      lastSync: lastSync ?? this.lastSync,
      pendingOperations: pendingOperations ?? this.pendingOperations,
      cacheUsagePercent: cacheUsagePercent ?? this.cacheUsagePercent,
      moduleStatus: moduleStatus ?? this.moduleStatus,
    );
  }

  bool get hasError => status == CacheStatus.error;
  bool get isOffline => status == CacheStatus.offline;
  bool get isSyncing => status == CacheStatus.syncing;
  bool get hasPendingOperations => pendingOperations > 0;
}

/// Estado de sincronización por módulo
class ModuleSyncStatus {
  final String moduleName;
  final SyncResult lastResult;
  final DateTime? lastSyncTime;
  final String? errorMessage;
  final bool isSyncing;

  const ModuleSyncStatus({
    required this.moduleName,
    required this.lastResult,
    this.lastSyncTime,
    this.errorMessage,
    this.isSyncing = false,
  });

  ModuleSyncStatus copyWith({
    String? moduleName,
    SyncResult? lastResult,
    DateTime? lastSyncTime,
    String? errorMessage,
    bool? isSyncing,
  }) {
    return ModuleSyncStatus(
      moduleName: moduleName ?? this.moduleName,
      lastResult: lastResult ?? this.lastResult,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      errorMessage: errorMessage,
      isSyncing: isSyncing ?? this.isSyncing,
    );
  }
}
