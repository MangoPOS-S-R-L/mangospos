# Sistema de Roles y Permisos - MangoPOS

## Descripción General

Este sistema implementa un control de acceso basado en roles (RBAC) completo para MangoPOS, permitiendo gestionar usuarios, roles y permisos de manera granular.

## Estructura de Archivos

1. **roles_permissions_schema.sql** - Schema completo de tablas
2. **insert_base_roles.sql** - Roles predefinidos del sistema
3. **roles_usuarios_mangopos.txt** - Documentación de permisos
4. **usuarios_gestion_spec.txt** - Especificación de UI

## Orden de Ejecución

### 1. Crear el Schema (Primera vez)

Ejecutar en Supabase SQL Editor:

```sql
-- Ejecutar todo el contenido de roles_permissions_schema.sql
```

Este script creará:
- ✅ Tabla `employees` - Empleados del negocio
- ✅ Tabla `roles` - Roles configurables
- ✅ Tabla `permissions` - Catálogo de permisos
- ✅ Tabla `role_permissions` - Permisos por rol
- ✅ Tabla `employee_roles` - Roles por empleado (multi-rol)
- ✅ Tabla `user_permission_overrides` - Excepciones de permisos
- ✅ Tabla `employee_benefits` - Beneficios de empleados
- ✅ Tabla `employee_deductions` - Deducciones (AFP, ARS)
- ✅ Tabla `audit_logs` - Auditoría de acciones críticas
- ✅ Vista `v_employees_summary` - Resumen de empleados con roles
- ✅ Función `get_employee_permissions()` - Obtener permisos de un empleado
- ✅ Políticas RLS para seguridad

### 2. Insertar Roles Base

Antes de ejecutar `insert_base_roles.sql`:

1. **Obtener el business_id** de tu negocio:
   ```sql
   SELECT id, business_name FROM businesses;
   ```

2. **Reemplazar** `{business_id}` en el script con el ID real

3. **Ejecutar** el script completo

Esto creará 6 roles predefinidos:
- **Administrador** - Todos los permisos
- **Supervisor** - Ventas, pagos, caja, reportes, anulaciones
- **Cajero** - Cobros, caja, ventas rápidas
- **Mesero** - Mesas, órdenes, split
- **Cocina** - Solo KDS
- **Delivery** - Órdenes de delivery

## Catálogo de Permisos

### Módulos Principales

#### 1. Configuración (settings)
- `settings.usuarios.*` - Gestión de usuarios
- `settings.roles.*` - Gestión de roles
- `settings.impresoras.gestionar` - Configurar impresoras
- `settings.zonas_mesas.gestionar` - Configurar zonas y mesas
- `settings.impuestos_fiscal.gestionar` - ITBIS, NCF
- `settings.metodos_pago.gestionar` - Métodos de pago
- `settings.kds.gestionar` - Configurar KDS

#### 2. Ventas por Salón (ventas)
- `ventas.mesas.*` - Gestión de mesas
- `ventas.orden.*` - Gestión de órdenes
- `ventas.cuenta.*` - Split de cuentas

#### 3. Venta Rápida (ventas_rapida)
- `ventas_rapida.acceso` - Acceso al módulo
- `ventas_rapida.crear_orden` - Crear órdenes
- `ventas_rapida.cobrar_inmediato` - Cobro inmediato

#### 4. Pagos y Caja (pagos, caja)
- `pagos.*` - Procesar pagos
- `caja.*` - Apertura, cierre, arqueo

#### 5. KDS/Cocina (kds)
- `kds.acceso` - Acceso a pantalla de cocina
- `kds.ver_comandas` - Ver órdenes
- `kds.cambiar_estado` - Cambiar estado de preparación

#### 6. Reportes (reportes)
- `reportes.ventas` - Reporte de ventas
- `reportes.caja` - Reporte de caja
- `reportes.fiscales` - Reportes fiscales
- `reportes.auditoria` - Auditoría de acciones

#### 7. Clientes y Delivery (clientes, delivery)
- `clientes.*` - Gestión de clientes
- `delivery.*` - Gestión de entregas

#### 8. Inventario y Compras (inventario, compras)
- `inventario.*` - Gestión de inventario
- `compras.*` - Órdenes de compra

## Uso en la Aplicación

### 1. Crear un Empleado

```dart
final employee = await employeeRepo.createEmployee(
  businessId: businessId,
  firstName: 'Juan',
  lastName: 'Pérez',
  email: 'juan@example.com',
  phone: '8091234567',
  department: 'Servicio/Salón',
  position: 'Mesero',
  salaryBase: 25000,
  payFrequency: 'Quincenal',
  roleIds: [meseroRoleId], // ID del rol Mesero
);
```

