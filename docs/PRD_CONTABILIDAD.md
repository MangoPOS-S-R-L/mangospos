# PRD — Módulo de Contabilidad (MangoPOS)

**Fecha:** 2026-08-05
**Estado:** Fase 1 implementada (núcleo contable + generadores automáticos). Fases 2–5 pendientes.
**Fuente del alcance:** documento `Software contable.pdf` del cliente.

---

## 1. Objetivo

Convertir MangoPOS de un POS con reportes financieros a un sistema con **contabilidad
de partida doble real**: catálogo de cuentas, asientos (manuales y automáticos),
períodos, libros oficiales, estados financieros y los formatos fiscales de la DGII.

Regla de diseño transversal: **la contabilidad NO se mete en el camino crítico del
POS**. No hay triggers contables sobre `payments`, `orders` ni
`fn_process_payment_v3`. Los asientos automáticos se generan **por lote y de forma
idempotente** desde los documentos que ya existen (ventas, compras, caja, créditos).
Si el motor contable falla, el cajero sigue cobrando.

---

## 2. Gap analysis: lo que pide el PDF vs. lo que ya existe

Leyenda: ✅ ya existe · 🟡 existe parcial · ❌ no existe (antes de este PRD) · 🟢 entregado en Fase 1

### 2.1 Contabilidad general

| Requisito | Antes | Dónde | Fase 1 |
|---|---|---|---|
| Catálogo de cuentas configurable | ❌ | — | 🟢 `accounting_accounts` + seed catálogo RD |
| Asientos manuales | ❌ | — | 🟢 `fn_accounting_post_entry` + UI |
| Asientos automáticos | ❌ | — | 🟢 generadores ventas/compras/caja/créditos |
| Débitos = créditos obligatorio | ❌ | — | 🟢 validado en RPC (`UNBALANCED_ENTRY`) |
| Libro Diario | ❌ | — | 🟢 `fn_accounting_journal` |
| Libro Mayor | ❌ | — | 🟢 `fn_accounting_ledger` (con saldo inicial y corrido) |
| Auxiliares | 🟡 | CxC/CxP en `/credits`, kardex en inventario | 🟡 quedan como auxiliares externos |
| Balanza de comprobación | ❌ | — | 🟢 `fn_accounting_trial_balance` |
| Balance general | ❌ | — | 🟢 `fn_accounting_balance_sheet` |
| Estado de resultados | 🟡 | `finance_report_view` (caja, no devengado) | 🟢 `fn_accounting_income_statement` |
| Centros de costo / departamentos / proyectos / sucursales | ❌ | sucursal = `business_id` separado | 🟢 `accounting_cost_centers` (4 tipos) |
| Apertura y cierre de períodos | ❌ | — | 🟢 `accounting_periods` + cerrar/reabrir |
| Bloqueo de meses cerrados | ❌ | — | 🟢 posteo rechazado con `PERIOD_CLOSED` |
| Reversión sin borrar el original | ❌ | — | 🟢 `fn_accounting_reverse_entry` + inmutabilidad |
| Trazabilidad asiento → documento origen | ❌ | — | 🟢 `source_type` / `source_id` / `source_table` |

### 2.2 Impuestos y DGII

| Requisito | Antes | Dónde | Fase 1 |
|---|---|---|---|
| NCF (emisión, secuencias, anulación) | ✅ | `ncf_sequences`, `fiscal_documents`, `/reports/fiscal` | — |
| e-NCF | 🟡 | `20260506_0001_alanube_ecf_extension.sql` (columnas listas, sin integración viva) | — |
| Reportes de ITBIS | ✅ | `/reports/taxes` (`tax_report_view`) | — |
| Formato 606 (compras) | ❌ | hay `purchase_orders` + `suppliers.rnc`, sin RNC/NCF de compra ni tipo de bien | Fase 2 |
| Formato 607 (ventas) | ❌ | `fiscal_documents` tiene todo lo necesario | Fase 2 |
| Formato 608 (anulados) | ❌ | `fiscal_documents.status='cancelled'` ya se marca | Fase 2 |
| Formato 609 (pagos al exterior) | ❌ | — | Fase 2 |
| Retenciones ISR / ITBIS | ❌ | — | Fase 2 (cuentas ya sembradas: 210202, 210203, 110402) |
| Archivos compatibles con prevalidador DGII | ❌ | — | Fase 2 (TXT delimitado por `\|`) |
| Conciliación formatos ↔ contabilidad | ❌ | — | Fase 2 (cruce 607 vs. 210201) |

