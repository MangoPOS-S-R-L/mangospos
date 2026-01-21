# 🎯 Plan de Acción - Implementación de Mejoras MangoPos

## 📅 Cronograma de Implementación

### ✅ FASE 1: FUNDAMENTOS (YA COMPLETADO)

**Archivos creados:**
- ✅ `lib/core/network/supabase_config.dart`
- ✅ `lib/core/network/database_operation_wrapper.dart`
- ✅ `lib/data/repositories/sales_repository_improved.dart`
- ✅ `lib/widgets/error_handler_widget.dart`
- ✅ `lib/presentation/sales/examples/payment_screen_improved.dart`
- ✅ `MEJORAS_BD.md`
- ✅ `RESUMEN_MEJORAS.md`

**Configuración actualizada:**
- ✅ `lib/main.dart` - Inicialización mejorada de Supabase

---

### 🔥 FASE 2: IMPLEMENTACIÓN CRÍTICA (PRÓXIMOS 2 DÍAS)

#### Día 1: Migrar Método de Pago

**1. Actualizar `sales_repository.dart`** (30 min)

```dart
// Reemplazar el método processPayment existente
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
```

**2. Actualizar la pantalla de pago** (1 hora)

Busca el archivo donde procesas pagos (probablemente en `lib/presentation/sales/` o similar) y actualiza:

```dart
// Agregar import
import '../../../widgets/error_handler_widget.dart';

// En el método que procesa el pago
try {
  await _salesRepo.processPayment(...);
  
  // Mostrar éxito
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white),
            SizedBox(width: 12),
            Text('Pago procesado exitosamente'),
          ],
        ),
        backgroundColor: Colors.green,
      ),
    );
  }
} catch (error) {
  // Mostrar error amigable
  if (mounted) {
    ErrorSnackBar.show(context, error);
  }
}
```

**3. Probar** (30 min)
- Hacer un pago normal (debe funcionar)
- Desconectar internet y hacer un pago (debe mostrar error amigable)
- Reconectar y usar el botón "Reintentar"

#### Día 2: Migrar Operaciones de Sesiones

**1. Actualizar métodos de sesiones** (1 hora)

```dart
// En sales_repository.dart

Future<Map<String, dynamic>> openTable({
  required String tableId,
  String? userId,
  int peopleCount = 1,
}) async {
  return DatabaseOperationWrapper.rpc(
    operationName: 'Abrir Mesa #$tableId',
    operation: () async {
      final response = await _client.rpc(
        SalesQueries.rpcOpenTable,
        params: {
          'p_people_count': peopleCount,
          'p_table_id': tableId,
          'p_user_id': userId,
        },
      );
      if (response == null) {
        throw Exception('No se pudo abrir la mesa');
      }
      return Map<String, dynamic>.from(response as Map);
    },
  );
}

Future<List<TableSession>> getActiveSessions(String businessId) async {
  return DatabaseOperationWrapper.read(
    operationName: 'Obtener Sesiones Activas',
    operation: () async {
      final data = await _client
          .from('table_sessions')
          .select()
          .eq('business_id', businessId)
          .isFilter('closed_at', null)
          .order('opened_at', ascending: false);
      return data.map((json) => TableSession.fromMap(json)).toList();
    },
  );
}
```

**2. Probar** (30 min)
- Abrir varias mesas
- Ver lista de sesiones activas
- Verificar que los errores se manejan correctamente

---

### 🚀 FASE 3: OPTIMIZACIÓN (PRÓXIMA SEMANA)

#### Lunes: Revisar Funciones RPC Lentas

**1. Identificar funciones lentas** (1 hora)

En Supabase SQL Editor:

```sql
-- Ver funciones que tardan más
SELECT 
  schemaname,
  funcname,
  calls,
  total_time,
  mean_time,
  max_time
FROM pg_stat_user_functions
WHERE schemaname = 'public'
ORDER BY mean_time DESC
LIMIT 10;
```

**2. Analizar cada función** (2 horas)

Para cada función lenta:

```sql
EXPLAIN ANALYZE
SELECT * FROM fn_process_payment(
  'order-id-example',
  null,
  'payment-method-id',
  100.00,
  null,
  null,
  null,
  null
);
```

Busca:
- `Seq Scan` (escaneo secuencial - malo)
- `Index Scan` (escaneo de índice - bueno)
- Tiempo de ejecución alto

**3. Agregar índices necesarios** (1 hora)

```sql
-- Ejemplo: Si ves Seq Scan en table_sessions
CREATE INDEX IF NOT EXISTS idx_table_sessions_business_closed 
ON table_sessions(business_id, closed_at) 
WHERE closed_at IS NULL;

-- Para orders
CREATE INDEX IF NOT EXISTS idx_orders_business_status 
ON orders(business_id, status);

-- Para order_items
CREATE INDEX IF NOT EXISTS idx_order_items_order 
ON order_items(order_id);

-- Para payments
CREATE INDEX IF NOT EXISTS idx_payments_order 
ON payments(order_id);
```

#### Martes-Miércoles: Migrar Resto de Métodos

**Prioridad Alta:**
1. `addItemFromMenu` - Se usa frecuentemente
2. `getOrderItems` - Puede ser lento con muchos items
3. `sendToKitchen` - Crítico para operaciones

