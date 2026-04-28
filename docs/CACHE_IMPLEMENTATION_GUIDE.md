# 🚀 Sistema de Caché Local para MangoPOS - Guía de Implementación

## 📋 Estado Actual

### ✅ Archivos Base Creados
```
lib/core/cache/
├── models/
│   ├── cache_entry.dart          ✅ Modelo de entrada de caché
│   ├── pending_operation.dart    ✅ Operaciones offline
│   └── sync_status.dart          ✅ Estados de sincronización
├── cache_config.dart             ✅ Configuración modular
└── (pendientes por implementar)

lib/core/storage/
└── storage_service.dart          ✅ Abstracción SharedPreferences
```

---

## 🎯 Plan de Implementación por Fases

### **FASE 1: Core Infrastructure** (Prioridad CRÍTICA)

#### 1.1 Cache Manager Principal
**Archivo:** `lib/core/cache/cache_manager.dart`

Este es el **cerebro del sistema**. Debe ser un **singleton** que orqueste:
- Inicialización con carga por prioridades
- Operaciones CRUD con fallback automático  
- Gestión del ciclo de vida del caché
- Coordinación de sincronización

**Funcionalidad clave:**
```dart
class CacheManager {
  static CacheManager? _instance;
  
  // Singleton
  factory CacheManager() => _instance ??= CacheManager._internal();
  
  // Inicialización con carga progresiva
  static Future<void> initialize({
    List<CachePriority> priorityOrder,
    Function(String module, int progress)? onProgress,
  }) async { /* ... */ }
  
  // GET con múltiples estrategias
  Future<T?> get<T>({
    required String key,
    required T Function(dynamic) fromJson,
    required Future<T> Function() fetch FromApi,
    CacheStrategy strategy = CacheStrategy.cacheFirst,
    bool useStaleCacheOnError = true,
    Duration? ttl,
  }) async { /* ... */ }
  
  // SET con soporte offline
  Future<bool> set<T>({
    required String key,
    required T data,
    Future<void> Function()? syncToServer,
    bool queueIfOffline = false,
  }) async { /* ... */ }
  
  // Stream de estado para UI
  Stream<CacheState> get stateStream;
}
```

#### 1.2 Connectivity Service
**Archivo:** `lib/core/network/connectivity_service.dart`

Monitor de conectividad que:
- Detecta cambios en la conexión a internet
- Proporciona stream de estado
- Permite simulación para tests

```dart
class ConnectivityService {
  static final instance = ConnectivityService._();
  
  Stream<bool> get connectionStream;
  bool get isConnected;
  
  Future<void> initialize() async { /* ... */ }
}
```

#### 1.3 Sync Queue
**Archivo:** `lib/core/network/sync_queue.dart`

Cola de sincronización para operaciones offline:
- Almacena operaciones pendientes
- Procesa automáticamente al reconectar
- Sistema de reintentos con backoff exponencial

---

### **FASE 2: Módulos Críticos** (Implementar en orden)

#### 2.1 Productos Cache Manager
**Archivo:** `lib/features/productos/cache/productos_cache_manager.dart`

**¿Por qué primero?** Es el módulo más consultado y crítico para ventas.

```dart
class ProductosCacheManager {
  static const String _cacheKey = 'productos_lista';
  
  Future<List<Producto>> getProductos() async {
    return await CacheManager().get<List<Producto>>(
      key: StorageKeys.cacheKey('productos', _cacheKey),
      fromJson: (json) => (json as List)
          .map((e) => Producto.fromJson(e))
          .toList(),
      fetchFromApi: () => _apiClient.getProductos(),
      strategy: CacheStrategy.cacheFirst,
      ttl: Duration(hours: 12),
    ) ?? [];
  }
  
  Future<void> syncProductos() async { /* ... */ }
}
```

#### 2.2 Ventas Offline Queue
**Archivo:** `lib/features/ventas/cache/ventas_offline_queue.dart`

**CRÍTICO:** Las ventas deben funcionar 100% sin conexión.

```dart
class VentasOfflineQueue {
  Future<void> agregarVenta(Venta venta) async {
    final operation = PendingOperation(
      id: Uuid().v4(),
      type: OperationType.create,
      module: 'ventas',
      data: venta.toJson(),
      timestamp: DateTime.now(),
      priority: QueuePriority.critical,
    );
    
    await CacheManager().queueOperation(operation);
  }
  
  Future<void> procesarQueue() async { /* ... */ }
}
```

#### 2.3 Caja Session Cache
**Archivo:** `lib/features/caja/cache/caja_session_cache.dart`

Gestión de sesión con persistencia robusta:

```dart
class CajaSessionCache {
  Future<CajaSession?> getSesionActiva() async {
    return await CacheManager().get<CajaSession>(
      key: StorageKeys.cacheKey('caja', 'session_active'),
      fromJson: (json) => CajaSession.fromJson(json),
      fetchFromApi: () => _apiClient.getCajaActiva(),
      strategy: CacheStrategy.cacheFirst,
      // Sin TTL mientras caja abierta
      ttl: Duration(days: 365),
    );
  }
}
```