### 2.3 Ventas y cuentas por cobrar

| Requisito | Antes | Dónde | Fase 1 |
|---|---|---|---|
| Clientes | ✅ | `customers`, `/customers` | — |
| Validación de RNC / cédula | 🟡 | se captura, no se valida contra DGII | Fase 3 |
| Facturas | ✅ | `fiscal_documents` | — |
| Cotizaciones | ❌ | — | Fase 3 |
| Notas de crédito / débito | 🟡 | tipo NCF existe; no hay flujo de emisión | Fase 3 |
| Recibos de ingreso | 🟡 | abonos en `credit_payments` sin documento numerado | Fase 3 |
| Cobros parciales | ✅ | `fn_register_credit_abono` | — |
| Anticipos | ❌ | — | Fase 3 |
| Antigüedad de saldos | 🟡 | `/credits` muestra vencidos, sin tramos 30/60/90 | Fase 3 |
| Estados de cuenta | ❌ | — | Fase 3 |
| Registro contable automático | ❌ | — | 🟢 ventas + abonos generan asiento |

### 2.4 Compras y cuentas por pagar

| Requisito | Antes | Dónde | Fase 1 |
|---|---|---|---|
| Proveedores | ✅ | `suppliers` (con `rnc`) | — |
| Órdenes de compra y facturas | ✅ | `purchase_orders` + `invoice_number` | — |
| Notas de crédito de compra | ❌ | — | Fase 3 |
| Gastos recurrentes | ❌ | — | Fase 3 |
| Retenciones ISR / ITBIS | ❌ | — | Fase 2 |
| Pagos parciales | ✅ | `fn_register_supplier_credit_payment` | — |
| Anticipos a proveedores | ❌ | — | Fase 3 |
| Antigüedad de CxP | 🟡 | `/credits` pestaña CxP | Fase 3 |
| Registro automático gasto/impuesto/deuda | ❌ | — | 🟢 generador de compras |

### 2.5 Caja y bancos

| Requisito | Antes | Dónde | Fase 1 |
|---|---|---|---|
| Caja general | ✅ | `cash_registers`, `cash_register_sessions`, arqueos | — |
| Caja chica | ❌ | — | Fase 4 (cuenta 110102 ya sembrada) |
| Cuentas bancarias | ✅ | `bank_accounts` (`20260508_0005`) | — |
| Depósitos / cheques / transferencias | 🟡 | transferencias sí; depósitos y cheques no | Fase 4 |
| Conciliación bancaria | ❌ | — | Fase 4 |
| Importación de estados bancarios | ❌ | — | Fase 4 |
| Flujo de efectivo | 🟡 | `finance_report_view` es de caja, no estado formal | Fase 4 |
| Registro contable automático | ❌ | — | 🟢 gastos y retiros de caja |

### 2.6 Seguridad y requisitos técnicos

| Requisito | Antes | Dónde | Fase 1 |
|---|---|---|---|
| Usuarios y roles por función | ✅ | `access_control_catalog.dart`, `roles`, `role_permissions` | — |
| Permisos separados crear/aprobar/contabilizar/pagar/anular/cerrar | 🟡 | granularidad existe, faltaban los contables | 🟢 6 permisos `contabilidad.*` |
| Copias de seguridad automáticas | 🟡 | infra VPS/Coolify, fuera de la app | Fase 5 (operativo) |
| Bitácora de auditoría no editable por usuarios | 🟡 | `audit_logs` existe | 🟢 asientos posteados inmutables por trigger; bitácora completa en Fase 5 |
| Sesiones con vencimiento automático | 🟡 | Supabase JWT refresh, sin expiración por inactividad | Fase 5 |
| Exportación a Excel y PDF | 🟡 | CSV (`ReportExporter`) + deps `excel`/`pdf` en `pubspec` | 🟢 CSV / XLSX / PDF en diario, mayor, balanza, resultados y balance |
| Prueba periódica de restauración | ❌ | — | Fase 5 (operativo, fuera de la app) |

