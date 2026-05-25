# PRD 7 — Reporte Fase 1A

**Inventario de tablas + tamaños**

| | |
|---|---|
| **Fecha** | 2026-05-24 |
| **Tamaño total `public`** | ~60 MB (mayormente operativo POS) |
| **Total de tablas** | 115 |
| **Negocios activos** | ~15 (25 rows en `businesses`) |

---

## 1. Top 10 por peso

| # | Tabla | Tamaño | Rows | Notas |
|---|---|---|---|---|
| 1 | `order_items` | 9.6 MB | 21,305 | ✓ Operativo. Volumen sano para 15 negocios |
| 2 | `order_item_tax_lines` | 6.3 MB | 21,969 | ✓ ~1.03 líneas/item (ITBIS + LEY común) |
| 3 | `payments` | 5.0 MB | 9,603 | ✓ ~78% de orders cierran con pago |
| 4 | `fiscal_documents` | 4.9 MB | 9,398 | ✓ ~1 NCF por payment, alineado |
| 5 | `order_checks` | 4.9 MB | 12,592 | ✓ Mayoría son C1 (sin split bill) |
| 6 | `orders` | 4.5 MB | 12,406 | ✓ Normal |
| 7 | `table_sessions` | 4.1 MB | 12,800 | ✓ ~1:1 con orders, esperado |
| 8 | `order_item_modifiers` | 1.8 MB | 6,718 | ✓ ~31% de items tienen modifier |
| 9 | `role_permissions` | 1.6 MB | 5,575 | ⚠️ Alta cardinalidad — verificar (§3.2) |
| 10 | `fiscal_documents_backup_20260513` | 1.6 MB | 5,023 | 🟡 **BACKUP en producción** |

---

## 2. Estado: 🟢 OK — tamaño total razonable

A nivel volumen no hay nada preocupante:
- 60 MB para 15 negocios operando ~1 año = ~4 MB por negocio.
- Crecimiento proyectado a 5 años: ~300 MB. Trivial para Postgres.
- Ratios entre tablas son coherentes (orders : payments : NCF cerca de 1:0.78:0.76).

**Pero hay deuda técnica detectada en la lista que vale la pena limpiar.**

---

## 3. Deuda técnica detectada (🟡 OBS)

### 3.1 Tablas backup en producción (~5 MB recuperables)

Cuatro tablas backup que sobraron de la migración del 13/05:

| Tabla | Tamaño | Rows |
|---|---|---|
| `fiscal_documents_backup_20260513` | 1.6 MB | 5,023 |
| `payments_backup_20260513` | 1.4 MB | 5,181 |
| `orders_backup_20260513` | 1.0 MB | 6,747 |
| `order_checks_backup_20260513` | 1.0 MB | 6,858 |

**Acción recomendada**: si la migración del 13/05 (refactor fiscal) lleva semanas estable, droppear estas tablas. Liberan ~5 MB de Storage y, más importante, eliminan posibilidad de query accidental sobre data stale.

```sql
-- Ejecutar SOLO si el refactor fiscal lleva >30 días sin issues
DROP TABLE IF EXISTS public.fiscal_documents_backup_20260513;
DROP TABLE IF EXISTS public.payments_backup_20260513;
DROP TABLE IF EXISTS public.orders_backup_20260513;
DROP TABLE IF EXISTS public.order_checks_backup_20260513;
```

### 3.2 Tablas legacy NCF / Comprobantes (deuda histórica)

Estas son del flujo de comprobantes pre-refactor fiscal. Todas con 0 rows:

| Tabla | Rows | Por qué existe |
|---|---|---|
| `comprobantes` | 0 | Legacy NCF en español, reemplazado por `fiscal_documents` |
| `comprobante_items` | 0 | Idem |
| `module_comprobantes_settings` | 0 | Config de módulo viejo |
| `auditoria_comprobantes` | 0 | Audit del flujo viejo |
| `secuencias_ncf` | 0 | Reemplazado por `ncf_sequences` |
| `dgii_receipt_types` | 0 | Vacío, no usado |
| `dgii_logs` | 0 | Vacío, no usado |
| `fiscal_receipts` | 0 | Legacy pre-PRD fiscal |

**Acción recomendada**: drop después de confirmar que nada en producción los referencia. Total liberado: ~300 KB pero más importante: **eliminan confusión arquitectónica** (~~8~~ → 0 tablas que aparentan ser el flujo fiscal real).

### 3.3 Tablas de features no implementadas (0 rows, código muerto)

Tablas que existen en el schema pero nunca recibieron data — features que se planificaron pero nunca se shippearon:

