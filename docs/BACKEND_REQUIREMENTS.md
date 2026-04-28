# BACKEND_REQUIREMENTS.md — Requerimientos de Backend
> Generado: 2026-02-24 | MangoPOS Flutter + Supabase
> **Nota:** Este documento define exactamente qué necesita el backend. No incluye código, solo especificaciones estructurales.

---

## 1. TABLAS NECESARIAS

### 1.1 Tablas YA EXISTENTES en Supabase (schema.sql confirmado)

| Tabla | Estado |
|-------|--------|
| `businesses` | ✅ Existe |
| `profiles` | ✅ Existe |
| `user_businesses` | ✅ Existe |
| `memberships` | ✅ Existe (duplicación con user_businesses — consolidar) |
| `zones` | ✅ Existe |
| `dining_tables` | ✅ Existe |
| `table_sessions` | ✅ Existe |
| `orders` | ✅ Existe |
| `order_items` | ✅ Existe |
| `order_item_modifiers` | ✅ Existe |
| `order_checks` | ✅ Existe |
| `payments` | ✅ Existe |
| `payment_methods` | ✅ Existe |
| `cash_registers` | ✅ Existe |
| `cash_register_sessions` | ✅ Existe |
| `cash_transactions` | ✅ Existe |
| `menu_items` | ✅ Existe |
| `menu_categories` | ✅ Existe (o similar) |
| `menus` | ✅ Existe |
| `modifier_groups` | ✅ Existe |
| `modifiers` | ✅ Existe |
| `taxes` | ✅ Existe |
| `currencies` | ✅ Existe |
| `business_settings` | ✅ Existe |
| `printers` | ✅ Existe |
| `fiscal_documents` | ✅ Existe (con NCF mock) |
| `ncf_sequences` | ✅ Existe (verificar) |
| `recipes` | ✅ Existe |
| `recipe_ingredients` | ✅ Existe |
| `inventory_items` | ✅ Existe |
| `inventory_movements` | ✅ Existe |
| `warehouses` | ✅ Existe |
| `suppliers` | ✅ Existe (verificar) |
| `purchase_orders` | ✅ Existe (verificar) |
| `kds_active_items` | ✅ Vista (verificar definición) |

### 1.2 Tablas FALTANTES o INCOMPLETAS

| Tabla | Por qué se necesita | Campos mínimos |
|-------|--------------------|-----------------|
| `customers` | Módulo de clientes sin queries | `id`, `business_id`, `name`, `email`, `phone`, `rnc`, `total_orders`, `total_spent`, `loyalty_points`, `created_at` |
| `loyalty_cards` | Programa de fidelidad | `id`, `customer_id`, `card_number`, `points`, `is_active` |
| `loyalty_history` | Historial de puntos | `id`, `customer_id`, `action`, `points`, `order_id`, `created_at` |
| `membership_levels` | Niveles de membresía | `id`, `business_id`, `name`, `min_points`, `discount_pct`, `benefits` |
| `promotions` | Descuentos y promociones | `id`, `business_id`, `name`, `type`, `value`, `start_date`, `end_date`, `is_active`, `min_purchase` |
| `coupons` | Códigos promocionales | `id`, `business_id`, `code`, `discount_type`, `value`, `max_uses`, `uses`, `valid_from`, `valid_until` |
| `gift_cards` | Tarjetas de regalo | `id`, `business_id`, `code`, `initial_value`, `current_balance`, `purchased_by`, `is_active` |
| `customer_credits` | Venta a crédito | `id`, `customer_id`, `business_id`, `credit_limit`, `balance`, `status` |
| `credit_transactions` | Historial de crédito | `id`, `customer_credit_id`, `amount`, `type`, `order_id`, `created_at` |
| `shifts` | Turnos de trabajo | `id`, `business_id`, `name`, `days`, `start_time`, `end_time`, `is_active` |
| `employee_schedules` | Horarios de empleados | `user_id`, `shift_id`, `date`, `status` |
| `sales_goals` | Metas de ventas | `id`, `business_id`, `name`, `target_amount`, `period`, `start_date`, `end_date` |
| `stock_adjustments` | Cuadre de stock | `id`, `warehouse_id`, `item_id`, `expected`, `counted`, `difference`, `reason`, `created_at` |
| `supplier_credits` | Cuentas por pagar | `id`, `supplier_id`, `total_debt`, `credit_limit`, `last_payment` |
| `combos` | Combos/paquetes | `id`, `business_id`, `name`, `price`, `discount_pct`, `is_active` |
| `combo_items` | Items de combos | `combo_id`, `menu_item_id`, `quantity` |
| `printer_categories` | Asignación impresora-categoría | `printer_id`, `category_id` |
| `app_versions` | Control de actualizaciones | `id`, `version`, `min_required`, `release_notes`, `released_at` |
| `exchange_rates` | Tipos de cambio histórico | `id`, `business_id`, `from_currency`, `to_currency`, `rate`, `date` |

