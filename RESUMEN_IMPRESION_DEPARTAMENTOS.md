# 🎯 Resumen Ejecutivo - Sistema de Impresión por Departamentos

## 📊 Visión General

El sistema de impresión por departamentos de MangoPos permite **enrutar automáticamente** las órdenes a diferentes impresoras según el departamento al que pertenece cada item del menú.

### Ejemplo Práctico:

```
Cliente ordena:
  🍔 Hamburguesa → Impresora de Cocina Caliente
  🍺 Cerveza     → Impresora del Bar  
  🥗 Ensalada    → Impresora de Cocina Fría
  
Resultado: 3 tickets impresos simultáneamente en 3 impresoras diferentes
```

## 🏗️ Componentes del Sistema

### 1. **Áreas de Impresión** (Departamentos)
Representan los diferentes departamentos de tu restaurante:
- `kitchen_hot` - Cocina Caliente
- `kitchen_cold` - Cocina Fría
- `bar` - Bar/Bebidas
- `cashier` - Caja
- `fiscal` - Impresora Fiscal

### 2. **Impresoras**
Dispositivos físicos configurados:
- Tipo: Red (IP), USB, o Bluetooth
- Configuración: IP, puerto, ancho de papel
- Estado: Activa/Inactiva

### 3. **Asignaciones**
Vinculación entre áreas e impresoras:
- Una área puede tener múltiples impresoras (redundancia)
- Prioridades para failover automático
- Configuración de qué tipos de documentos imprime cada una

### 4. **Trabajos de Impresión**
Cola de impresión con:
- Estado: Pendiente, Imprimiendo, Impreso, Fallido
- Reintentos automáticos
- Tracking de errores

## 📁 Archivos Creados

### Documentación:
1. **`GUIA_IMPRESION_DEPARTAMENTOS.md`**
   - Guía completa del sistema
   - Arquitectura y flujo
   - Configuración paso a paso
   - Mejores prácticas

### Código:
2. **`lib/data/repositories/printing_service.dart`**
   - Servicio de impresión con agrupación automática
   - Lógica de enrutamiento por departamento
   - Creación de trabajos de impresión
   - Reimpresión por área

3. **`lib/presentation/settings/screens/printer_configuration_screen.dart`**
   - Interfaz de usuario para configuración
   - Gestión de impresoras
   - Gestión de áreas
   - Asignación de impresoras a áreas

### Base de Datos:
4. **`database/setup_printing_departments.sql`**
   - Script SQL completo
   - Tablas, funciones, triggers
   - Vistas de monitoreo
   - Datos de ejemplo

## 🚀 Cómo Implementar

### Paso 1: Configurar Base de Datos (5 minutos)

```sql
-- En Supabase SQL Editor, ejecutar:
-- 1. Copiar contenido de setup_printing_departments.sql
-- 2. Pegar y ejecutar

-- 3. Crear áreas predeterminadas
SELECT fn_create_default_print_areas('tu-business-id');

-- 4. Asignar áreas a items del menú
SELECT fn_assign_print_area_by_category();
```

### Paso 2: Registrar Impresoras (10 minutos)

Usar la pantalla de configuración o código:

```dart
final printingRepo = PrintingRepository(Supabase.instance.client);

// Registrar impresora de cocina
await printingRepo.createPrinter(
  businessId: businessId,
  name: 'Impresora Cocina 1',
  type: 'network',
  ipAddress: '192.168.1.100',
  port: 9100,
  paperWidth: 80,
);
```

### Paso 3: Asignar Impresoras a Áreas (5 minutos)

```dart
// Obtener áreas
final areas = await printingRepo.getPrintAreas(businessId);
final kitchenArea = areas.firstWhere((a) => a.code == 'kitchen_hot');

// Asignar impresora
await printingRepo.linkAreaToPrinter(
  businessId: businessId,
  areaId: kitchenArea.id,
  printerId: printerId,
  enabled: true,
  printsOrders: true,
  priority: 1,
);
```

### Paso 4: Usar en Ventas (Automático)

```dart
// Usar el nuevo servicio de impresión
final printingService = PrintingService(Supabase.instance.client);

// Al enviar orden a cocina
final jobs = await printingService.sendOrderToKitchen(
  orderId: orderId,
  businessId: businessId,
);

// El sistema automáticamente:
// 1. Agrupa items por departamento
// 2. Crea trabajos de impresión
// 3. Envía a las impresoras correspondientes
```

## 🎨 Interfaz de Usuario

### Pantalla de Configuración

La pantalla `PrinterConfigurationScreen` tiene 3 tabs:

1. **Tab Impresoras**
   - Lista de impresoras registradas
   - Agregar nueva impresora
   - Probar impresora
   - Editar/Eliminar

2. **Tab Áreas**
   - Lista de departamentos
   - Crear nuevas áreas
   - Activar/Desactivar

3. **Tab Asignaciones**
   - Vincular impresoras con áreas
   - Configurar prioridades
   - Configurar tipos de documentos

