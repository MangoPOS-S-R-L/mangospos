# AUDIT_REPORT.md — Reporte de Auditoría Full-Stack
> Generado: 2026-02-24 | Auditor: Antigravity AI | Proyecto: MangoPOS (Flutter + Supabase)

---

## CONTEXTO DEL AUDIT

Este proyecto experimentó una **migración completa** de tecnología:

- **Originen (Lovable/React):** Prototipo UI con ~70 pantallas, todo mock, sin backend real.
- **Estado actual (Flutter + Supabase):** Reescritura parcial con arquitectura MVVM + Riverpod. Algunos módulos tienen backend real conectado; otros son esqueletos vacíos.

Los documentos en `/docs` describen exclusivamente el prototipo React original. El código Flutter actual es **más avanzado en algunos módulos** y **completamente inexistente en otros**.

---

## 1. MÓDULOS QUE EXISTEN SOLO VISUALMENTE

### 1.1 Dashboard (`/lib/presentation/dashboard/dashboard_view.dart`) — 46KB
- **Estado:** Pantalla enorme con data hardcodeada.
- **Evidencia:** No existe `dashboard_repository.dart`. No hay llamadas a Supabase en el dashboard.
- **Riesgo:** Estadísticas de ventas, mesas activas y gráficos muestran datos ficticios.

### 1.2 Módulo de Reportes (`/lib/presentation/reports/`)
- **Estado:** Estructura MVC existe (view, viewmodel, state), pero `reports_repository.dart` es un **archivo vacío (0 bytes)**.
- **Riesgo CRÍTICO:** El módulo de reportes no puede funcionar. No hay queries definidas.

### 1.3 Módulo de Inventario (`/lib/presentation/inventory/`)
- **Estado:** Estructura MVC existe, pero **no hay repositorio ni datasource** para inventario en `/lib/data/repositories/`.
- **Riesgo CRÍTICO:** Todo el módulo de inventario (kardex, salidas, transferencias, cuadre de stock, mermas) es UI sin backend.

### 1.4 Módulo de Clientes (`/lib/presentation/customers/`)
- **Estado:** `customers_repository.dart` existe (1.3KB). `customers_queries.dart` está **vacío (0 bytes)**.
- **Riesgo:** Repositorio sin queries funcionales.

### 1.5 Módulo de Compras (`/lib/presentation/purchases/`)
- **Estado:** Módulo de presentación existe. No hay repositorio de compras en `/lib/data/repositories/`.
- **Riesgo CRÍTICO:** Proveedores, órdenes de compra, registro de compras — sin backend.

### 1.6 Módulo de Promos (`/lib/presentation/promos/`)
- **Estado:** Directorio existe (3 archivos). No hay repositorio para promociones/cupones/gift cards.
- **Riesgo:** Sin backend para descuentos, cupones ni membresías.

### 1.7 Módulo de Settings (múltiples pantallas)
- **Estado:** `/lib/presentation/settings/` contiene `more settings/` con 27 subdirectorios. No hay repositorios dedicados para: turnos, monedas, configuración regional, opciones de sistema, ni info de restaurante.
- **Riesgo:** Toda la configuración del sistema se pierde al cerrar la app.

---

## 2. MÓDULOS SIN LÓGICA REAL

### 2.1 Productos (`/lib/presentation/products/`)
- **Estado:** Estructura MVVM existe. `products_repository.dart` es un **archivo vacío (0 bytes)**. `products_queries.dart` también vacío.
- **Impacto:** El catálogo de productos (creación, edición, categorías, menús, modificadores) no persiste.

### 2.2 Printing (`/lib/presentation/printing/`)
- **Estado:** Existen servicios de impresión (`escpos_ticket_service.dart`, `print_manager.dart`, `usb_printer_manager.dart`). Sin embargo, `printer-services/` tiene solo 1 archivo y la integración con el flujo de ventas no está completa.
- **Riesgo:** La impresión de comandas y recibos puede fallar en casos borde.