---

## 2. RELACIONES Y CLAVES FORÁNEAS

| Relación | Tipo | Constraint |
|----------|------|-----------|
| `customers.business_id` → `businesses.id` | N:1 | ON DELETE CASCADE |
| `orders.customer_id` → `customers.id` | N:1 | ON DELETE SET NULL |
| `loyalty_history.customer_id` → `customers.id` | N:1 | ON DELETE CASCADE |
| `loyalty_history.order_id` → `orders.id` | N:1 | ON DELETE SET NULL |
| `promotions.business_id` → `businesses.id` | N:1 | ON DELETE CASCADE |
| `coupons.business_id` → `businesses.id` | N:1 | ON DELETE CASCADE |
| `combos.business_id` → `businesses.id` | N:1 | ON DELETE CASCADE |
| `combo_items.combo_id` → `combos.id` | N:1 | ON DELETE CASCADE |
| `combo_items.menu_item_id` → `menu_items.id` | N:1 | ON DELETE RESTRICT |
| `customer_credits.customer_id` → `customers.id` | 1:1 | ON DELETE CASCADE |
| `shifts.business_id` → `businesses.id` | N:1 | ON DELETE CASCADE |
| `sales_goals.business_id` → `businesses.id` | N:1 | ON DELETE CASCADE |
| `stock_adjustments.warehouse_id` → `warehouses.id` | N:1 | ON DELETE RESTRICT |
| `printer_categories.printer_id` → `printers.id` | N:1 | ON DELETE CASCADE |

**CONSOLIDACIÓN URGENTE:** Las tablas `memberships` y `user_businesses` modelan la misma relación usuario-negocio. Se deben consolidar en una sola tabla o definir claramente la diferencia semántica.

---

## 3. ÍNDICES

### Índices críticos para performance

```
-- Órdenes por negocio y estado (dashboard, reportes)
CREATE INDEX idx_orders_business_status ON orders(business_id, status_ext, created_at DESC);

-- Items por orden (carga de carrito)
CREATE INDEX idx_order_items_order ON order_items(order_id, status);

-- Sesiones activas de mesa
CREATE INDEX idx_table_sessions_active ON table_sessions(business_id, closed_at) WHERE closed_at IS NULL;

-- KDS: items pendientes/preparando
CREATE INDEX idx_order_items_kitchen ON order_items(business_id, status, created_at) 
  WHERE status IN ('pending', 'preparing');

-- Clientes por negocio
CREATE INDEX idx_customers_business ON customers(business_id, name);

-- Pagos por orden
CREATE INDEX idx_payments_order ON payments(order_id, created_at DESC);

-- Caja: sesiones por usuario
CREATE INDEX idx_cash_sessions_user ON cash_register_sessions(user_id, status) WHERE status = 'open';

-- Inventario por almacén y producto
CREATE INDEX idx_inventory_movements_item ON inventory_movements(warehouse_id, item_id, created_at DESC);

-- Documentos fiscales
CREATE INDEX idx_fiscal_docs_business ON fiscal_documents(business_id, ncf_number, issued_at DESC);

-- NCF sequences por tipo
CREATE INDEX idx_ncf_sequences_type ON ncf_sequences(business_id, ncf_type, is_active);
```

---

## 4. ROW LEVEL SECURITY (RLS)

### 4.1 Política base — Todas las tablas

```
Regla: El usuario solo puede ver y modificar datos de su(s) negocio(s).
Función auxiliar: current_user_business_ids() — ya existe pero necesita consolidación.
```

### 4.2 Políticas específicas por tabla

| Tabla | SELECT | INSERT | UPDATE | DELETE |
|-------|--------|--------|--------|--------|
| `businesses` | Solo miembro del negocio | Solo owner | Solo owner/admin | ❌ Nunca |
| `profiles` | Propio perfil | Sistema (trigger) | Propio perfil | ❌ Nunca |
| `orders` | Propio negocio | Propio negocio | Admin/Supervisor; mesero solo sus órdenes | Admin solo |
| `order_items` | Via order.business_id | Via order | Mesero (notas/quantity antes de envío); Admin siempre | Admin solo |
| `payments` | Admin/Cajero del negocio | Admin/Cajero | ❌ Inmutable | ❌ Nunca |
| `cash_register_sessions` | Admin/Cajero del negocio | Cajero autenticado | Solo el dueño de la sesión o Admin | ❌ Nunca |
| `menu_items` | Propio negocio | Admin/Manager | Admin/Manager | Admin solo |
| `customers` | Propio negocio | Cualquier rol autenticado | Admin/Manager | Admin solo |
| `fiscal_documents` | Admin/Manager del negocio | Sistema (SECURITY DEFINER) | ❌ Inmutable | ❌ Nunca |
| `inventory_movements` | Admin/Manager | Cualquier rol (con restricción de tipo) | ❌ Inmutable | ❌ Nunca |
| `promotions` | Propio negocio | Admin/Manager | Admin/Manager | Admin solo |
| `business_settings` | Propio negocio | Sistema | Solo Admin | ❌ Nunca |
| `shifts` | Propio negocio | Admin/Manager | Admin/Manager | Admin solo |
| `user_businesses` | Propio registro | Sistema | Admin del negocio | Admin solo |