### Cómo Acceder

```dart
// Navegar a la pantalla de configuración
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (context) => PrinterConfigurationScreen(
      businessId: currentBusinessId,
    ),
  ),
);
```

## 📊 Flujo Completo

```
1. Cliente ordena items
   ↓
2. Sistema identifica área de cada item
   (Hamburguesa → kitchen_hot)
   (Cerveza → bar)
   ↓
3. Al enviar a cocina, se crean PrintJobs
   (1 job por área con items agrupados)
   ↓
4. Sistema busca impresoras asignadas
   ↓
5. Printer Agent procesa jobs
   ↓
6. Tickets impresos en cada departamento
```

## 🔧 Características Avanzadas

### 1. **Redundancia**
```dart
// Asignar múltiples impresoras a la misma área
await linkAreaToPrinter(areaId: kitchen, printerId: printer1, priority: 1);
await linkAreaToPrinter(areaId: kitchen, printerId: printer2, priority: 2);

// Si printer1 falla, automáticamente usa printer2
```

### 2. **Reimpresión por Área**
```dart
// Reimprimir solo en cocina caliente
await printingService.reprintOrderInArea(
  orderId: orderId,
  businessId: businessId,
  areaCode: 'kitchen_hot',
);
```

### 3. **Monitoreo en Tiempo Real**
```dart
// Suscribirse a trabajos de impresión
printingRepo.subscribeToPrintJobs(businessId).listen((jobs) {
  final pending = jobs.where((j) => j.isPending).length;
  final failed = jobs.where((j) => j.isFailed).length;
  
  print('Pendientes: $pending, Fallidos: $failed');
});
```

### 4. **Configuración por Tipo de Documento**
```dart
// Impresora de caja solo para precuentas y recibos
await linkAreaToPrinter(
  areaId: cashierArea,
  printerId: fiscalPrinter,
  printsOrders: false,      // No imprime órdenes
  printsPrebills: true,     // Sí imprime precuentas
  printsReceipts: true,     // Sí imprime recibos
);
```

## 📈 Beneficios

### Operacionales:
- ✅ **Eficiencia**: Cada departamento recibe solo sus items
- ✅ **Velocidad**: Impresión paralela en múltiples impresoras
- ✅ **Organización**: Tickets separados por departamento
- ✅ **Reducción de errores**: Items van al departamento correcto

### Técnicos:
- ✅ **Redundancia**: Múltiples impresoras por área
- ✅ **Failover automático**: Si una falla, usa la siguiente
- ✅ **Reintentos**: Hasta 3 intentos automáticos
- ✅ **Monitoreo**: Vista en tiempo real de trabajos

### Escalabilidad:
- ✅ **Flexible**: Agregar nuevas áreas fácilmente
- ✅ **Configurable**: Personalizar por negocio
- ✅ **Extensible**: Soporta nuevos tipos de documentos

## 🎯 Casos de Uso

### Restaurante Pequeño
```
Áreas: kitchen, cashier
Impresoras: 2 (1 cocina, 1 caja)
```

### Restaurante Mediano
```
Áreas: kitchen_hot, kitchen_cold, bar, cashier
Impresoras: 4-5 (con redundancia en cocina)
```

### Restaurante Grande
```
Áreas: kitchen_hot, kitchen_cold, bar, grill, desserts, cashier, fiscal
Impresoras: 8-10 (múltiples por área crítica)
```

## 🔍 Troubleshooting

### Problema: Items no se imprimen en el área correcta
**Solución**: Verificar que los items del menú tengan `print_area_code` asignado
```sql
SELECT id, name, print_area_code FROM menu_items WHERE print_area_code IS NULL;
```

### Problema: Área no tiene impresoras
**Solución**: Asignar al menos una impresora al área
```dart
await printingRepo.linkAreaToPrinter(...);
```

### Problema: Trabajos quedan pendientes
**Solución**: Verificar que el Printer Agent esté corriendo y que las impresoras estén encendidas

## 📚 Recursos Adicionales

- **Guía Completa**: `GUIA_IMPRESION_DEPARTAMENTOS.md`
- **Script SQL**: `database/setup_printing_departments.sql`
- **Código de Servicio**: `lib/data/repositories/printing_service.dart`
- **UI de Configuración**: `lib/presentation/settings/screens/printer_configuration_screen.dart`

## 🎉 Conclusión

El sistema de impresión por departamentos está **completamente implementado** y listo para usar. Solo necesitas:

1. ✅ Ejecutar el script SQL
2. ✅ Configurar tus impresoras
3. ✅ Asignar impresoras a áreas
4. ✅ ¡Empezar a usarlo!

**El sistema ya maneja automáticamente la agrupación y enrutamiento de órdenes a las impresoras correctas.** 🚀

---

**¿Necesitas ayuda?** Revisa la guía completa o pregunta cualquier duda sobre la implementación.