---

## 3. Arquitectura de la Fase 1

### 3.1 Modelo de datos (migración `20260805_0001_accounting_core.sql`)

```
accounting_settings        1 fila por negocio: mes de inicio fiscal, moneda, cuentas especiales
accounting_accounts        catálogo jerárquico (parent_id), tipo, is_postable
accounting_cost_centers    centro de costo / departamento / proyecto / sucursal
accounting_periods         (year, month) con status open/closed
accounting_entries         asiento: número correlativo por negocio, fecha, período, origen, status
accounting_entry_lines     línea: cuenta, centro de costo, débito, crédito
accounting_account_mappings  evento contable → cuenta (lo que hace configurables los automáticos)
```

**Integridad:**
- Una línea no puede tener débito y crédito a la vez.
- Un asiento posteado no se puede editar ni borrar (trigger `fn_accounting_guard_immutable`);
  solo se revierte con un asiento espejo que queda enlazado en ambos sentidos.
- `unique(business_id, source_type, source_id)` → un documento origen genera **un** asiento.
  Re-correr un generador sobre el mismo rango no duplica nada.
- Posteo en período cerrado → excepción `PERIOD_CLOSED`.
- Débitos ≠ créditos → excepción `UNBALANCED_ENTRY`.

### 3.2 Mapeo de eventos → cuentas

`accounting_account_mappings` traduce un evento del POS a una cuenta. Se siembra con
el catálogo y el contador del negocio lo puede reasignar sin tocar código:

| `event_key` | Cuenta por defecto |
|---|---|
| `cash` | 110101 Caja general |
| `petty_cash` | 110102 Caja chica |
| `bank` | 110103 Bancos |
| `card_clearing` | 110104 Tarjetas por liquidar |
| `ar_customers` | 110201 CxC clientes |
| `inventory` | 110301 Inventario |
| `itbis_credit` | 110401 ITBIS adelantado (compras) |
| `ap_suppliers` | 210101 CxP proveedores |
| `itbis_payable` | 210201 ITBIS por pagar (ventas) |
| `tips_payable` | 210301 Propinas por pagar |
| `service_fee_payable` | 210302 Servicio por pagar |
| `sales_revenue` | 410101 Ventas |
| `delivery_revenue` | 410102 Ingresos por delivery |
| `sales_discounts` | 410201 Descuentos en ventas |
| `other_income` | 420101 Otros ingresos |
| `cogs` | 510101 Costo de ventas |
| `cash_expense` | 610108 Gastos varios de caja |
| `rounding` | 610201 Diferencias y redondeo |
| `payment_method:cash` / `:card` / `:transfer` / `:credit` | cuenta de contrapartida del cobro |

### 3.3 Generadores automáticos (idempotentes, por rango de fechas)

**Ventas — un asiento por día** (`source_type='sales'`, `source_id = uuid determinístico del día`):

```
DEBE   Caja / Banco / Tarjetas / CxC     ← sum(payments) del día por método
DEBE   410201 Descuentos en ventas       ← sum(orders.discounts)
HABER  410101 Ventas                     ← sum(orders.subtotal)
HABER  210201 ITBIS por pagar            ← sum(orders.tax)
HABER  210302 Servicio por pagar         ← sum(orders.service_fee)
[± 610201 Diferencias]                   ← residuo si descuadra por redondeo
```

Base: órdenes con `status='paid'` cuyo `closed_at` cae en el día según el timezone
del negocio (`business_settings.timezone`), unidas al negocio vía
`table_sessions.business_id` (`orders` no tiene `business_id`).

**Compras — un asiento por orden recibida** (`source_type='purchase'`):