### 2. Asignar Roles a un Empleado

```sql
-- Asignar múltiples roles
INSERT INTO employee_roles (employee_id, role_id)
VALUES 
  ('employee-uuid', 'mesero-role-uuid'),
  ('employee-uuid', 'cajero-role-uuid');
```

### 3. Verificar Permisos

```sql
-- Obtener todos los permisos de un empleado
SELECT * FROM get_employee_permissions('employee-uuid');

-- Verificar si tiene un permiso específico
SELECT EXISTS (
  SELECT 1 
  FROM get_employee_permissions('employee-uuid')
  WHERE permission_code = 'ventas.orden.anular'
);
```

### 4. Registrar Auditoría

```sql
INSERT INTO audit_logs (
  business_id,
  employee_id,
  action,
  reason,
  ref_id,
  ref_type,
  metadata
) VALUES (
  'business-uuid',
  'employee-uuid',
  'anular_venta',
  'Cliente solicitó cancelación',
  'order-uuid',
  'order',
  '{"order_number": "ORD-001", "total": 1500}'::jsonb
);
```

## Gestión de Roles desde la UI

### Crear un Rol Personalizado

1. Ir a **Configuración** → **Gestionar Roles**
2. Clic en **Nuevo Rol**
3. Ingresar nombre y descripción
4. Seleccionar permisos por módulo:
   - **Acceso** - Puede entrar al módulo
   - **Ver** - Puede ver datos
   - **Graba/Modifica** - Puede crear/editar
   - **Anula** - Puede anular (requiere motivo)
   - **Reimprime** - Puede reimprimir documentos
5. Guardar rol

### Asignar Roles a Usuarios

1. Ir a **Configuración** → **Gestión de Usuarios**
2. Editar usuario
3. En la pestaña **Roles**, seleccionar uno o más roles
4. Guardar cambios

## Reglas de Negocio

### Acciones que Requieren Motivo
- Anular venta (`ventas.orden.anular`)
- Reabrir orden (`ventas.orden.reabrir`)
- Anular pago (`pagos.anular_pago`)
- Reimprimir recibo (`pagos.reimprimir_recibo`)
- Reimprimir comanda (`kds.reimprimir_comanda`)

### Acciones que Requieren Supervisor
- Anular ventas mayores a cierto monto
- Aplicar descuentos mayores al X%
- Modificar precios
- Reabrir órdenes cerradas

### Restricciones por Rol
- **Cocina**: No ve precios en KDS
- **Mesero**: No puede cobrar, solo preparar cuentas
- **Cajero**: No puede anular sin supervisor
- **Delivery**: Solo ve sus órdenes asignadas

## Consultas Útiles

### Ver todos los roles y sus permisos
```sql
SELECT 
  r.name as rol,
  p.module as modulo,
  p.name as permiso,
  p.code as codigo
FROM roles r
JOIN role_permissions rp ON rp.role_id = r.id
JOIN permissions p ON p.id = rp.permission_id
WHERE r.business_id = 'your-business-id'
ORDER BY r.name, p.module, p.name;
```

### Ver empleados con sus roles
```sql
SELECT 
  e.first_name || ' ' || e.last_name as nombre,
  e.email,
  e.department,
  e.position,
  json_agg(r.name) as roles
FROM employees e
LEFT JOIN employee_roles er ON er.employee_id = e.id
LEFT JOIN roles r ON r.id = er.role_id
WHERE e.business_id = 'your-business-id'
GROUP BY e.id, e.first_name, e.last_name, e.email, e.department, e.position;
```

### Auditoría de acciones críticas
```sql
SELECT 
  al.created_at,
  e.first_name || ' ' || e.last_name as empleado,
  al.action,
  al.reason,
  al.ref_type,
  al.metadata
FROM audit_logs al
LEFT JOIN employees e ON e.id = al.employee_id
WHERE al.business_id = 'your-business-id'
  AND al.action IN ('anular_venta', 'reimprimir', 'reabrir_orden')
ORDER BY al.created_at DESC
LIMIT 100;
```

## Extensiones Futuras

- [ ] Permisos temporales (ventana de tiempo)
- [ ] Permisos por sucursal
- [ ] Webhooks para alertas de acciones críticas
- [ ] Dashboard de auditoría en tiempo real
- [ ] Aprobaciones de dos pasos para acciones críticas
- [ ] Límites de descuento por rol
- [ ] Restricciones por horario

## Soporte

Para más información, consultar:
- `roles_usuarios_mangopos.txt` - Documentación completa de permisos
- `usuarios_gestion_spec.txt` - Especificación de UI