### 4.3 Tablas que actualmente NO tienen RLS activo (verificar)

Según el header del schema.sql: `SET row_security = off;` — esto solo afecta la sesión de importación, pero todas las tablas necesitan revisión de políticas activas en el dashboard de Supabase.

---

## 5. TRIGGERS

### 5.1 Triggers existentes (confirmar en producción)

| Trigger | Tabla | Función |
|---------|-------|---------|
| `fn_compute_item_totals` | `order_items` (BEFORE INSERT/UPDATE) | Calcula subtotal y total del item |
| `fn_after_item_change` | `order_items` (AFTER INSERT/UPDATE/DELETE) | Recalcula totales de la orden |
| `enforce_prep_minutes` | `menu_items` (BEFORE INSERT/UPDATE) | Limpia prep_minutes si has_prep=false |
| `fn_check_max_checks` | `order_checks` (BEFORE INSERT) | Limita a 5 checks por orden |
| `calculate_order_totals` | Via RPCs | Calcula subtotal/tax/total de orden |
| `calculate_check_totals` | Via RPCs | Calcula totales de checks |

### 5.2 Triggers FALTANTES que se necesitan

| Trigger | Tabla | Función necesaria |
|---------|-------|------------------|
| Auto-crear `customer_credits` | `customers` (AFTER INSERT) | Crear registro de crédito en 0 al día de creación |
| Actualizar `customers.total_orders` y `total_spent` | `payments` (AFTER INSERT) | Incrementar totales acumulados del cliente al pagar |
| Acumular `loyalty_points` | `payments` (AFTER INSERT) | Calcular y registrar puntos según membresía |
| Actualizar `inventory_items.stock` | `inventory_movements` (AFTER INSERT) | Sumar/restar stock actual al registrar movimiento |
| Auto-close `table_sessions` | `orders` (AFTER UPDATE de status a 'void') | Liberar mesa si todos los pedidos están cancelados |
| Notificar KDS | `order_items` (AFTER UPDATE de status a 'pending') | Insert en tabla de notificaciones si no hay real-time |

---

## 6. EDGE FUNCTIONS (Supabase)

| Función | Trigger | Descripción |
|---------|---------|-------------|
| `send-kitchen-notification` | POST /orders/:id/send | Envío de push al KDS (si no usa Realtime) |
| `generate-ncf` | POST /fiscal/document | Generar NCF secuencial real, conectar DGII |
| `process-ecf` | POST /fiscal/ecf | Envío de comprobante electrónico a DGII |
| `send-receipt-email` | POST /payments/:id/receipt | Enviar factura por email al cliente |
| `generate-report-pdf` | POST /reports/pdf | Generar reportes en PDF |
| `sync-inventory` | Scheduled (daily) | Verificar stock bajo y generar alertas |
| `stripe-checkout` | POST /payments/stripe | Integración con Stripe (si aplica) |
| `apply-coupon` | POST /orders/:id/coupon | Validar y aplicar cupón a orden activa |
| `close-cashier-session` | POST /cash/close | Wrapper de `fn_close_cash_session` con validaciones extras |

---

## 7. ENDPOINTS REST / RPC

### 7.1 RPCs existentes (verificar que están activos)

| RPC | Estado | Llamada Flutter |
|-----|--------|----------------|
| `fn_open_table_session` | ✅ Activo | `SalesRepository.openTable()` |
| `fn_open_manual_or_quick` | ✅ Activo | `SalesRepository.openManualOrQuick()` |
| `fn_add_item_from_menu` | ✅ Activo | `SalesRepository.addItemFromMenu()` |
| `fn_update_item_qty` | ✅ Activo | `SalesRepository.updateItemQuantity()` |
| `fn_update_item_notes` | ✅ Activo | `SalesRepository.updateItemNotes()` |
| `fn_delete_item` | ✅ Activo | `SalesRepository.deleteItem()` |
| `fn_toggle_item_takeout` | ✅ Activo | `SalesRepository.toggleItemTakeout()` |
| `fn_confirm_order_to_kitchen` | ✅ Activo | `SalesRepository.sendToKitchen()` |
| `fn_create_split_bill` | ✅ Activo | `SalesRepository.createSplitBill()` |
| `fn_move_item_to_check` | ✅ Activo | `SalesRepository.moveItemToCheck()` |
| `fn_process_payment` | ✅ Activo | `SalesRepository.processPayment()` |
| `fn_close_order_and_table` | ✅ Activo | `SalesRepository.closeOrder()` |
| `create_fiscal_document` | ⚠️ MOCK | `SalesRepository.createFiscalDocument()` |
| `fn_close_cash_session` | ✅ Activo pero no llamado | No llamado desde Flutter |
| `fn_start_preparing_order` | ❓ No visible en schema | `KitchenRepository.startPreparingOrder()` |
| `fn_mark_order_ready` | ❓ No visible en schema | `KitchenRepository.markOrderReady()` |
| `get_table_live` | ✅ Activo | `SalesRepository.getTableLive()` |
| `fn_get_or_create_check` | ✅ Interno | Usado en otros RPCs |
| `fn_recalc_order_totals` | ✅ Interno | Trigger-like |

