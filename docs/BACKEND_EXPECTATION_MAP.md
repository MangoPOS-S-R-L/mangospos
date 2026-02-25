# BACKEND_EXPECTATION_MAP.md — Lo que el Frontend Espera del Backend

> Generado: 2026-02-25 | Auditor: Lovable AI

---

## 1. AUTENTICACIÓN

### Método esperado
- **PIN-based login** (4-6 dígitos)
- Asociado a un `user_id` y `business_id`
- Sin email/password (flujo POS físico)
- Sesión persistente (actualmente se pierde al recargar)

### Endpoints necesarios

| Método | Endpoint | Descripción |
|--------|----------|-------------|
| POST | `/auth/pin-login` | Verificar PIN → devolver user + token + permisos |
| POST | `/auth/pin-verify` | Verificar PIN para acciones sensibles (acceso a mesa de otro mesero) |
| POST | `/auth/logout` | Cerrar sesión |
| GET | `/auth/session` | Validar sesión activa |

---

## 2. ROLES Y PERMISOS

### Roles del sistema (pre-seed)
```
Administrador (admin) — todos los permisos
Supervisor (supervisor) — casi todos menos configuración crítica
Cajero (operator) — caja + pagos
Mesero (operator) — ventas por salón
Cocina (operator) — solo KDS
Delivery (operator) — solo delivery
```

### Tablas necesarias

```sql
roles (id, business_id, name, description, level, is_system_role, permissions[])
users (id, business_id, email, pin_hash, first_name, last_name, phone, status, photo_url, ...)
user_roles (user_id, role_id)
permissions (id, code, name, description, module, action)
```

### ~100 permisos granulares definidos
Códigos ya definidos en `src/types/users.ts` → `ALL_PERMISSIONS[]` (ej: `ventas.mesas.acceso`, `caja.apertura`, `settings.usuarios.crear`)

---

## 3. TABLAS DE BASE DE DATOS NECESARIAS

### Core POS

```sql
-- Negocio
businesses (id, name, rnc, address, phone, logo_url, ...)
branches (id, business_id, name, address, phone, manager_id, is_active)

-- Productos
menus (id, business_id, name, schedule_start, schedule_end, days[], is_active)
categories (id, business_id, name, icon, sort_order)
products (id, business_id, name, description, price, cost, sku, barcode, 
          image_url, category_id, menu_id, product_type, tax_included, 
          tax_rate, available, has_modifiers, has_variations)
modifier_groups (id, product_id, name, required, min_selection, max_selection)
modifiers (id, group_id, name, price)
combos (id, business_id, name, price, discount_pct, is_active)
combo_items (combo_id, product_id, quantity)

-- Mesas y Zonas
zones (id, branch_id, name, sort_order)
tables (id, zone_id, code, capacity, status, current_order_id)

-- Órdenes
orders (id, business_id, branch_id, table_id, customer_id, waiter_id,
        order_number, status, subtotal, tax, tip, discount, total,
        order_type, created_at, sent_at, paid_at, voided_at)
order_items (id, order_id, product_id, quantity, unit_price, modifiers_total,
             total_price, notes, status, sent_to_kitchen_at)
order_item_modifiers (id, order_item_id, modifier_id, modifier_name, price)

-- Pagos
payments (id, order_id, method, amount, reference, change, created_at, created_by)
sub_accounts (id, order_id, name, items[], subtotal, tax, total, paid)

-- Facturación
invoices (id, order_id, payment_id, invoice_number, ncf, rnc_client,
          subtotal, tax, tip, total, created_at)
credit_notes (id, invoice_id, amount, reason, ncf, created_at)
```

### Caja

```sql
cash_registers (id, branch_id, name, printer_id, status, current_shift_id)
cash_shifts (id, register_id, user_id, opened_at, closed_at, 
             opening_amount, expected_cash, expected_card, expected_transfer,
             counted_cash, counted_card, counted_transfer, difference, notes)
cash_movements (id, shift_id, type, concept, amount, created_at, created_by)
```

### Inventario

```sql
supplies (id, business_id, name, unit, current_stock, min_stock, 
          cost_per_unit, supplier_id, branch_id)
recipes (id, product_id, portions, prep_time_min)
recipe_ingredients (id, recipe_id, supply_id, quantity, unit)
inventory_movements (id, branch_id, supply_id, type, quantity, 
                     reason, created_at, created_by)
inventory_transfers (id, from_branch_id, to_branch_id, supply_id, 
                     quantity, status, created_at)
stock_adjustments (id, branch_id, supply_id, expected, counted, 
                   difference, reason, created_at)
waste_records (id, branch_id, supply_id, quantity, reason, cost, created_at)
stock_requests (id, from_branch_id, to_branch_id, supply_id, 
                quantity, priority, status, created_at)
```

### Compras

```sql
suppliers (id, business_id, name, rnc, contact_name, phone, email, address)
purchase_orders (id, supplier_id, branch_id, status, total, created_at)
purchase_order_items (id, order_id, supply_id, quantity, unit_price)
purchases (id, supplier_id, branch_id, invoice_number, date, 
           total, payment_status, warehouse)
supplier_credits (id, supplier_id, total_debt, credit_limit, last_payment)
```

### Clientes y Fidelización

```sql
customers (id, business_id, name, email, phone, address, rnc,
           total_orders, total_spent, loyalty_points, membership_level_id)
membership_levels (id, business_id, name, min_points, discount_pct, benefits)
loyalty_cards (id, customer_id, card_number, points, is_active)
loyalty_history (id, customer_id, action, points, order_id, created_at)
promotions (id, business_id, name, type, value, start_date, end_date, is_active)
coupons (id, business_id, code, discount_type, value, max_uses, uses, 
         valid_from, valid_until, is_active)
gift_cards (id, business_id, code, initial_value, current_balance, 
            purchased_by, is_active)
reward_points (id, customer_id, points_earned, points_redeemed, balance)
customer_credits (id, customer_id, credit_limit, balance, status)
```