| Categoría | Tablas (0 rows) |
|---|---|
| **RRHH** | `attendance`, `shifts`, `employee_deductions`, `employee_benefits` |
| **Fidelidad** | `loyalty_programs`, `customer_points`, `point_transactions`, `customer_credits` |
| **Cupones/Gift cards** | `coupons`, `coupon_usage`, `gift_cards`, `gift_card_transactions` |
| **Combos** | `combo_groups`, `combo_group_items` |
| **Inventario avanzado** | `inventory_lots`, `stock_transfers`, `stock_transfer_items`, `suppliers`, `purchase_orders`, `purchase_order_items` |
| **Crédito** | `credit_payments` |
| **Audit/Telemetría** | `audit_logs`, `noc_audit_log`, `agent_nodes`, `printer_health`, `device_printer_bindings` |
| **Onboarding** | `business_onboarding` |

**No es urgente borrarlas** — son schema futuro. Pero conviene:
- Documentar cuáles son "para implementar" vs "abandonadas".
- Si están abandonadas → drop. Si son futuras → marcar con COMMENT que avise al próximo developer.

### 3.4 Tablas con conteo sospechosamente bajo

| Tabla | Rows | Sospecha |
|---|---|---|
| `direct_receipts` | 7 | Feature implementado a medias, casi sin uso real |
| `physical_count_sessions` | 1 | Feature de conteo físico — uso anecdótico |
| `physical_count_lines` | 2 | Idem |
| `gift_cards` | 1 | Test, no producción |
| `promotions` | 1 | Test, no producción |
| `membership_invoices` | 4 | ? |

**Acción**: validar con Cristian si estas features se mantendrán activas. Si no, candidatas a drop o documentación clara.

### 3.5 `_pin_cleanup_log`

Tabla con prefijo `_` (convención de utility/temporal). 15 rows. **Acción**: revisar si tiene retención automática. Si crece sin límite, agregarle `delete after N days`.

### 3.6 `v_business_id` falso positivo

Aparece en `pg_stat_user_tables` con 0 bytes / 0 rows. Casi seguro es una VIEW, no tabla. Ignorable.

---

## 4. Cardinalidades importantes para Fase 1B/1C

Cuando hagas la auditoría de RLS, **prioriza estas tablas** por volumen+sensibilidad:

| Prioridad | Tabla | Razón |
|---|---|---|
| 🔴 Crítica | `payments`, `fiscal_documents` | Datos financieros, alta cardinalidad |
| 🔴 Crítica | `orders`, `order_items` | Volumen alto, core POS |
| 🟡 Importante | `customers`, `employees` | Datos personales |
| 🟡 Importante | `cash_transactions`, `cash_count_blind`, `cash_register_sessions` | Caja |
| 🟢 Normal | `menu_items`, `categories`, `taxes` | Operativo no sensible |

---

## 5. Proyección de crecimiento

Asumiendo ritmo lineal actual (~1 año acumulado):

| Tabla | Hoy | +1 año | +5 años |
|---|---|---|---|
| `order_items` | 9.6 MB | ~20 MB | ~50 MB |
| `payments` | 5 MB | ~10 MB | ~25 MB |
| `fiscal_documents` | 5 MB | ~10 MB | ~25 MB |
| **Total `public`** | ~60 MB | ~120 MB | ~300 MB |

**Conclusión proyección**: con Postgres en 200 GB de disco (40 GB usados actualmente), MangoPOS NO tiene problema de storage en horizonte 5 años. El problema viene de **Storage de fotos** (Fase 2, ya cubierto por el fix de compresión que aplicamos).

---

## 6. Resumen y acciones

### Estado general Fase 1A: 🟢 OK con observaciones menores

### Acciones recomendadas (orden ROI)

1. **🟡 Limpieza de backups (15 min)** — drop de las 4 tablas `*_backup_20260513` libera 5 MB y elimina confusión.
2. **🟡 Decisión sobre legacy NCF** — drop o documentar las 8 tablas con 0 rows del flujo viejo (`comprobantes*`, `secuencias_ncf`, etc.).
3. **🟢 Documentación de features futuras** — marcar con COMMENT cuáles tablas son "abandonadas" vs "para implementar".
4. **🟢 Retención de `_pin_cleanup_log`** — si crece sin límite, agregar policy de retención.

### Lo que NO es problema

- Tamaño total (60 MB es minúsculo).
- Cardinalidades (todas razonables para 15 negocios).
- Ratios entre tablas (coherentes).
- Crecimiento proyectado a 5 años.