**Prioridad Media:**
4. `updateItemQuantity`
5. `deleteItem`
6. `closeOrder`

**Prioridad Baja:**
7. Métodos legacy (pueden esperar)

#### Jueves: Implementar Caché

**1. Crear provider de caché para menú** (2 horas)

```dart
// lib/presentation/menu/providers/menu_cache_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

final menuItemsCacheProvider = FutureProvider.autoDispose.family<
  List<MenuItem>, 
  String
>((ref, businessId) async {
  // Mantener caché por 5 minutos
  final link = ref.keepAlive();
  Timer(const Duration(minutes: 5), link.close);
  
  final repo = ref.watch(menuRepositoryProvider);
  return DatabaseOperationWrapper.read(
    operationName: 'Obtener Menú (Caché)',
    operation: () => repo.getMenuItems(businessId),
  );
});
```

**2. Usar en la UI** (1 hora)

```dart
// En tu widget de menú
final menuItems = ref.watch(menuItemsCacheProvider(businessId));

menuItems.when(
  data: (items) => ListView.builder(...),
  loading: () => CircularProgressIndicator(),
  error: (error, stack) => ErrorHandlerWidget(
    error: error,
    onRetry: () => ref.refresh(menuItemsCacheProvider(businessId)),
  ),
);
```

#### Viernes: Testing y Ajustes

**1. Testing de carga** (2 horas)
- Abrir 10+ mesas simultáneamente
- Procesar múltiples pagos
- Agregar muchos items a órdenes
- Verificar tiempos de respuesta

**2. Ajustar timeouts si es necesario** (1 hora)

```dart
// En supabase_config.dart
// Si ves que algunas operaciones necesitan más tiempo
static const Duration rpcTimeout = Duration(seconds: 30); // Aumentar si es necesario
```

**3. Documentar hallazgos** (30 min)
- Qué operaciones son más lentas
- Qué mejoras tuvieron más impacto
- Qué queda por optimizar

---

### 📊 FASE 4: MONITOREO (PRÓXIMO MES)

#### Semana 1-2: Implementar Analytics

**1. Crear servicio de logging** (3 horas)

```dart
// lib/core/logging/analytics_service.dart
class AnalyticsService {
  static void logSlowOperation(
    String operationName,
    Duration duration,
    bool success,
  ) {
    if (duration.inSeconds > 5) {
      // Enviar a tu servicio de analytics
      // Ejemplo: Firebase Analytics, Sentry, etc.
      print('⚠️ SLOW: $operationName - ${duration.inSeconds}s - Success: $success');
    }
  }
  
  static void logError(
    String operationName,
    dynamic error,
    int attempts,
  ) {
    // Enviar errores a servicio de tracking
    print('❌ ERROR: $operationName - Attempts: $attempts - Error: $error');
  }
}
```

**2. Integrar en wrapper** (1 hora)

```dart
// En database_operation_wrapper.dart
// Agregar logging al final de execute()
if (kDebugMode || kReleaseMode) {
  AnalyticsService.logSlowOperation(
    operationName,
    stopwatch.elapsed,
    true,
  );
}
```

#### Semana 3-4: Optimizaciones Finales

**1. Revisar métricas recopiladas**
- Identificar operaciones más problemáticas
- Priorizar optimizaciones

**2. Implementar mejoras específicas**
- Optimizar consultas SQL
- Agregar más caché donde sea necesario
- Ajustar timeouts basado en datos reales

---

## 📋 Checklist de Verificación

### Antes de cada deploy:

- [ ] Todos los tests pasan
- [ ] No hay errores de lint
- [ ] Timeouts configurados apropiadamente
- [ ] Mensajes de error son amigables
- [ ] Logging está funcionando
- [ ] Caché está limpiándose correctamente

### Después de cada deploy:

- [ ] Monitorear logs por 24 horas
- [ ] Verificar que no hay regresiones
- [ ] Revisar métricas de rendimiento
- [ ] Recopilar feedback de usuarios

---

## 🎯 Métricas de Éxito

### Semana 1:
- ✅ 0 errores de timeout en pagos
- ✅ Tiempo promedio de pago < 3 segundos
- ✅ 95%+ de operaciones exitosas en primer intento

### Semana 2:
- ✅ Todas las operaciones críticas migradas
- ✅ Tiempo de carga de menú < 2 segundos
- ✅ Usuarios reportan mejor experiencia

### Mes 1:
- ✅ 99%+ de operaciones exitosas
- ✅ Tiempo promedio de respuesta < 2 segundos
- ✅ 0 quejas de usuarios sobre errores

---

## 🆘 Contactos de Emergencia

Si algo sale mal:

1. **Rollback inmediato**: Revertir a versión anterior
2. **Revisar logs**: Buscar patrones en errores
3. **Aumentar timeouts temporalmente**: Dar más tiempo mientras investigas
4. **Contactar soporte de Supabase**: Si es problema de infraestructura

---

## 📝 Notas Finales

- **No tengas miedo de ajustar**: Los timeouts y reintentos son configurables
- **Monitorea constantemente**: Los primeros días son críticos
- **Escucha a los usuarios**: Ellos te dirán si algo no funciona
- **Itera rápido**: Pequeñas mejoras constantes > gran cambio único

**¡Éxito con la implementación! 🚀**