### 2.3 Branches (`/lib/presentation/branches/`) — 3 archivos
- **Estado:** Multi-sucursal sin repositorio en data layer.
- **Riesgo:** No hay filtro por sucursal en ningún dato del sistema.

---

## 3. PANTALLAS SIN CONEXIÓN A DATOS REALES

| Pantalla | Módulo Flutter | Estado |
|----------|----------------|--------|
| Dashboard | `dashboard_view.dart` | Hardcodeado |
| Reportes | `reports/view/` | Repositorio vacío |
| Inventario (Kardex, Salidas, Mermas, etc.) | `inventory/view/` | Sin repositorio |
| Productos (CRUD) | `products/view/` | Repositorio vacío |
| Compras / Proveedores | `purchases/view/` | Sin repositorio |
| Clientes | `customers/` | Queries vacías |
| Promos / Cupones / Gift Cards | `promos/view/` | Sin repositorio |
| Settings (Turnos, Monedas, Regionales) | `settings/more settings/` | Sin repositorio |
| Impresoras (configuración) | `printing/` | Integración parcial |

---

## 4. LÓGICA SIMULADA (MOCK)

### 4.1 Facturación Fiscal — MOCK en Supabase
```sql
-- En create_fiscal_document() del schema.sql (línea 536):
'B02', 'B0200000001', -- MOCK
```
**Crítico:** La función `create_fiscal_document` en Supabase usa un NCF hardcodeado `B0200000001`. No existe lógica real de secuencias NCF-DGII.

### 4.2 Cierre de Caja — Diferencia no calculada correctamente
```dart
// cashier_repository_new.dart línea 99:
'difference': endAmount - 0, // Se calcula en el trigger
```
La diferencia se calcula como `endAmount - 0`. Aunque existe un trigger `fn_close_cash_session` en el schema, el código Flutter no lo llama correctamente — usa `update` directo en lugar del RPC `fn_close_cash_session`.

### 4.3 Inventario de Stock — Sin consumo automático real
La función `consume_inventory_from_order` existe en el schema pero **no es invocada** desde ningún repositorio Flutter. El consumo de inventario al procesar pagos **no ocurre**.

### 4.4 Rol fallback — Seguridad
```dart
// login_viewmodel.dart línea 83:
posRole = PosRole.administrador; // Fallback
```
Si `user_businesses` no retorna registros, el usuario obtiene **rol de Administrador** por defecto. Esto es un riesgo de seguridad crítico.

### 4.5 Resolución de businessId
En `sales_repository.dart` y varias partes del código, se usa `resolveBusinessIdOrNull(_client, 'auto')`. Si esta función falla o retorna null, los errores son silenciados en algunos lugares.

---

## 5. DEPENDENCIAS ROTAS

| Dependencia | Descripción |
|------------|-------------|
| `products_repository.dart` → vacío | El viewmodel de productos no puede persistir datos |
| `reports_repository.dart` → vacío | El módulo de reportes está completamente roto |
| `customers_queries.dart` → vacío | Clientes no puede hacer queries |
| `cashier_queries.dart` → vacío | Caja puede fallar en queries específicas |
| `kitchen_queries.dart` → vacío | KDS depende de lógica inline |
| `reservations_repository.dart` → vacío | Reservaciones sin soporte |
| `ProductsContext` → desacoplado de backend | Productos admin y catálogo de ventas son fuentes separadas |
| `RPC fn_start_preparing_order` | KitchenRepository la llama pero el schema no la muestra explícitamente |
| `RPC fn_mark_order_ready` | KitchenRepository la llama pero el schema no la muestra explícitamente |

---

## 6. INCONSISTENCIAS DE NAMING