### 7.2 RPCs FALTANTES que necesitan crearse

| RPC | Descripción | Prioridad |
|-----|-------------|-----------|
| `fn_get_products_by_business` | Catálogo de productos para el POS, con filtros | P0 |
| `fn_create_or_update_menu_item` | CRUD de producto con categorías y modificadores | P0 |
| `fn_toggle_product_availability` | Marcar producto disponible/agotado | P0 |
| `fn_apply_discount_to_order` | Aplicar promoción o cupón a una orden | P1 |
| `fn_get_sales_summary` | Resumen de ventas del día (dashboard) | P1 |
| `fn_get_sales_report` | Reporte de ventas por rango de fechas | P1 |
| `fn_get_inventory_report` | Reporte de inventario actual | P2 |
| `fn_adjust_stock` | Registrar ajuste de inventario (cuadre) | P2 |
| `fn_transfer_inventory` | Mover stock entre almacenes | P2 |
| `fn_create_customer` | Crear cliente con validación de RNC/email único | P1 |
| `fn_get_customer_history` | Historial de compras de un cliente | P2 |
| `fn_redeem_coupon` | Validar y aplicar cupón | P2 |
| `fn_add_loyalty_points` | Acumular puntos al cliente | P2 |
| `fn_generate_real_ncf` | NCF secuencial real desde `ncf_sequences` | P0 |
| `fn_get_active_promotions` | Promociones activas aplicables a una orden | P2 |
| `fn_get_financial_summary` | Resumen financiero para reportes | P2 |

---

## 8. REAL-TIME (Supabase Realtime)

### 8.1 Canales necesarios

| Canal / Tabla | Evento | Consumidor Flutter | Prioridad |
|---------------|--------|--------------------|-----------|
| `dining_tables` | UPDATE | `sales/view` — actualizar estado de mesa | P1 |
| `order_items` | INSERT, UPDATE | `kds/view` — ya implementado parcialmente | P1 |
| `table_sessions` | INSERT, UPDATE | `sales/view` — sesiones activas | P1 |
| `payments` | INSERT | `cashier/view` — movimientos en tiempo real | P2 |
| `cash_transactions` | INSERT | `cashier/view` — balance en tiempo real | P2 |
| `orders` | UPDATE | `monitor_ventas/view` — monitor de ventas | P2 |
| `inventory_items` | UPDATE | `inventory/view` — alertas de stock bajo | P3 |

### 8.2 Configuración necesaria

- Habilitar Realtime para las tablas listadas en el dashboard de Supabase
- Configurar `REPLICA IDENTITY FULL` en tablas donde se necesite acceso a valores anteriores (UPDATE events)
- Implementar mecanismo de reconexión automática en el cliente Flutter ante pérdida de conexión

---

## 9. FALTANTE CRÍTICO INMEDIATO (P0)

Estos son los bloqueantes que impiden que el sistema funcione en producción:

1. **`products_repository.dart`** — Archivo vacío. Sin esto, el catálogo de productos no puede gestionarse. Necesita: CRUD completo de `menu_items`, `menu_categories`, `menus`, `modifier_groups`, `modifiers`.

2. **NCF Real** — La función `create_fiscal_document` tiene NCF hardcodeado `B0200000001`. Se necesita:
   - Tabla `ncf_sequences` con secuencias por tipo (B01, B02, B14...)
   - RPC `fn_generate_real_ncf(p_business_id, p_ncf_type)` que incremente atómicamente la secuencia
   - Reemplazar el mock en `create_fiscal_document`

3. **Rol Admin como fallback** — `login_viewmodel.dart:83` asigna `PosRole.administrador` si no hay registro en `user_businesses`. Necesita: lanzar error y solicitar al administrador que configure el acceso del empleado.

4. **`reports_repository.dart`** — Archivo vacío. Sin reportes, el sistema no puede auditarse comercialmente.

5. **`customers_queries.dart`** — Archivo vacío. El módulo de clientes es inoperable.
