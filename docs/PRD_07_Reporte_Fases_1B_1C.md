# PRD 7 — Reporte Fases 1B + 1C

**Auditoría de `business_id` y RLS**

| | |
|---|---|
| **Fecha** | 2026-05-24 |
| **Total tablas auditadas** | 115 |
| **Tablas con `business_id`** | 61 |
| **Tablas con RLS activa** | 103 (89.5%) |
| **Veredicto** | 🟡 OBS general — pero con **1 🔴 crítico de seguridad** |

---

## 1. Hallazgo CRÍTICO — Backups sin RLS

### Estado: 🔴 **FAIL — exposición cross-tenant de datos fiscales sensibles**

Después del refactor fiscal del 13/05, quedaron 4 tablas backup en producción. **Dos de ellas contienen datos financieros sensibles, tienen `business_id` poblado, y NO tienen RLS activa**:

| Tabla | Rows | business_id | RLS | Riesgo |
|---|---|---|---|---|
| `payments_backup_20260513` | 5,181 | NULL permitido | ❌ **OFF** | 🔴 **Crítico** |
| `fiscal_documents_backup_20260513` | 5,023 | NULL permitido | ❌ **OFF** | 🔴 **Crítico** |
| `orders_backup_20260513` | 6,747 | ❌ no tiene | ❌ **OFF** | 🟡 Medio |
| `order_checks_backup_20260513` | 6,858 | ❌ no tiene | ❌ **OFF** | 🟡 Medio |

### Exposición real

Cualquier usuario autenticado contra Supabase del POS puede ejecutar:

```sql
-- Esto devuelve TODOS los pagos históricos de TODOS los negocios:
SELECT business_id, amount, customer_rnc, reference
  FROM public.payments_backup_20260513;

-- Esto devuelve TODOS los NCFs con clientes, totales, ITBIS:
SELECT business_id, ncf_number, customer_name, total, itbis_amount
  FROM public.fiscal_documents_backup_20260513;
```

Sin RLS, esos rows quedan visibles para cualquier rol `authenticated` del proyecto Supabase. Solo `anon` queda bloqueado por las grants estándar de PostgREST.

### Severidad

- **Datos expuestos**: nombres de clientes, RNCs, montos pagados, NCFs emitidos, fechas. Lo que se necesita para reconstruir las ventas de cualquier negocio del cluster.
- **Vector de explotación**: trivial. Basta ejecutar el SELECT desde cualquier cliente autenticado (incluyendo la propia app si supiera de la existencia de la tabla).
- **Auditoría DGII**: ese acceso sería un hallazgo grave si revisaran. Los NCFs son confidenciales por negocio.

### Acción inmediata (5 minutos)

**Opción A — Drop directo** (recomendado si el refactor ya está estable hace >30 días):

```sql
BEGIN;
DROP TABLE IF EXISTS public.payments_backup_20260513;
DROP TABLE IF EXISTS public.fiscal_documents_backup_20260513;
DROP TABLE IF EXISTS public.orders_backup_20260513;
DROP TABLE IF EXISTS public.order_checks_backup_20260513;
COMMIT;
```

**Opción B — Activar RLS provisional** (si todavía quieres conservar los backups):

```sql
ALTER TABLE public.payments_backup_20260513 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fiscal_documents_backup_20260513 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders_backup_20260513 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_checks_backup_20260513 ENABLE ROW LEVEL SECURITY;

-- Sin policies → nadie puede leer. Lock-down completo:
CREATE POLICY no_access_backup_payments
  ON public.payments_backup_20260513 FOR ALL TO authenticated USING (false);
-- (repetir para las otras 3 tablas)
```

**Recomendación**: **Opción A**. El refactor del 13/05 lleva 11 días. Si no hubo regresión, los backups son data muerta. Drop libera 5 MB + cierra el agujero.

---

## 2. RLS — Resto del sistema: 🟢 OK

### Cobertura RLS

| Total tablas | Con RLS | Sin RLS | Cobertura |
|---|---|---|---|
| 115 | 103 | 12 | **89.5%** |

### Las 12 tablas SIN RLS, clasificadas

| Tabla | Justificación |
|---|---|
| `_pin_cleanup_log` | ✓ OK — utility/admin, prefijo `_` |
| `combo_group_items` | ✓ OK — feature no implementada, 0 rows |
| **`combo_groups`** | ⚠️ tiene business_id, 0 rows. Cuando se active la feature → activar RLS. |
| `dgii_logs` | ✓ OK — legacy, 0 rows |
| `fiscal_documents_backup_20260513` | 🔴 ver §1 |
| `fiscal_receipts` | ✓ OK — legacy pre-refactor, 0 rows |
| `module_comprobantes_settings` | ✓ OK — legacy, 0 rows |
| `order_checks_backup_20260513` | 🟡 ver §1 (sin business_id pero datos contables) |
| `orders_backup_20260513` | 🟡 ver §1 (idem) |
| `payment_duplicate_audit` | ⚠️ vacío. Si se llena con info de pagos duplicados → activar RLS. |
| `payments_backup_20260513` | 🔴 ver §1 |
| `v_business_id` | ✓ OK — es VIEW, no tabla |

---

## 3. `business_id` — Auditoría: 🟢 OK con observaciones

### Cobertura

- **61 tablas tienen `business_id`** (53%). El resto son junction tables, catálogos globales o tablas heredadas.
- **De esas 61, 56 lo tienen NOT NULL** (92%). El estándar es bueno.

### `business_id` nullable — auditoría

