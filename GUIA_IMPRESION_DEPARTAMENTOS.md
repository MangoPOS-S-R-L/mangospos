# 🖨️ Guía de Configuración de Impresión por Departamentos - MangoPos

## 📋 Resumen del Sistema

Tu sistema MangoPos ya tiene una arquitectura robusta para impresión por departamentos. Aquí te explico cómo funciona y cómo configurarlo.

## 🏗️ Arquitectura del Sistema de Impresión

### Componentes Principales:

1. **PrinterConfig** - Configuración de impresoras físicas
   - IP, puerto, tipo (red/USB/Bluetooth)
   - Estado activo/inactivo
   - Ancho de papel, codificación

2. **PrintArea** - Áreas/Departamentos de impresión
   - Ejemplos: `kitchen_hot`, `kitchen_cold`, `bar`, `cashier`, `fiscal`
   - Cada área representa un departamento

3. **PrintAreaPrinter** - Asignación de impresoras a áreas
   - Vincula una impresora con un área
   - Prioridad para múltiples impresoras en la misma área

4. **PrintJob** - Trabajos de impresión
   - Cola de impresión
   - Tipos: `kitchen_order`, `precheck`, `fiscal_invoice`, `cash_close`

## 🎯 Flujo de Impresión por Departamento

```
1. Cliente ordena items
   ↓
2. Sistema identifica departamento de cada item
   (Ej: Hamburguesa → kitchen_hot, Cerveza → bar)
   ↓
3. Se crean PrintJobs por departamento
   ↓
4. Sistema busca impresoras asignadas a cada área
   ↓
5. Se envía a imprimir a las impresoras correspondientes
```

## 📊 Estructura de Base de Datos

### Tabla: `printers`
```sql
CREATE TABLE printers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id),
  name TEXT NOT NULL,
  type TEXT NOT NULL, -- 'network', 'usb', 'bluetooth'
  ip_address TEXT,
  port INTEGER,
  device_path TEXT,
  is_active BOOLEAN DEFAULT true,
  paper_width INTEGER DEFAULT 80,
  encoding TEXT DEFAULT 'CP437',
  created_at TIMESTAMPTZ DEFAULT now()
);
```

### Tabla: `print_areas`
```sql
CREATE TABLE print_areas (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id),
  name TEXT NOT NULL, -- 'Cocina Caliente', 'Bar', etc.
  code TEXT NOT NULL, -- 'kitchen_hot', 'bar', etc.
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(business_id, code)
);
```

### Tabla: `print_area_printers`
```sql
CREATE TABLE print_area_printers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id UUID REFERENCES print_areas(id) ON DELETE CASCADE,
  printer_id UUID REFERENCES printers(id) ON DELETE CASCADE,
  priority INTEGER DEFAULT 1, -- Mayor número = mayor prioridad
  enabled BOOLEAN DEFAULT true,
  prints_orders BOOLEAN DEFAULT true,
  prints_prebills BOOLEAN DEFAULT false,
  prints_receipts BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(area_id, printer_id)
);
```

### Tabla: `print_jobs`
```sql
CREATE TABLE print_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES businesses(id),
  area_id UUID REFERENCES print_areas(id),
  order_id UUID REFERENCES orders(id),
  check_id UUID REFERENCES order_checks(id),
  type TEXT NOT NULL, -- 'kitchen_order', 'precheck', 'fiscal_invoice'
  status TEXT DEFAULT 'pending', -- 'pending', 'printing', 'printed', 'failed'
  data JSONB NOT NULL,
  printer_id UUID REFERENCES printers(id),
  retry_count INTEGER DEFAULT 0,
  error_message TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  printed_at TIMESTAMPTZ
);
```

## 🔧 Configuración Paso a Paso

### Paso 1: Crear Áreas de Impresión (Departamentos)

```dart
// Ejemplo de código para crear áreas
final printingRepo = PrintingRepository(Supabase.instance.client);

// Crear área de cocina caliente
await printingRepo.createArea(
  businessId: 'tu-business-id',
  name: 'Cocina Caliente',
  code: 'kitchen_hot',
);

// Crear área de cocina fría
await printingRepo.createArea(
  businessId: 'tu-business-id',
  name: 'Cocina Fría',
  code: 'kitchen_cold',
);

// Crear área de bar
await printingRepo.createArea(
  businessId: 'tu-business-id',
  name: 'Bar',
  code: 'bar',
);

// Crear área de caja
await printingRepo.createArea(
  businessId: 'tu-business-id',
  name: 'Caja',
  code: 'cashier',
);
```

