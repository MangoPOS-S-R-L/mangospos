# PRD 7 — Reporte Fase 1.4

**Auditoría de queries del cliente Flutter — Aislamiento Multi-Tenant**

| | |
|---|---|
| **Fecha** | 2026-05-24 |
| **Alcance** | `lib/` (production code). Excluye `lib/databasecode/`, `lib/examples/`, `test/`, docs |
| **Metodología** | Grep + análisis estático sobre llamadas `.from(...)`, `.select`, `.insert`, `.update`, `.delete`, `.upsert`, `.rpc` |

---

## 1. Resumen ejecutivo

| Categoría | Definición | Conteo |
|---|---|---|
| **A — OK** | Query con `.eq('business_id', X)` explícito en el chain | 49 |
| **B — RIESGO** | Query sin filtro `business_id` sobre tabla sensible. Solo confía en RLS | 104 |
| **C — OK por diseño** | Catálogos globales o queries scoped por FK uuid no-enumerable | (no contado, ver §3) |
| **D — RPC** | `.rpc(...)` con `SECURITY DEFINER`. Filtro vive server-side | 30+ |

**Estado general: 🟡 OBS** — RLS es la única línea de defensa para los 104 hits de categoría B. Si RLS falla por un bug en `pg_policies` (Fase 1.3), el blast radius es alto. **NO bloqueador hoy**, pero amerita endurecimiento progresivo.

---

## 2. Categoría B — Casos de riesgo, ordenados por severidad

### 2.1 Crítico (datos fiscales / financieros)

#### B.1 — Anulación de pago sin filtro `business_id`

**Archivo**: [`lib/data/repositories/sales_repository.dart`](../lib/data/repositories/sales_repository.dart)

| Línea | Operación | Tabla | Filtro |
|---|---|---|---|
| 143-149 | SELECT siblings | `payments` | `eq('order_id', X)` solo |
| 158-164 | SELECT payment | `payments` | `eq('id', X)` solo |
| 204-206 | **UPDATE status='cancelled'** | `payments` | `eq('id', X)` solo |
| 208-211 | **UPDATE status='cancelled'** | `fiscal_documents` | `eq('payment_id', X)` solo |
| 232-235 | UPDATE status_ext | `orders` | `eq('id', X)` solo |

**Riesgo concreto**: si un bug en RLS de `payments` (ej. policy `USING (true)`) llegara a producción, un usuario autenticado del Negocio A podría anular pagos del Negocio B conociendo solo el UUID del payment. Los UUIDs no son enumerables fácilmente, pero si se filtran por logs/reports/etc., el atacante puede actuar. **El cliente no provee segunda barrera defensiva.**

**Mitigación recomendada**: agregar `.eq('business_id', activeBusinessId)` al UPDATE. Convierte un bypass de RLS en un fallo silencioso (0 rows updated).

#### B.2 — Annul order sin segunda barrera

Mismo patrón en `annulOrder()` y `_recoverCompletedPaymentAfterUniqueViolation` ([`sales_repository.dart:1674-1683`](../lib/data/repositories/sales_repository.dart), [`sales_repository_improved.dart:401`](../lib/data/repositories/sales_repository_improved.dart)).

#### B.3 — Cash transactions sin filtro

[`sales_repository.dart:260`](../lib/data/repositories/sales_repository.dart) — `INSERT INTO cash_transactions(...)` sin `business_id` explícito (depende del trigger que lo deriva de session_id). Riesgo bajo porque el `cashier_session_id` viene del state autenticado, pero faltaría defensa en profundidad.

#### B.4 — Update fiscal documents

[`sales_repository.dart:209`](../lib/data/repositories/sales_repository.dart) — `UPDATE fiscal_documents SET status='cancelled' WHERE payment_id=X`. NCFs son sensibles fiscalmente (DGII auditable). Sin business_id, si RLS rompe, se anulan NCFs ajenos.

---

### 2.2 Medio (RBAC / personal)

#### B.5 — Edit/Delete empleado

[`lib/data/repositories/employee_repository.dart:292`](../lib/data/repositories/employee_repository.dart) — `UPDATE employees SET ... WHERE id = X`
[`lib/data/repositories/employee_repository.dart:375`](../lib/data/repositories/employee_repository.dart) — `DELETE FROM employees WHERE id = X`

Sin `business_id`. Si RLS rompe → un admin del Negocio A modifica/borra empleados del Negocio B. Impacto: pérdida de acceso del personal víctima, suplantación de identidad.

#### B.6 — Update/Delete productos

[`lib/data/repositories/products_repository.dart:122-281`](../lib/data/repositories/products_repository.dart) — múltiples UPDATE/DELETE `WHERE id = X` sin `business_id`.

#### B.7 — Inventory stock chain

[`lib/data/repositories/inventory_repository.dart:140-148`](../lib/data/repositories/inventory_repository.dart) — `inventory_items` filtra por business_id ✓ pero la query siguiente a `inventory_stock` solo filtra por `warehouse_id`. Si un warehouse_id de otro tenant llegara al cliente (por bug de hidratación), la query traería stock ajeno. **RLS cubre, pero la cadena lógica está rota.**

Líneas 274, 290, 301, 304 — UPDATE/DELETE inventory_stock sin business_id upstream.

---

### 2.3 Bajo (configuración / metadata)

- [`printing_repository.dart:2319, 2336`](../lib/data/repositories/printing_repository.dart) — `menu_items` SELECT sin business_id en contexto de printing.
- [`sales_repository.dart:226-229`](../lib/data/repositories/sales_repository.dart) — UPDATE `order_checks` solo por id (defensa débil pero datos no-fiscales).

---