```
DEBE   110301 Inventario                 ← subtotal
DEBE   110401 ITBIS adelantado           ← tax
HABER  210101 CxP proveedores            ← total, si existe supplier_credit de esa OC
   o   HABER 110101 Caja                 ← total, si fue compra de contado
```

**Caja — un asiento por movimiento** (`source_type='cash_txn'`): gastos y retiros
manuales (`type in ('expense','withdrawal')`, sin `related_order_id`). Si la razón
(`cash_transaction_reasons`) tiene cuenta contable asignada se usa esa; si no,
610108. **Se excluyen** los movimientos que generan las RPC de crédito
(`'Abono crédito CxC %'` y `'Pago CxP %'`) porque esos los emite su propio generador —
evita doble conteo.

**Créditos** (`source_type='credit_payment'` / `'supplier_payment'`):

```
Abono CxC:  DEBE Caja/Banco        HABER 110201 CxC clientes
Pago CxP:   DEBE 210101 CxP        HABER Caja/Banco
```

### 3.4 Lo que la Fase 1 deliberadamente NO hace

- **Costo de ventas (COGS) automático.** La cuenta y el mapeo existen pero no se
  postea: requiere decidir el método de valuación contra `inventory_movements`
  (ver `project_cost_last_price_policy` — hoy el costo maestro es último precio).
  Sin eso, el estado de resultados muestra ingresos y gastos pero **no margen bruto real**.
- **Depósitos manuales de caja** (`type='deposit'`): quedan fuera del generador
  porque hoy no se distinguen de forma confiable de los abonos de crédito.
  Fase 2 agrega `cash_transactions.source` para separarlos.
- **Cierre anual con traspaso a resultados acumulados**: el balance general calcula
  el resultado del ejercicio al vuelo; no hay asiento de cierre todavía.
- **Propinas**: el POS no persiste la propina a nivel de orden (`fiscal_documents.tip`
  sí la tiene), así que 210301 queda sembrada pero sin movimiento automático.

---

## 4. Roadmap

| Fase | Alcance | Estado |
|---|---|---|
| **F1 — Núcleo contable** | Catálogo, períodos, asientos manuales y automáticos, diario, mayor, balanza, estados financieros, centros de costo, permisos, reversión, inmutabilidad | ✅ implementada |
| **F2 — DGII** | 606, 607, 608, 609, retenciones ISR/ITBIS, TXT del prevalidador, conciliación formato ↔ contabilidad. Requiere: NCF y RNC en compras, tipo de bien/servicio, `cash_transactions.source` | ⏳ |
| **F3 — CxC / CxP completo** | Cotizaciones, notas de crédito/débito, recibos de ingreso numerados, anticipos, antigüedad 30/60/90, estados de cuenta, gastos recurrentes | ⏳ |
| **F4 — Caja y bancos** | Caja chica, cheques, conciliación bancaria, importación de estados de cuenta, flujo de efectivo formal | ⏳ |
| **F5 — Cierre técnico** | COGS automático, asiento de cierre anual, bitácora completa de auditoría, expiración de sesión por inactividad, respaldos verificados | ⏳ |

---

## 5. Puesta en marcha (Fase 1)

1. Aplicar `supabase/migrations/20260805_0001_accounting_core.sql`.
2. En la app: **Más Opciones → Contabilidad**. La primera entrada ofrece
   *Inicializar contabilidad*, que llama a `fn_accounting_seed_chart` y siembra
   catálogo + mapeos del negocio activo.
3. Conceder los permisos `contabilidad.*` al rol correspondiente en
   **Configuración → Usuarios → Roles y Permisos** (owner/admin ya pasan por rol).
4. En **Asientos → Generar automáticos**, elegir rango y correr. Es idempotente:
   se puede correr todos los días sobre el mes en curso sin duplicar.
5. Al cerrar el mes: **Períodos → Cerrar**. A partir de ahí ese mes rechaza asientos.

**Rollback:** `20260805_0001_accounting_core_ROLLBACK.sql` borra las tablas
`accounting_*`, las funciones y la columna agregada a `cash_transaction_reasons`.
No toca ninguna tabla del POS.