### Paso 2: Registrar Impresoras

```dart
// Impresora de red para cocina caliente
final printer1 = await printingRepo.createPrinter(
  businessId: 'tu-business-id',
  name: 'Impresora Cocina 1',
  type: 'network',
  ipAddress: '192.168.1.100',
  port: 9100,
  paperWidth: 80,
);

// Impresora para bar
final printer2 = await printingRepo.createPrinter(
  businessId: 'tu-business-id',
  name: 'Impresora Bar',
  type: 'network',
  ipAddress: '192.168.1.101',
  port: 9100,
  paperWidth: 80,
);

// Impresora fiscal para caja
final printer3 = await printingRepo.createPrinter(
  businessId: 'tu-business-id',
  name: 'Impresora Fiscal',
  type: 'network',
  ipAddress: '192.168.1.102',
  port: 9100,
  paperWidth: 80,
);
```

### Paso 3: Asignar Impresoras a Áreas

```dart
// Obtener IDs de áreas
final areas = await printingRepo.getPrintAreas('tu-business-id');
final kitchenHotArea = areas.firstWhere((a) => a.code == 'kitchen_hot');
final barArea = areas.firstWhere((a) => a.code == 'bar');
final cashierArea = areas.firstWhere((a) => a.code == 'cashier');

// Asignar impresora a cocina caliente
await printingRepo.linkAreaToPrinter(
  businessId: 'tu-business-id',
  areaId: kitchenHotArea.id,
  printerId: printer1, // ID de la impresora
  enabled: true,
  printsOrders: true,      // Imprime órdenes de cocina
  printsPrebills: false,   // No imprime precuentas
  printsReceipts: false,   // No imprime recibos
  priority: 1,
);

// Asignar impresora a bar
await printingRepo.linkAreaToPrinter(
  businessId: 'tu-business-id',
  areaId: barArea.id,
  printerId: printer2,
  enabled: true,
  printsOrders: true,
  printsPrebills: false,
  printsReceipts: false,
  priority: 1,
);

// Asignar impresora fiscal a caja
await printingRepo.linkAreaToPrinter(
  businessId: 'tu-business-id',
  areaId: cashierArea.id,
  printerId: printer3,
  enabled: true,
  printsOrders: false,     // No imprime órdenes
  printsPrebills: true,    // Imprime precuentas
  printsReceipts: true,    // Imprime recibos
  priority: 1,
);
```

### Paso 4: Configurar Items del Menú con Áreas

Necesitas asignar cada item del menú a un área de impresión:

```dart
// En tu tabla menu_items, agrega el campo area_code
// O crea una tabla de relación menu_item_print_areas

// Ejemplo en SQL:
ALTER TABLE menu_items ADD COLUMN print_area_code TEXT;

UPDATE menu_items 
SET print_area_code = 'kitchen_hot' 
WHERE category_id IN (SELECT id FROM categories WHERE name IN ('Carnes', 'Pastas'));

UPDATE menu_items 
SET print_area_code = 'kitchen_cold' 
WHERE category_id IN (SELECT id FROM categories WHERE name IN ('Ensaladas', 'Postres'));

UPDATE menu_items 
SET print_area_code = 'bar' 
WHERE category_id IN (SELECT id FROM categories WHERE name IN ('Bebidas', 'Cocteles'));
```

### Paso 5: Crear Trabajos de Impresión al Enviar Orden

```dart
// Cuando se envía una orden a cocina
Future<void> sendOrderToKitchen(String orderId) async {
  // 1. Obtener items de la orden
  final items = await salesRepo.getOrderItems(orderId);
  
  // 2. Agrupar items por área de impresión
  final itemsByArea = <String, List<OrderItem>>{};
  
  for (final item in items) {
    final areaCode = item.printAreaCode ?? 'kitchen_hot'; // Default
    if (!itemsByArea.containsKey(areaCode)) {
      itemsByArea[areaCode] = [];
    }
    itemsByArea[areaCode]!.add(item);
  }
  
  // 3. Crear un PrintJob por cada área
  for (final entry in itemsByArea.entries) {
    final areaCode = entry.key;
    final areaItems = entry.value;
    
    // Obtener área
    final areas = await printingRepo.getPrintAreas(businessId);
    final area = areas.firstWhere((a) => a.code == areaCode);
    
    // Crear trabajo de impresión
    await printingRepo.createPrintJob(
      businessId: businessId,
      areaId: area.id,
      type: 'kitchen_order',
      orderId: orderId,
      data: {
        'items': areaItems.map((i) => {
          'name': i.itemName,
          'quantity': i.quantity,
          'notes': i.notes,
          'modifiers': i.modifiers,
        }).toList(),
        'table': tableName,
        'waiter': waiterName,
        'orderNumber': orderNumber,
      },
    );
  }
}
```