#### 2.4 Mesas Realtime Sync
**Archivo:** `lib/features/mesas/cache/mesas_realtime_sync.dart`

Sincronización automática cada 2-5 minutos:

```dart
class MesasRealtimeSync {
  Timer? _syncTimer;
  
  void iniciarSyncAutomatico() {
    _syncTimer = Timer.periodic(Duration(minutes: 3), (_) async {
      await sincronizarMesas();
    });
  }
  
  Future<void> sincronizarMesas() async { /* ... */ }
}
```

---

### **FASE 3: Servicios de Mantenimiento**

#### 3.1 Cache Sync Coordinator
**Archivo:** `lib/core/cache/cache_sync_coordinator.dart`

Coordina sincronización inteligente:
- Sincroniza solo si hay cambios (hash comparison)
- Respeta prioridades y estrategias
- Previene sincronizaciones innecesarias

#### 3.2 Cache Maintenance Service
**Archivo:** `lib/core/cache/cache_maintenance_service.dart`

Limpieza y mantenimiento automático:
- Elimina datos expirados
- Comprime datos grandes (> 1MB)
- Libera espacio por prioridad (low → medium)

---

## 📦 Dependencias Requeridas

```yaml
# pubspec.yaml
dependencies:
  shared_preferences: ^2.2.2
  connectivity_plus: ^5.0.2
  crypto: ^3.0.3         # Para hashing
  uuid: ^4.0.0           # Para IDs únicos
```

---

## 🚥 ¿Cómo Proceder?

### Opción A: Implementación Completa Automatizada
**Te genero todos los archivos necesarios en secuencia:**

1. CacheManager principal (500+ líneas)
2. ConnectivityService
3. SyncQueue
4. CacheSyncCoordinator
5. CacheMaintenanceService
6. Módulos específicos (Productos, Ventas, Caja, Mesas)
7. UI Components (CacheStatusIndicator)
8. Ejemplos de uso

**Ventajas:**
✅ Sistema completo y funcional de inmediato
✅ Todos los módulos implementados
✅ Tests incluidos

**Desventajas:**
⚠️ Requiere revisar ~3000 líneas de código
⚠️ Puede ser abrumador inicialmente

### Opción B: Implementación Incremental Guiada
**Te guío paso a paso con código funcional minimal:**

1. **DÍA 1**: CacheManager básico + StorageService (ya hecho)
2. **DÍA 2**: Productos cache (módulo más simple para aprender)
3. **DÍA 3**: Ventas offline queue (crítico)
4. **DÍA 4**: Caja session + Mesas realtime
5. **DÍA 5**: Servicios de mantenimiento y optimización

**Ventajas:**
✅ Entiendes cada parte del sistema
✅ Puedes probar incrementalmente
✅ Menos chance de errores

**Desventajas:**
⚠️ Toma más tiempo
⚠️ Funcionalidad partial hasta completar

### Opción C: Mix Estratégico (RECOMENDADO)
**Core completo + Guía para módulos:**

1. Te genero CacheManager, Connectivity, SyncQueue (core completo)
2. Te doy 1 ejemplo completo (Productos)
3. Tú implementas los demás módulos siguiendo el patrón
4. Yo reviso y optimizo

**Ventajas:**
✅ Balance entre rapidez y aprendizaje
✅ Core robusto garantizado
✅ Autonomía en módulos específicos

---

## 📊 Métricas de Éxito

Al finalizar, debes poder:

### Tests de Performance
```dart
✅ Cold start < 500ms con cache poblado
✅ Carga de 5000 productos < 1 segundo  
✅ Búsqueda de producto < 50ms
✅ Actualización de mesas < 100ms
```

### Tests Funcionales
```dart
✅ Crear venta sin conexión
✅ Sincronizar 50+ ventas offline
✅ Recuperar sesión de caja después de crash
✅ Actualizar mesas automáticamente cada 3 min
```

### Tests de Robustez
```dart
✅ Cache no excede 30 MB total
✅ Limpieza automática funciona
✅ No pierde datos en operaciones críticas
✅ Retry automático con backoff exponencial
```

---

## ❓ ¿Qué Opción Prefieres?

**Responde con:**
- **A** para implementación completa automatizada
- **B** para incremental guiada
- **C** para mix estratégico (recomendado)

O indícame cualquier ajuste al plan.

---

## 📝 Notas Importantes

### Módulos Ya Implementados
Según tu código actual tienes:
- ✅ Productos (catálogo, modificadores)
- ✅ Ventas (orders, order_items)
- ✅ Caja (cash_register_sessions, cash_transactions)
- ✅ Mesas (dining_tables, table_sessions, zones)
- ✅ Configuración (businesses, payment_methods, printers)

### Módulos Pendientes (NO cachear aún)
- ❌ Reportes (consulta on-demand)
- ❌ Historial completo de ventas (solo últimas 100)
- ❌ Fidelización (no implementado)
- ❌ Compras/Proveedores (no implementado)

---

**Siguiente paso:** Dime qué opción eliges y comenzamos inmediatamente. 🚀