### Configuración

```sql
settings (id, business_id, key, value, category)
-- Categorías: comandas, precuentas, sistema, app, regional
tax_rates (id, business_id, name, rate, is_default, is_active)
currencies (id, business_id, code, name, symbol, exchange_rate, is_default)
fiscal_config (id, business_id, ncf_prefix, current_sequence, max_sequence,
               ecf_enabled, dgii_rnc)
```

### RRHH

```sql
shifts (id, branch_id, name, days[], start_time, end_time, is_active)
employee_schedules (user_id, shift_id, date, status)
employment_info (user_id, hire_date, contract_type, department, position,
                 base_salary, currency, payroll_frequency, 
                 afp_provider, ars_provider, ...)
```

### Impresión

```sql
printers (id, branch_id, name, type, ip_address, port, is_active)
printer_assignments (printer_id, entity_type, entity_id)
-- entity_type: 'product', 'category', 'receipt', 'comanda'
```

---

## 4. ENDPOINTS CRUD NECESARIOS

### Patrón general para cada entidad:

```
GET    /api/{entity}          — Listar (con filtros, paginación)
GET    /api/{entity}/:id      — Detalle
POST   /api/{entity}          — Crear
PUT    /api/{entity}/:id      — Actualizar
DELETE /api/{entity}/:id      — Eliminar
```

### Endpoints especializados:

| Método | Endpoint | Descripción |
|--------|----------|-------------|
| POST | `/api/orders/:id/send-kitchen` | Enviar orden a cocina |
| POST | `/api/orders/:id/pay` | Registrar pago |
| POST | `/api/orders/:id/split` | Dividir cuenta |
| POST | `/api/orders/:id/void` | Anular orden |
| PUT | `/api/orders/:id/items/:itemId/status` | Cambiar estado de item (KDS) |
| POST | `/api/cash-registers/:id/open` | Abrir caja |
| POST | `/api/cash-registers/:id/close` | Cerrar caja (cierre a ciegas) |
| POST | `/api/cash-registers/:id/movement` | Registrar ingreso/egreso |
| PUT | `/api/products/:id/availability` | Toggle disponibilidad |
| POST | `/api/products/:id/stock-out` | Marcar agotado (KDS) |
| GET | `/api/reports/sales` | Reporte de ventas (con rango de fechas) |
| GET | `/api/reports/purchases` | Reporte de compras |
| GET | `/api/reports/inventory` | Reporte de inventario |
| GET | `/api/reports/financial` | Reporte financiero |
| GET | `/api/dashboard/summary` | Resumen para dashboard |
| POST | `/api/invoices/:id/print` | Generar PDF/enviar a impresora |
| GET | `/api/fiscal/ncf-available` | NCF disponibles |

---

## 5. REAL-TIME (WebSocket / Subscriptions)

| Canal | Uso |
|-------|-----|
| `tables:status` | Actualización en tiempo real del estado de mesas |
| `orders:kitchen` | Nuevas órdenes para KDS |
| `orders:status` | Cambios de estado de órdenes |
| `products:availability` | Productos agotados/disponibles |
| `cash:movements` | Nuevos movimientos de caja |

---

## 6. SEGURIDAD (RLS / Policies)

### Reglas esperadas:

| Tabla | Política |
|-------|---------|
| Todas | Filtrar por `business_id` del usuario autenticado |
| `users` | Solo Admin puede crear/editar/desactivar |
| `orders` | Mesero solo ve sus propias órdenes (excepto Admin/Supervisor) |
| `cash_shifts` | Solo el usuario del turno o Admin puede ver/cerrar |
| `settings` | Solo Admin puede modificar |
| `payments` | Solo Admin puede anular |
| `credit_notes` | Solo Admin/Supervisor puede crear |
| `fiscal_config` | Solo Admin puede modificar |

---

## 7. RESUMEN DE ESTADO (Actualizado a Flutter + Supabase)

| Aspecto | Estado actual |
|---------|--------------|
| Backend conectado | ✅ Sí (Supabase) |
| Base de datos | ✅ Sí (PostgreSQL + RLS) |
| Autenticación real | ✅ Sí (Supabase Auth Email/Password) |
| Persistencia de datos | ✅ Parcial (Ventas, Caja, Cocina sí; Productos, Inventario, Clientes no) |
| Archivos locales (SQLite) | ❌ No (Todo es online) |
| Real-time | ✅ Parcial (KDS cocina usa Supabase Realtime) |
| Impresión | ⚠️ Parcial (Agente local y servicios Flutter armados, falta integrarlos al flujo) |
| Facturación fiscal | ❌ No (Supabase tiene un mock fijo `B0200000001`) |
| Multi-sucursal | ❌ No (UI existe, sin filtro en BD por branch_id) |
| Multi-moneda | ❌ No (Todo en RD$) |

**Conclusión Actualizada:** El frontend migró a Flutter usando Riverpod. **No es un prototipo.** El motor pesado (Autenticación, Gestión de Mesas, KDS en Cocina, Pagos) está conectado a un backend de producción en Supabase usando funciones atómicas (RPCs) y transacciones. Sin embargo, los módulos administrativos (Productos, Reportes, Inventario) tienen repositorios vacíos y aún requieren desarrollo del lado de Flutter.