## 🎨 Interfaz de Usuario - Pantalla de Configuración

Voy a crear una pantalla de ejemplo para configurar impresoras y áreas:

### Características de la UI:

1. **Lista de Áreas de Impresión**
   - Ver todas las áreas configuradas
   - Crear nuevas áreas
   - Editar/eliminar áreas

2. **Lista de Impresoras**
   - Ver impresoras registradas
   - Agregar nuevas impresoras
   - Probar impresoras
   - Ver estado (activa/inactiva)

3. **Asignación de Impresoras a Áreas**
   - Drag & drop para asignar
   - Configurar prioridades
   - Configurar qué tipos de documentos imprime cada impresora

4. **Vista de Trabajos de Impresión**
   - Cola de impresión en tiempo real
   - Reintentar trabajos fallidos
   - Ver historial

## 🔍 Debugging y Monitoreo

### Ver trabajos pendientes:

```dart
final pendingJobs = await printingRepo.getPendingJobs(businessId);

for (final job in pendingJobs) {
  print('Job: ${job.type}');
  print('Area: ${job.areaId}');
  print('Status: ${job.status}');
  print('Retry count: ${job.retryCount}');
}
```

### Suscribirse a nuevos trabajos:

```dart
final jobsStream = printingRepo.subscribeToPrintJobs(businessId);

jobsStream.listen((jobs) {
  print('Nuevos trabajos de impresión: ${jobs.length}');
  // Procesar trabajos...
});
```

## 🚀 Mejores Prácticas

1. **Redundancia**: Asigna múltiples impresoras a áreas críticas
   ```dart
   // Impresora principal
   await linkAreaToPrinter(areaId: kitchenId, printerId: printer1, priority: 1);
   
   // Impresora de respaldo
   await linkAreaToPrinter(areaId: kitchenId, printerId: printer2, priority: 2);
   ```

2. **Reintentos Automáticos**: El sistema ya maneja reintentos
   - Si una impresora falla, intenta con la siguiente en prioridad
   - Máximo 3 reintentos por trabajo

3. **Monitoreo en Tiempo Real**: Usa streams para monitorear
   ```dart
   printingRepo.subscribeToPrintJobs(businessId).listen((jobs) {
     final failed = jobs.where((j) => j.isFailed);
     if (failed.isNotEmpty) {
       // Notificar al administrador
       showNotification('${failed.length} trabajos de impresión fallidos');
     }
   });
   ```

4. **Configuración por Tipo de Documento**:
   - Órdenes de cocina → Solo impresoras de cocina
   - Precuentas → Impresoras de caja
   - Facturas fiscales → Solo impresora fiscal

## 📱 Ejemplo de Flujo Completo

```dart
// 1. Cliente ordena
final order = await salesRepo.openTable(tableId: 'mesa-1');

// 2. Agregar items
await salesRepo.addItemFromMenu(
  orderId: order.id,
  menuItemId: 'hamburguesa-id', // area_code: 'kitchen_hot'
);

await salesRepo.addItemFromMenu(
  orderId: order.id,
  menuItemId: 'cerveza-id', // area_code: 'bar'
);

// 3. Enviar a cocina (esto crea los PrintJobs automáticamente)
await salesRepo.sendToKitchen(order.id);

// El sistema automáticamente:
// - Agrupa items por área (kitchen_hot, bar)
// - Crea PrintJob para cada área
// - Busca impresoras asignadas a cada área
// - Envía a imprimir
```

## 🎯 Próximos Pasos

1. **Crear pantalla de configuración** (ver archivo siguiente)
2. **Implementar lógica de agrupación por área** en sendToKitchen
3. **Configurar impresoras físicas** en tu red
4. **Asignar áreas a items del menú**
5. **Probar flujo completo**

---

**Nota**: El siguiente archivo contiene el código completo de la pantalla de configuración de impresión.