| Código Flutter | Supabase Schema | Inconsistencia |
|----------------|-----------------|----------------|
| `user_businesses` | `memberships` + `user_businesses` | Dos tablas para la misma relación |
| `profiles` tabla | Supabase usa `profiles` (estándar) | OK pero la query no incluye `business_id` |
| `dining_tables` | Docs llaman `tables` | Renombre no documentado |
| `status_ext` (orders) | `order_status` enum | Campo `status_ext` usa el enum pero `status` es `text` |
| `OrderItem.qty` vs `quantity` | Ambos campos existen en schema | Duplicación en `order_items` (qty + quantity) |
| `PosRole.delivery` | Enum `user_role` tiene `delivery` | OK |
| `PosRole.cocina` | Enum `user_role` tiene `cook` | Inconsistencia: Flutter dice `cocina`, DB dice `cook` |
| `member_role` enum | `user_role` enum | DOS enums distintos para roles en el mismo schema |
| `cash_register_sessions` | Docs decían `cash_shifts` | Renombre no reflejado en docs |

---

## 7. ESTADOS IMPOSIBLES

### 7.1 Mesa sin sesión pero con orden
- `dining_tables.state = 'occupied'` puede existir sin `table_sessions` activa si el RPC `fn_close_order_and_table` falla silenciosamente.

### 7.2 Pago registrado sin orden cerrada
- `_processPaymentDirect` inserta en `payments` y luego llama `fn_close_order_and_table`. Si el RPC falla, existe el pago pero la orden sigue "abierta" y la mesa "ocupada".

### 7.3 Check cerrado sin pago registrado
- `clearCheck()` en `sales_repository.dart` marca items como `paid` y el check como `closed` antes de verificar si existe un pago. No hay rollback transaccional.

### 7.4 Usuario sin businessId
- Login puede completarse con `businessId = null` si `user_businesses` está vacío. La sesión se establece pero todas las queries posteriores fallarán.

### 7.5 Cierre de caja con diferencia `endAmount - 0`
- Si se llama `closeCashRegisterSession` directamente (no via RPC), la diferencia siempre es `endAmount` (se resta 0), reportando una diferencia falsa.

---

## 8. RIESGOS ESTRUCTURALES

| Riesgo | Nivel | Descripción |
|--------|-------|-------------|
| Sin transacciones atómicas en Flutter | 🔴 CRÍTICO | Los RPCs de Supabase son atómicos, pero los métodos directos (`_processPaymentDirect`) tienen múltiples pasos sin rollback |
| `sales_repository_improved.dart` coexiste con `sales_repository.dart` | 🟡 ALTO | Dos implementaciones del mismo repositorio. ¿Cuál se usa? |
| `cashier_repository.dart` Y `cashier_repository_new.dart` | 🟡 ALTO | Dos implementaciones de caja. Riesgo de uso inconsistente |
| Sin manejo de concurrencia en mesas | 🟡 ALTO | Dos cajeros pueden abrir la misma mesa simultáneamente |
| Subscribe a `order_items` stream sin filtro por business_id | 🟡 ALTO | El KDS puede recibir items de otros negocios si el RLS falla |
| `kds_active_items` es una vista | 🟡 ALTO | No se ha verificado si esta vista existe en el schema exportado |
| Real-time solo en KDS | 🟡 ALTO | Mesas y caja no tienen suscripciones en tiempo real |
| Sin offline mode | 🟡 ALTO | POS sin internet = sistema completamente no funcional |
| NCF MOCK en producción | 🔴 CRÍTICO | Documentos fiscales con número fijo `B0200000001` |
| Rol Admin como fallback de login | 🔴 CRÍTICO | Seguridad comprometida si `user_businesses` falla |

---

## 9. FALTA DE VALIDACIONES

| Área | Validación faltante |
|------|--------------------|
| Login | No valida `email format` antes de enviar a Supabase |
| Apertura de caja | No valida si ya existe sesión activa del mismo usuario |
| Pago | No valida que el monto sea > 0 en el repositorio (solo en UI) |
| Creación de orden | No valida que la mesa esté disponible antes de abrir sesión |
| Productos | `products_repository.dart` vacío — sin validación posible |
| Multi-negocio | No valida que el `businessId` del usuario coincida con el negocio activo |
| Stock | No valida stock disponible antes de confirmar pedido |
| Cierre de caja | No valida que no haya órdenes abiertas antes de cerrar |
| Impresoras | No valida conectividad antes de intentar imprimir |
| Zonas/Mesas | No valida que la zona pertenezca al negocio del usuario |