## 3. Categoría C — OK por diseño

Quedan **fuera** del análisis crítico:

- **Catálogos globales**: `countries`, `currencies`, `auth.users`, `profiles` (scoped por user_id que es claim del JWT).
- **Queries por UUID con escritura previa scoped**: ejemplo, `getOrderById(orderId)` donde `orderId` se obtuvo de un listado ya filtrado por `business_id`. Defensible si RLS no falla.
- **Asserts explícitos**: `_assertOrderInBusinessScope(orderId)` en [`sales_repository.dart`](../lib/data/repositories/sales_repository.dart) — valida scope ANTES de operaciones de lectura. Patrón correcto, **pero no aplicado a UPDATE/DELETE**.

---

## 4. Categoría D — RPCs (filtro server-side)

Las llamadas `.rpc(...)` filtran server-side via `SECURITY DEFINER` + lógica interna. No requieren filtro en el cliente porque la función SQL hace `SELECT business_id FROM table_sessions WHERE id = ...` y valida ahí.

RPCs principales catalogadas (selección):

| RPC | Dominio | Filtro server-side |
|---|---|---|
| `fn_process_payment_v3` | Pagos | Resuelve business_id desde `table_sessions` → `orders`. Auditado en migraciones |
| `fn_add_item_from_menu` | Sales | Mismo patrón |
| `fn_open_cash_session` | Caja | Filtra por `auth.uid()` |
| `fn_inventory_adjust` | Inventario | Recibe `p_business_id` explícito |
| `fn_create_employee_with_access` | RBAC | Validación de role + business |
| `fn_mark_order_takeout` | Sales | Indirecto via order → session → business |
| `fn_toggle_item_takeout` | Sales | Indirecto |
| `fn_inventory_transfer_send/receive` | Inventario | Filtra business |

**Estado RPCs: ✅ OK**. La capa server-side de Supabase es la fuente de verdad para multi-tenancy.

---

## 5. Patrones detectados (deuda técnica)

### 5.1 — `update(...).eq('id', X)` sin business_id

**Frecuencia**: alta. Aparece en `sales_repository`, `employee_repository`, `products_repository`, `inventory_repository`, `customer_repository`.

**Por qué pasa**: el desarrollador asume que el UUID del registro es suficiente porque RLS lo filtra. Es correcto **mientras RLS esté bien configurada**, pero NO ofrece defensa en profundidad ante:
- Una migración futura que rompa RLS.
- Un toggle accidental de `rowsecurity = false`.
- Una policy mal escrita (`USING (true)`).

### 5.2 — Inserts sin `business_id` que dependen del trigger

**Frecuencia**: media. `INSERT INTO cash_transactions(...)` sin `business_id` porque el trigger lo deriva.

**Riesgo**: si el trigger falla o se desactiva por una migración, los inserts entran sin business_id (NULL) y queda en limbo.

### 5.3 — Cadena de FKs rota

`inventory_items` filtra por `business_id` ✓ pero `inventory_stock` filtra solo por `warehouse_id`. Si el cliente recibiera un `warehouse_id` ajeno (bug, race, replay), la query traería data cross-tenant.

---

## 6. Conclusión y top recomendaciones

**Veredicto Fase 1.4**: 🟡 **OBS — Aislamiento depende exclusivamente de RLS**

La auditoría confirma que MangoPOS confía pesadamente en RLS para aislamiento multi-tenant. El cliente Flutter NO tiene una segunda barrera defensiva en operaciones de escritura críticas. Eso no es necesariamente roto **hoy** (asumiendo RLS sana, que mide la Fase 1.3), pero deja el sistema con un **single point of failure** desde el ángulo de aislamiento.

### Top 3 acciones recomendadas para el PRD siguiente

1. **Patrón obligatorio "doble filtro" en escrituras críticas** (severidad alta)
   - Reescribir todos los `.update().eq('id', X)` sobre `payments`, `fiscal_documents`, `orders`, `employees` para que incluyan `.eq('business_id', activeBusinessId)`.
   - Estimado: 2-3 días de refactor cuidadoso + tests.
   - ROI: convierte cualquier futuro bug de RLS de "data corruption cross-tenant" a "fallo silencioso (0 rows)".

2. **Lint rule + code review checklist** (severidad media)
   - Definir regla: "todo INSERT/UPDATE/DELETE sobre tabla con `business_id` debe filtrar por `business_id` explícito".
   - Documentar en `CLAUDE.md` y agregar a PR template.
   - Estimado: 0.5 días.

3. **Fix de la cadena rota `inventory_items` → `inventory_stock`** (severidad media)
   - Antes de cualquier query a `inventory_stock`, verificar que el `warehouse_id` pertenece al business activo.
   - Estimado: 1 día.

### Hallazgos que **NO** requieren acción inmediata

- RPCs (Categoría D) son seguras por diseño server-side.
- Queries con `_assertOrderInBusinessScope()` previo cumplen la defensa en profundidad.
- Reads que ya filtran por `business_id` explícito (Categoría A) están OK.

---

## 7. Evidencia

Auditoría hecha el 2026-05-24 vía `Explore` agent + verificación manual de hits críticos. Comando reproducible:

```bash
grep -rn "\.from(\|\.insert(\|\.update(\|\.delete(\|\.upsert(\|\.rpc(" \
  /Users/cristiangomez/dev/mangospos/lib \
  --include="*.dart" \
  | grep -v "lib/databasecode/" \
  | grep -v "lib/examples/" \
  > audit_queries.txt
```

Verificación manual de hits críticos: leídas líneas 130-240 de `sales_repository.dart` para confirmar la cadena de UPDATEs de anulación de pago sin business_id (confirmado).
