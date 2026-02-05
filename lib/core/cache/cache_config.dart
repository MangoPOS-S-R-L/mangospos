/// Prioridades de caché por módulo
enum CachePriority {
  critical, // Productos, Ventas, Caja, Mesas - SIEMPRE se cargan
  high, // Clientes, Inventario - Se cargan después de critical
  medium, // Proveedores, Recetas - Bajo demanda
  low, // Otros - Solo si hay espacio
}

/// Estrategias de sincronización
enum CacheSyncStrategy {
  realtime, // Mesas (cada 2-5 min), Caja activa
  aggressive, // Productos, Configuración (cada 30 min)
  moderate, // Clientes, Inventario (cada 2 horas)
  lazy, // Proveedores, Recetas (cada 24 horas)
  manual, // Solo cuando usuario lo pide
}

/// Estrategias de lectura de caché
enum CacheStrategy {
  cacheFirst, // Intentar cache primero, luego red
  networkFirst, // Intentar red primero, luego cache
  cacheOnly, // Solo usar cache
  networkOnly, // Solo usar red
}

/// Configuración de un módulo de caché
class ModuleCacheConfig {
  final String moduleName;
  final bool enabled;
  final CachePriority priority;
  final CacheSyncStrategy syncStrategy;
  final Duration ttl;
  final int maxSizeMB;
  final bool allowOfflineOperations;
  final bool compressData;

  const ModuleCacheConfig({
    required this.moduleName,
    required this.enabled,
    required this.priority,
    required this.syncStrategy,
    required this.ttl,
    this.maxSizeMB = 10,
    this.allowOfflineOperations = false,
    this.compressData = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'moduleName': moduleName,
      'enabled': enabled,
      'priority': priority.name,
      'syncStrategy': syncStrategy.name,
      'ttl': ttl.inSeconds,
      'maxSizeMB': maxSizeMB,
      'allowOfflineOperations': allowOfflineOperations,
      'compressData': compressData,
    };
  }

  factory ModuleCacheConfig.fromJson(Map<String, dynamic> json) {
    return ModuleCacheConfig(
      moduleName: json['moduleName'] as String,
      enabled: json['enabled'] as bool,
      priority: CachePriority.values.firstWhere(
        (e) => e.name == json['priority'],
      ),
      syncStrategy: CacheSyncStrategy.values.firstWhere(
        (e) => e.name == json['syncStrategy'],
      ),
      ttl: Duration(seconds: json['ttl'] as int),
      maxSizeMB: json['maxSizeMB'] as int? ?? 10,
      allowOfflineOperations: json['allowOfflineOperations'] as bool? ?? false,
      compressData: json['compressData'] as bool? ?? false,
    );
  }
}

/// Configuración global del sistema de caché
class CacheConfig {
  // MÓDULOS CRÍTICOS (SIEMPRE ACTIVOS)
  static const Map<String, ModuleCacheConfig> modules = {
    'productos': ModuleCacheConfig(
      moduleName: 'productos',
      enabled: true,
      priority: CachePriority.critical,
      syncStrategy: CacheSyncStrategy.aggressive,
      ttl: Duration(hours: 12),
      maxSizeMB: 10,
      compressData: true,
    ),

    'ventas': ModuleCacheConfig(
      moduleName: 'ventas',
      enabled: true,
      priority: CachePriority.critical,
      syncStrategy: CacheSyncStrategy.realtime,
      ttl: Duration(hours: 1), // Solo para historial
      maxSizeMB: 5,
      allowOfflineOperations: true, // CRÍTICO: Ventas offline
    ),

    'caja': ModuleCacheConfig(
      moduleName: 'caja',
      enabled: true,
      priority: CachePriority.critical,
      syncStrategy: CacheSyncStrategy.realtime,
      ttl: Duration(days: 1), // Sin TTL mientras caja abierta
      maxSizeMB: 2,
      allowOfflineOperations: true,
    ),

    'mesas': ModuleCacheConfig(
      moduleName: 'mesas',
      enabled: true,
      priority: CachePriority.critical,
      syncStrategy: CacheSyncStrategy.realtime,
      ttl: Duration(minutes: 5),
      maxSizeMB: 1,
    ),

    'configuracion': ModuleCacheConfig(
      moduleName: 'configuracion',
      enabled: true,
      priority: CachePriority.critical,
      syncStrategy: CacheSyncStrategy.aggressive,
      ttl: Duration(hours: 24),
      maxSizeMB: 1,
    ),

    // MÓDULOS DE ALTA PRIORIDAD
    'clientes': ModuleCacheConfig(
      moduleName: 'clientes',
      enabled: true,
      priority: CachePriority.high,
      syncStrategy: CacheSyncStrategy.moderate,
      ttl: Duration(hours: 12),
      maxSizeMB: 3,
    ),

    'inventario': ModuleCacheConfig(
      moduleName: 'inventario',
      enabled: true,
      priority: CachePriority.high,
      syncStrategy: CacheSyncStrategy.moderate,
      ttl: Duration(hours: 6),
      maxSizeMB: 2,
    ),

    // MÓDULOS PREPARADOS PARA FUTURO (DESHABILITADOS)
    'fidelizacion': ModuleCacheConfig(
      moduleName: 'fidelizacion',
      enabled: false,
      priority: CachePriority.medium,
      syncStrategy: CacheSyncStrategy.lazy,
      ttl: Duration(days: 7),
      maxSizeMB: 2,
    ),

    'reportes': ModuleCacheConfig(
      moduleName: 'reportes',
      enabled: false, // NO cachear reportes
      priority: CachePriority.low,
      syncStrategy: CacheSyncStrategy.manual,
      ttl: Duration(hours: 1),
      maxSizeMB: 5,
    ),
  };

  // Configuración global
  static const int maxTotalCacheSizeMB = 30;
  static const Duration defaultTTL = Duration(hours: 12);
  static const bool enableCompression = true;
  static const bool enableDebugLogs = true;
  static const int cacheVersion = 1;

  /// Obtener configuración de un módulo
  static ModuleCacheConfig? getModuleConfig(String moduleName) {
    return modules[moduleName];
  }

  /// Verificar si un módulo está habilitado
  static bool isModuleEnabled(String moduleName) {
    return modules[moduleName]?.enabled ?? false;
  }

  /// Obtener módulos por prioridad
  static List<String> getModulesByPriority(CachePriority priority) {
    return modules.entries
        .where((e) => e.value.enabled && e.value.priority == priority)
        .map((e) => e.key)
        .toList();
  }

  /// Obtener módulos habilitados ordenados por prioridad
  static List<String> getEnabledModulesInPriorityOrder() {
    final allModules = modules.entries.where((e) => e.value.enabled).toList();

    allModules.sort((a, b) {
      return a.value.priority.index.compareTo(b.value.priority.index);
    });

    return allModules.map((e) => e.key).toList();
  }
}