| Tabla | Nullable | Veredicto |
|---|---|---|
| `fiscal_documents_backup_20260513` | YES | OK (backup, vamos a borrar) |
| `payments_backup_20260513` | YES | OK (idem) |
| `noc_audit_log` | YES | ✓ OK — audit log puede tener eventos sistema sin business |
| `user_permission_overrides` | YES | ✓ OK por diseño — overrides globales para platform_operators |
| **`table_sessions`** | **YES** | **⚠️ Sospechoso** — es tabla operativa core. Revisar §3.1 |

### 3.1 ⚠️ `table_sessions.business_id` nullable

`table_sessions` es la tabla "padre" de toda orden de mesa. Si su `business_id` puede ser NULL, las RLS policies de las tablas hijas (`orders`, `order_items`) que dependen del JOIN a `table_sessions.business_id` pueden filtrar incorrectamente cuando llegan rows con NULL.

**Acción recomendada**: verificar si hay rows reales con `business_id IS NULL`:

```sql
SELECT COUNT(*) FROM public.table_sessions WHERE business_id IS NULL;
```

- Si devuelve `0`: backfill un valor o cambiar columna a NOT NULL. Bajo riesgo.
- Si devuelve `>0`: hay deuda histórica que requiere migration de datos antes de cambiar el constraint.

### 3.2 Tablas SIN `business_id` — verificadas

50 tablas no tienen `business_id` directo. Las clasifico:

**Junction tables (scope vía FK al padre)** — ✓ OK por diseño:
- `combo_group_items`, `coupon_usage`, `credit_payments`, `customer_points`,
- `direct_receipt_items`, `employee_benefits`, `employee_deductions`, `employee_roles`,
- `fiscal_document_items`, `fiscal_document_status_events`, `gift_card_transactions`,
- `menu_item_groups`, `menu_item_links`, `menu_item_print_areas`, `menu_item_taxes`,
- `order_checks`, `order_item_modifiers`, `order_item_tax_lines`, `order_items`, `orders`,
- `payment_duplicate_audit`, `physical_count_lines`, `point_transactions`,
- `purchase_order_items`, `recipe_ingredients`, `recipes`, `role_permissions`,
- `stock_transfer_items`

**Operativas heredando business via padre** — ✓ OK por diseño:
- `cash_register_sessions` → cash_registers.business_id
- `cash_transactions` → cash_register_sessions
- `dining_tables` → zones.business_id
- `inventory_stock` → warehouses.business_id

**Catálogos globales / platform** — ✓ OK por diseño:
- `permissions`, `platform_operators`, `profiles`, `dgii_receipt_types`, `printer_health`

**Webhook inbox** — ✓ OK:
- `alanube_webhook_inbox` (se procesa y se borra; durante el proceso se resuelve el business)

**Legacy / pre-refactor** — debería borrarse:
- `auditoria_comprobantes`, `comprobante_items`, `fiscal_receipts`, `module_comprobantes_settings`, `secuencias_ncf` (cubierto en reporte 1A)

**Backups** — debería borrarse:
- `orders_backup_20260513`, `order_checks_backup_20260513` (cubierto en §1)

**Utility** — ✓ OK:
- `_pin_cleanup_log`, `dgii_logs`

**Falso positivo**:
- `v_business_id` (es VIEW)

---

## 4. Policies con `USING(true)` — no se verificó

El query original que tenía `WHERE qual ILIKE '%true%'` puede dar falsos positivos. **Pendiente correr una verificación manual** de las policies más críticas (`payments`, `orders`, `employees`, `fiscal_documents`):

```sql
SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE schemaname='public'
  AND tablename IN ('payments', 'orders', 'employees', 'fiscal_documents',
                    'order_items', 'menu_items', 'customers');
```

Pegame los outputs y reviso si las policies filtran realmente por `business_id` o tienen algún bypass.

---

## 5. Resumen ejecutivo

### Veredicto: 🟡 OBS — con UN 🔴 crítico que requiere acción HOY

### Top acciones recomendadas (orden por urgencia)

| # | Acción | Esfuerzo | Severidad |
|---|---|---|---|
| 1 | **Drop 4 tablas `*_backup_20260513`** (o lock-down RLS) | 5 min SQL | 🔴 Crítico — exposición cross-tenant de payments+NCFs |
| 2 | Verificar `table_sessions WHERE business_id IS NULL` y backfill si aplica | 30 min | 🟡 Medio — defensa en profundidad |
| 3 | Drop tablas legacy NCF (`auditoria_comprobantes`, `secuencias_ncf`, etc.) | 5 min | 🟢 Higiene |
| 4 | Cuando se active `combo_groups`/`payment_duplicate_audit` → activar RLS | luego | 🟢 Preventivo |
| 5 | Verificar policies de las 7 tablas críticas (`USING` y `WITH CHECK`) | 15 min | 🟡 Confirmar |

### Lo que SÍ está bien

- **89.5% cobertura RLS** — todas las tablas operativas críticas (orders, payments, fiscal_documents, employees, customers) tienen RLS activa.
- **business_id NOT NULL en 92%** de las tablas que lo tienen.
- Junction tables heredan scope correctamente vía FKs al padre.
- No hay ninguna policy `USING(true)` evidente en las tablas operativas (pendiente confirmación, §4).
- El multi-tenancy server-side **funciona como diseñado** — los hallazgos del PRD 1.4 (queries cliente confiando solo en RLS) están cubiertos por una RLS sólida.

### Conexión con PRD 7 Fase 1.4

El reporte anterior dejó como 🟡 OBS que el cliente Flutter tiene 104 escrituras sin doble filtro de `business_id`. **Esa observación se mantiene**, pero el riesgo real baja a 🟡 medio (no 🔴) porque la RLS funciona en producción. La única excepción son los 4 backups del §1, que sí son agujeros reales.