---

## 10. FALTA DE MANEJO DE ERRORES

| Ubicación | Error no manejado |
|-----------|-------------------|
| `sales_repository.dart` → `deleteItem()` | Silencia el error del RPC con catch vacío `catch (_)` |
| `cashier_repository_new.dart` → `closeCashRegisterSession()` | No maneja el caso donde la sesión ya está cerrada |
| `kitchen_repository.dart` → `subscribeToKitchenItems()` | El stream no tiene manejo de reconexión ante error |
| `login_viewmodel.dart` | `TimeoutException` capturado pero sin timeout configurado en la llamada |
| `_processPaymentDirect()` | Paso 6 (cash_transactions) silencia errores: `catch (_) {}` |
| `getActiveSessions()` | Si `table_sessions` no existe o hay error de RLS, el error propaga sin mensaje útil |
| Todos los repositories | Patrón `throw Exception('Error al X: $e')` pierde el stack trace original |

---

## 11. PROBLEMAS DE SEGURIDAD

| Severidad | Problema | Ubicación |
|-----------|----------|-----------|
| 🔴 CRÍTICO | Rol Admin asignado como fallback si `user_businesses` está vacío | `login_viewmodel.dart:83` |
| 🔴 CRÍTICO | NCF hardcodeado en función de producción | `schema.sql:536` |
| 🟡 ALTO | `create_fiscal_document` usa `LIMIT 1` para obtener business_id sin filtrar por usuario | `schema.sql:537` |
| 🟡 ALTO | `current_user_business_ids()` hace UNION de `memberships` + `user_businesses` — modelo de autorización dual inconsistente | `schema.sql:553` |
| 🟡 ALTO | `fn_add_item_from_menu`, `fn_confirm_order_to_kitchen`, `fn_close_order_and_table` son SECURITY DEFINER sin validar que el usuario pertenece al negocio | `schema.sql` |
| 🟡 ALTO | `agent_claim_next_job` y `agent_report_result` usan `crypt()` para autenticación de agente — si se filtra `api_key_hash` hay vulnerabilidad | `schema.sql:234` |
| 🟡 MEDIO | Sin rate limiting en login desde el cliente Flutter | `login_viewmodel.dart` |
| 🟡 MEDIO | Stream KDS no filtra por `business_id` en `.inFilter('status', [...])` | `kitchen_repository.dart:174` |
| 🟡 MEDIO | `row_security = off` en el header del schema.sql | `schema.sql:14` — solo afecta la sesión de importación, pero sugiere que RLS puede no estar activo en todas las tablas |

---

## RESUMEN EJECUTIVO

| Dimensión | Estado |
|-----------|--------|
| **Autenticación** | ✅ Real (email/password Supabase) — con vulnerabilidad de fallback de rol |
| **Ventas / Orden** | ✅ Real y funcional — con riesgos de atomicidad |
| **Caja** | ⚠️ Parcial — apertura/cierre funcional, cálculo de diferencia incorrecto |
| **KDS / Cocina** | ✅ Funcional con real-time limitado |
| **Productos (Admin)** | ❌ Repositorio vacío |
| **Inventario** | ❌ Sin repositorio |
| **Reportes** | ❌ Repositorio vacío |
| **Clientes** | ❌ Queries vacías |
| **Compras / Proveedores** | ❌ Sin repositorio |
| **Fiscal / NCF** | ❌ Mock hardcodeado |
| **Promos / Fidelidad** | ❌ Sin repositorio |
| **Multi-sucursal** | ❌ Sin implementación |
| **Impresión** | ⚠️ Servicios existen, integración incompleta |
| **Tiempo real** | ⚠️ Solo KDS — mesas y caja sin real-time |
| **Seguridad RLS** | ⚠️ Incompleta / inconsistente |
