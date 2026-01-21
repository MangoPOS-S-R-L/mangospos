# 🚀 Guía de Mejoras para MangoPos - Prevención de Timeouts y Errores de BD

## 📋 Resumen del Problema

El error `PostgrestException(message: canceling statement due to statement timeout, code: 57014)` indica que las consultas a la base de datos están tardando demasiado tiempo y superan el límite configurado en PostgreSQL.

## ✅ Soluciones Implementadas

### 1. **Configuración Centralizada de Supabase** (`supabase_config.dart`)

- ✨ Timeouts personalizados para diferentes tipos de operaciones:
  - **Lectura (SELECT)**: 15 segundos
  - **Escritura (INSERT/UPDATE/DELETE)**: 20 segundos
  - **RPC**: 25 segundos

- ✨ Identificación de errores recuperables (timeouts, conexión, deadlocks)
- ✨ Mensajes de error amigables para el usuario
- ✨ Configuración optimizada de Supabase con reintentos automáticos

### 2. **Wrapper de Operaciones de BD** (`database_operation_wrapper.dart`)

- ✨ **Reintentos automáticos** con backoff exponencial
- ✨ **Manejo inteligente de errores** (distingue entre recuperables y no recuperables)
- ✨ **Logging detallado** para debugging
- ✨ **Timeouts configurables** por tipo de operación
- ✨ **Operaciones paralelas** con manejo de errores

### 3. **Repositorio Mejorado** (`sales_repository_improved.dart`)

- ✨ Todas las operaciones envueltas con manejo de errores
- ✨ Nombres descriptivos para cada operación (mejor debugging)
- ✨ Reintentos automáticos en caso de fallos temporales

## 🔧 Cómo Usar las Mejoras

### Opción 1: Migración Gradual (Recomendado)

Puedes mantener tu `SalesRepository` actual y migrar gradualmente los métodos que están dando problemas:

\`\`\`dart
// En tu sales_repository.dart existente
import '../../core/network/database_operation_wrapper.dart';

// Ejemplo: Mejorar solo el método processPayment
Future<Payment> processPayment({
  required String orderId,
  String? checkId,
  required String paymentMethodId,
  required double amount,
  String? reference,
  String? customerId,
  String? customerRnc,
  String? cashierSessionId,
}) async {
  return DatabaseOperationWrapper.rpc(
    operationName: 'Procesar Pago',
    operation: () async {
      final response = await _client.rpc(
        SalesQueries.rpcProcessPayment,
        params: {
          'p_order_id': orderId,
          'p_check_id': checkId,
          'p_payment_method_id': paymentMethodId,
          'p_amount': amount,
          'p_reference': reference,
          'p_customer_id': customerId,
          'p_customer_rnc': customerRnc,
          'p_cashier_session_id': cashierSessionId,
        },
      );
      return Payment.fromMap(response);
    },
  );
}
\`\`\`

### Opción 2: Reemplazo Completo

Reemplaza tu `SalesRepository` con `SalesRepositoryImproved` y actualiza las referencias en tus providers.

## 📊 Mejoras Adicionales Recomendadas

### 1. **Optimización de Consultas SQL**

Revisa las funciones RPC en PostgreSQL para asegurar que:
- Tienen índices apropiados
- No hacen consultas innecesarias
- Usan `LIMIT` cuando sea apropiado

\`\`\`sql
-- Ejemplo: Agregar índice para mejorar rendimiento
CREATE INDEX IF NOT EXISTS idx_table_sessions_business_closed 
ON table_sessions(business_id, closed_at) 
WHERE closed_at IS NULL;
\`\`\`

### 2. **Configuración de Timeouts en PostgreSQL**

Ajusta los timeouts en tu base de datos de Supabase:

\`\`\`sql
-- Aumentar el statement_timeout (solo si es necesario)
ALTER DATABASE postgres SET statement_timeout = '30s';

-- O configurarlo por sesión en funciones específicas
CREATE OR REPLACE FUNCTION fn_process_payment(...)
RETURNS ...
AS $$
BEGIN
  SET LOCAL statement_timeout = '30s';
  -- ... resto de la función
END;
$$ LANGUAGE plpgsql;
\`\`\`

### 3. **Caché de Datos Frecuentes**

Implementa caché para datos que no cambian frecuentemente:

\`\`\`dart
// Ejemplo: Caché simple con Riverpod
final menuItemsCacheProvider = FutureProvider.autoDispose.family<List<MenuItem>, String>(
  (ref, businessId) async {
    // Esta consulta se cachea automáticamente por 5 minutos
    final link = ref.keepAlive();
    Timer(const Duration(minutes: 5), link.close);
    
    return DatabaseOperationWrapper.read(
      operationName: 'Obtener Menú',
      operation: () async {
        final data = await Supabase.instance.client
            .from('menu_items')
            .select()
            .eq('business_id', businessId);
        return data.map((json) => MenuItem.fromMap(json)).toList();
      },
    );
  },
);
\`\`\`

### 4. **Monitoreo y Logging**

Implementa un sistema de logging para identificar operaciones lentas:

\`\`\`dart
// lib/core/logging/performance_logger.dart
class PerformanceLogger {
  static void logSlowOperation(String operationName, Duration duration) {
    if (duration.inSeconds > 5) {
      print('⚠️ OPERACIÓN LENTA: $operationName tardó ${duration.inSeconds}s');
      // Aquí podrías enviar a un servicio de analytics
    }
  }
}
\`\`\`

### 5. **Paginación para Consultas Grandes**

Implementa paginación para evitar cargar demasiados datos:

\`\`\`dart
Future<List<Order>> getOrders({
  required String businessId,
  int page = 0,
  int pageSize = 20,
}) async {
  return DatabaseOperationWrapper.read(
    operationName: 'Obtener Órdenes (Página $page)',
    operation: () async {
      final data = await _client
          .from('orders')
          .select()
          .eq('business_id', businessId)
          .order('created_at', ascending: false)
          .range(page * pageSize, (page + 1) * pageSize - 1);
      
      return data.map((json) => Order.fromMap(json)).toList();
    },
  );
}
\`\`\`

## 🎯 Próximos Pasos

1. **Inmediato**: 
   - ✅ Ya implementamos la configuración de Supabase con timeouts
   - ✅ Ya creamos el wrapper de operaciones
   - ⏳ Migrar los métodos críticos (como `processPayment`) al nuevo wrapper

2. **Corto Plazo** (esta semana):
   - Revisar y optimizar las funciones RPC más lentas
   - Agregar índices a las tablas más consultadas
   - Implementar caché para datos estáticos

3. **Mediano Plazo** (próximas 2 semanas):
   - Implementar paginación en listados grandes
   - Agregar sistema de logging/monitoreo
   - Revisar y optimizar consultas complejas

## 🔍 Debugging de Problemas de Timeout

Si sigues experimentando timeouts:

1. **Identifica la operación lenta**:
   - Revisa los logs en la consola (el wrapper imprime el nombre de la operación)
   - Ejemplo: `[Procesar Pago] ❌ Error en intento 1: ...`

2. **Revisa la función RPC en Supabase**:
   - Ve al SQL Editor en Supabase
   - Ejecuta `EXPLAIN ANALYZE` en la consulta problemática
   - Busca operaciones sin índices (Sequential Scan)

3. **Aumenta el timeout temporalmente**:
   \`\`\`dart
   // Solo para debugging
   await DatabaseOperationWrapper.execute(
     operationName: 'Operación Problemática',
     timeout: const Duration(seconds: 60), // Timeout temporal más alto
     operation: () async {
       // ... tu operación
     },
   );
   \`\`\`

## 📞 Soporte

Si necesitas ayuda adicional:
- Revisa los logs detallados que proporciona el wrapper
- Verifica el estado de tu conexión a internet
- Revisa el dashboard de Supabase para ver métricas de rendimiento
- Considera actualizar tu plan de Supabase si estás cerca de los límites

## 🎉 Beneficios de las Mejoras

- ✅ **Menos errores**: Reintentos automáticos para errores temporales
- ✅ **Mejor UX**: Mensajes de error claros y amigables
- ✅ **Debugging más fácil**: Logs detallados de cada operación
- ✅ **Mayor confiabilidad**: Manejo robusto de timeouts y errores de red
- ✅ **Código más limpio**: Separación de concerns (lógica de negocio vs manejo de errores)
