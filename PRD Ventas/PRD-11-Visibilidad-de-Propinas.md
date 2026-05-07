# PRD-11 — Visibilidad de Propinas Voluntarias

| Campo | Valor |
|---|---|
| **Programa** | Fiscal Stabilization Program |
| **Status** | Draft — pendiente de aprobación |
| **Owner / DRI** | Cristian Gómez |
| **Pattern** | Strangler fig (capa nueva sobre reportes existentes; cero cambios destructivos) |
| **PRD previos directos** | PRD-01 (motor fiscal), PRD-03 (reportes), PRD-05 (printing) |
| **Última actualización** | 2026-05-07 |

> **Nota de numeración**: el documento se nombró PRD-11 porque PRD-07 ya está ocupado por `PRD_07_AGENT_USB.md`. El nombre solicitado originalmente era `PRD-07-Visibilidad-de-Propinas.md`; se ajustó al siguiente número libre.

---

## 1. Contexto y motivación

### 1.1. El gap

Mientras analizaba ventas por categoría descubrí que los reportes oficiales muestran un total mayor al `SUM(orders.total)`. La diferencia es **propina voluntaria pagada en efectivo**, registrada como exceso en `payments.amount` sin facturar. Hoy queda como diferencia oculta y el comerciante tiene que cuadrarla mentalmente.

**Evidencia (rango 28 abr → 1 may 2026):**

| Concepto | Monto |
|---|---:|
| `fiscal_documents.total` (lo facturado) | RD$ 9,212.30 |
| `fiscal_documents.tip` (propina legal 10%) | 0.00 |
| `orders.service_fee` (cargo por servicio) | 0.00 |
| `SUM(payments.amount - change_amount)` (lo que entró a caja) | 9,993.00 |
| **Diferencia (propina voluntaria, no facturada)** | **780.70** |

5 órdenes con propina voluntaria entre RD$14.45 y RD$429.88 — rondan el ~10% pero no son exactas, confirmando que es propina al estilo "quédate con el cambio" y NO la propina legal de Ley 16-92.

### 1.2. Diferenciación de los dos tipos de propina

| | **Propina legal (Ley 16-92)** | **Propina voluntaria** |
|---|---|---|
| Origen | Cobrada por el sistema, configurable por negocio | Cliente paga más de lo facturado |
| Ubicación BD | `fiscal_documents.tip`, `orders.service_fee` | `payments.amount - change_amount - orders.total` |
| Aparece en NCF | Sí (línea separada) | No |
| Lleva ITBIS | No | No |
| Calculado por | Sistema, exacto al centavo | Cliente, redondeada |
| Atribución por empleado | No (es del establecimiento) | Sí (mesero/cajero que atendió) |

### 1.3. Casos de uso del comerciante

1. **Cuadre diario**: el dueño cierra caja y debe poder distinguir qué entró por ventas vs qué entró por propina (no es ingreso del negocio sino del empleado).
2. **Reporte de propinas por mesero**: pago semanal/mensual de propinas a meseros — hoy se calcula a mano contra recibos.
3. **Auditoría fiscal**: la propina voluntaria no debe sumarse a ventas declaradas (no lleva ITBIS), pero sí debe cuadrar con el efectivo en caja.
4. **Análisis comercial**: % de propina vs venta como métrica de satisfacción del cliente.

---

## 2. Objetivos

### 2.1. Primarios

1. **Cero diferencias ocultas en cuadre de caja**: cualquier diferencia entre `SUM(payments.amount)` y `SUM(orders.total) + SUM(propinas)` es un bug, no un "ajuste mental" del comerciante.
2. **Línea explícita de "Propinas voluntarias"** en reportes de venta y cierre de caja, separada de ventas.
3. **Reporte de propinas por empleado** — mesero/cajero/turno, con totales y promedios.
4. **Cálculo único reusable** — vista o función SQL que cualquier reporte consume; nunca duplicar la fórmula `amount - change - total` en código cliente.

### 2.2. Secundarios

1. Métricas de propina (% sobre venta, ticket promedio con propina) en el dashboard de reportes.
2. Auditoría: poder reasignar la atribución de una propina si el cajero se equivocó al cobrar.
3. Soporte para "propina dividida" entre múltiples empleados (sólo si la operación lo amerita; por ahora 1 empleado por payment).

### 2.3. Fuera de alcance (este PRD)

- **Cálculo y configuración de la propina legal del 10%**: ya resuelto por PRD-01 (motor fiscal). Aquí solo se consume.
- **Liquidación de pago de propinas** a empleados (planilla / nómina): otro módulo.
- **Propinas con tarjeta** registradas como cargo separado en el datáfono: depende de PRD-10 (Pagos Integrados Datáfono); aquí se asume que mientras tanto la propina con tarjeta se ingresa como exceso al total igual que la propina en efectivo.
- **Cobro recargo automático para propina voluntaria** (estilo "agregar 18% como propina sugerida"): cambio de UX cobranza, no es visibilidad.
- **Tocar la duplicación `quantity`/`qty` en `order_items`**: deuda técnica conocida; permanece como está.

---

## 3. Decisiones arquitectónicas

### DA-1 · Cálculo en BD vía vista SQL, no en cliente

La fórmula `tip_amount = max(0, payments.amount - change_amount - per-payment-share-of-orders.total)` vive en una **vista SQL** (`v_payment_tips`). Cualquier reporte (Flutter, Edge Functions, queries ad-hoc en Supabase Studio) consume la vista — no replica la fórmula.

**Justificación**: sin esto el motor de reportes Dart, el ticket de cierre, el dashboard analytics y los queries one-off del dueño se desincronizan. Una vista garantiza consistencia.

**Alternativa descartada**: columna materializada `tip_amount` en `payments` actualizada por trigger. Más rápida en lecturas pero introduce desincronización si la orden cambia post-cobro (refund parcial, anulación). Si la performance se vuelve un problema en F3, se evalúa migrar a materialized view; no antes.

### DA-2 · Atribución a un empleado por payment, en `payments.tip_recipient_user_id`

Una propina pertenece al empleado que cobró el ticket, no se divide entre meseros. Se modela como columna nullable `tip_recipient_user_id uuid REFERENCES auth.users(id)` en `payments`.

**Justificación**: 95% de los casos de un restaurante tipo medio dominicano = un mesero atiende, un cajero cobra, la propina es del mesero (o se reparte por convención offline en la cocina, fuera del POS). Modelar splits dentro del POS añade complejidad de UI y de cuadre que no resuelve un dolor real hoy.

**Asunción ajustable**: si en producción se descubre que los negocios sí necesitan splits (ej. restaurantes grandes con propinas pooled), migrar a tabla dedicada `tips(payment_id, recipient_user_id, amount)` en F2.5 sin tocar cómo se computa el monto total (sigue saliendo de `v_payment_tips`).

### DA-3 · Default de atribución = mesero de la sesión, no cajero

Cuando un cajero cierra una mesa atendida por otro mesero, la propina por default va al **mesero asignado a la sesión** (`table_sessions.waiter_user_id` cuando aplica), no al cajero que ejecuta el cobro. El cajero ve un dropdown editable con la sugerencia preseleccionada.

**Justificación**: regla cultural; el cajero no se queda con la propina del mesero. El dropdown editable cubre el caso "el cliente fue atendido por X pero quiere que la propina sea para Y" (raro pero posible).

**Fallback** cuando la orden no tiene mesero (ventas rápidas, manual orders): atribuir al `processed_by` (cajero) como sugerencia.

### DA-4 · Strangler fig — los reportes legacy NO se modifican, se ignoran

El reporte SQL viejo que hoy dice "ventas = 9,993" sigue diciendo eso (no se rompe). Pero en Flutter el `ReportsViewModel` empieza a consumir un nuevo **endpoint/RPC** (`fn_sales_with_tips`) que devuelve `ventas_facturadas`, `propinas_legales`, `propinas_voluntarias`, `total_caja` por separado. La UI presenta el desglose; el query viejo queda como fallback temporal hasta que el migration esté validado en prod por al menos 7 días.

### DA-5 · Cálculo per-payment, no per-order

Cuando una orden tiene 2+ payments parciales, cada payment puede llevar su propio exceso. La vista calcula la propina a nivel de payment ponderando por `amount / SUM(amount per order)`. Si se prefiere atribuir todo el exceso al último payment de la orden (regla operativa común), se documenta y se cambia el lado SQL — no afecta cómo se consume.

**Default propuesto**: distribución proporcional al `amount` de cada payment dentro de la orden. Si en F1.1 el caller indica una preferencia operacional distinta, se ajusta.

---

## 4. Modelo de datos

### 4.1. Cambios de schema (mínimos)

**Migration `20260507_0010_payments_tip_recipient.sql`** (nombre tentativo, se ajusta a la fecha de aplicación):

```sql
-- Atribución de propina voluntaria al empleado que la recibe.
-- NULL = sin atribución (legacy o el cajero no la asignó).
ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS tip_recipient_user_id uuid
    REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_payments_tip_recipient
  ON public.payments(tip_recipient_user_id)
  WHERE tip_recipient_user_id IS NOT NULL;

COMMENT ON COLUMN public.payments.tip_recipient_user_id IS
  'PRD-11: empleado al que se atribuye la propina voluntaria de este '
  'pago. NULL = legacy o no asignada. La propina se calcula en '
  'v_payment_tips; este campo solo guarda la atribución.';
```

### 4.2. Vista canónica `v_payment_tips`

```sql
-- Calcula la propina voluntaria por payment. Estructura cerrada para
-- que cualquier reporte la consuma sin replicar la fórmula.
CREATE OR REPLACE VIEW public.v_payment_tips
WITH (security_invoker = on) AS
WITH payment_totals_per_order AS (
  SELECT
    order_id,
    SUM(amount - COALESCE(change_amount, 0)) AS net_paid
  FROM public.payments
  WHERE status = 'completed'
  GROUP BY order_id
)
SELECT
  p.id                       AS payment_id,
  p.business_id,
  p.session_id,
  p.order_id,
  p.processed_by,
  p.tip_recipient_user_id,
  p.created_at,
  -- Propina voluntaria: lo que sobra de este payment después de cubrir
  -- su porción del total de la orden, ponderado por su % del net_paid.
  -- GREATEST(0, ...) protege contra órdenes sobre-pagadas seguidas de
  -- refund parcial donde el cálculo daría negativo transitorio.
  GREATEST(
    0,
    (p.amount - COALESCE(p.change_amount, 0))
    - (
        o.total
        * (p.amount - COALESCE(p.change_amount, 0))
        / NULLIF(pt.net_paid, 0)
      )
  )::numeric(12,2) AS tip_amount
FROM public.payments p
JOIN public.orders o          ON o.id = p.order_id
JOIN payment_totals_per_order pt ON pt.order_id = p.order_id
WHERE p.status = 'completed';

COMMENT ON VIEW public.v_payment_tips IS
  'PRD-11: propina voluntaria calculada per-payment. tip_amount = '
  'exceso del payment sobre su porción ponderada del orders.total. '
  'NO incluye propina legal (esa va en fiscal_documents.tip).';
```

**Notas**:
- `security_invoker = on` → la vista hereda el RLS del caller; no se escapa de las políticas existentes en `payments` y `orders`.
- Se filtra a `status = 'completed'` para no contar pagos en proceso o reversos.

### 4.3. Vista de cuadre `v_session_cash_summary`

```sql
-- Resumen por turno/sesión de caja. Reemplaza el cálculo en cliente
-- del cierre. Se usa también en el reporte de propinas por empleado.
CREATE OR REPLACE VIEW public.v_session_cash_summary
WITH (security_invoker = on) AS
SELECT
  s.id                    AS session_id,
  s.business_id,
  s.opened_at,
  s.closed_at,
  -- Lo facturado (no incluye propina ni voluntaria ni legal)
  COALESCE(SUM(o.total), 0)::numeric(12,2)   AS ventas_facturadas,
  -- Propina legal del motor fiscal (ya factura con NCF)
  COALESCE(SUM(o.service_fee), 0)::numeric(12,2) AS propinas_legales,
  -- Propina voluntaria agregada
  COALESCE((
    SELECT SUM(tip_amount)
    FROM public.v_payment_tips vpt
    WHERE vpt.session_id = s.id
  ), 0)::numeric(12,2) AS propinas_voluntarias,
  -- Total efectivo entrado a caja
  COALESCE((
    SELECT SUM(amount - COALESCE(change_amount, 0))
    FROM public.payments
    WHERE session_id = s.id AND status = 'completed'
  ), 0)::numeric(12,2) AS total_caja
FROM public.table_sessions s
LEFT JOIN public.orders o ON o.session_id = s.id AND o.status = 'paid'
GROUP BY s.id, s.business_id, s.opened_at, s.closed_at;
```

**Invariante**: `ventas_facturadas + propinas_legales + propinas_voluntarias = total_caja`. Cualquier desviación es un bug.

### 4.4. RPC para reportes de Flutter

```sql
CREATE OR REPLACE FUNCTION public.fn_tips_by_employee(
  p_business_id uuid,
  p_from        timestamptz,
  p_to          timestamptz
) RETURNS TABLE (
  recipient_user_id uuid,
  full_name         text,
  tip_count         int,
  tip_total         numeric(12,2),
  tip_avg           numeric(12,2)
) ...  -- Cuerpo en F1.1
```

**No tocar PRD-01**: este PRD no modifica `fiscal_documents`, `fn_compute_item_totals`, ni nada del motor fiscal. Solo lee.

---

## 5. Arquitectura de código (Flutter)

```
lib/
├── data/
│   ├── repositories/
│   │   └── tips_repository.dart           # NUEVO
│   └── models/
│       └── tip_models.dart                # NUEVO (PaymentTip, TipsByEmployee, SessionCashSummary)
├── presentation/
│   ├── reports/
│   │   ├── view/
│   │   │   ├── reports_view.dart          # MODIFICAR — añadir sección "Propinas"
│   │   │   └── tips_by_employee_view.dart # NUEVO
│   │   └── viewmodel/
│   │       ├── reports_viewmodel.dart     # MODIFICAR — consumir SessionCashSummary
│   │       └── tips_viewmodel.dart        # NUEVO
│   ├── cashier/
│   │   └── widgets/
│   │       └── close_session_summary.dart # MODIFICAR — añadir línea propinas
│   └── payments/
│       └── widgets/
│           └── tip_recipient_picker.dart  # NUEVO (dropdown en cobranza)
└── services/
    └── printing/
        └── print_ticket_service.dart      # MODIFICAR — sección propinas en cierre
```

**Repositorio**: `TipsRepository.fetchByEmployee(businessId, fromDate, toDate)` consume el RPC `fn_tips_by_employee`. `fetchSessionSummary(sessionId)` consume `v_session_cash_summary`.

**Cero lógica de cálculo en Dart** (DA-1).

---

## 6. Plan de fases con DoD

### F1 — Visibilidad básica sin atribución

> Objetivo: el cierre de caja y el reporte de ventas dejan de tener "diferencia oculta". Aún no se asigna a empleados.

**F1.1 — Migration + vistas**
- Crear `v_payment_tips`, `v_session_cash_summary`.
- NO crea `payments.tip_recipient_user_id` todavía (eso es F2).
- Smoke test: ejecutar contra los 5 casos de evidencia y verificar `tip_amount` por payment.
- **DoD**: contra los datos del 28 abr → 1 may, `SUM(v_session_cash_summary.propinas_voluntarias)` = 780.70 ± 0.05 (ajuste de redondeo).

**F1.2 — Reportes de venta**
- `ReportsViewModel` consume `v_session_cash_summary` en lugar del query legacy.
- Sección nueva "Propinas voluntarias" en el reporte de ventas, separada de "Ventas".
- Reporte legacy queda accesible como toggle "Vista anterior" durante 7 días para validar.
- **DoD**: el dueño puede abrir el reporte de un día arbitrario y ver venta + propina como líneas distintas, suma = total que entró a caja.

**F1.3 — Cierre de caja**
- `CloseSessionSummary` lee de `v_session_cash_summary`.
- Ticket de cierre (PRD-05) imprime una sección nueva:
  ```
  VENTAS FACTURADAS .... 9,212.30
  PROPINAS VOLUNTARIAS .   780.70
  ────────────────────────────────
  TOTAL CAJA ........... 9,993.00
  ```
- **DoD**: el comerciante cierra caja y el ticket muestra explícitamente las propinas; el `TOTAL CAJA` cuadra con efectivo contado sin cuentas mentales.

### F2 — Atribución por empleado

> Objetivo: poder ver y pagar propinas por mesero / cajero / turno.

**F2.1 — Schema + UI cobranza**
- Migration `payments.tip_recipient_user_id`.
- `TipRecipientPicker` en la pantalla de cobranza: aparece sólo si el payment tiene exceso > 0; preselecciona el mesero de la sesión (DA-3); editable.
- Persiste en el INSERT del payment.
- **DoD**: cobrar una orden con propina deja `tip_recipient_user_id` populado en al menos el 90% de los casos del primer día post-rollout.

**F2.2 — RPC + repo**
- `fn_tips_by_employee(business_id, from, to)`.
- `TipsRepository.fetchByEmployee`.
- **DoD**: la RPC, llamada con un rango de 1 mes y un negocio típico, responde en < 500ms.

**F2.3 — Reporte de propinas por empleado**
- `tips_by_employee_view.dart`: tabla con columnas (Empleado, # propinas, Total RD$, Promedio RD$).
- Filtros: rango de fechas, empleado individual, turno.
- Export a CSV/PDF (alineado con PRD-03).
- **DoD**: el dueño exporta el reporte semanal de propinas y lo usa para el pago a meseros sin modificarlo manualmente.

### F2.5 (condicional) — Splits de propina entre empleados

> Sólo se activa si en producción se confirma que los negocios reales lo necesitan. **Default: no se construye.**

- Tabla nueva `payment_tip_splits(payment_id, recipient_user_id, amount, percentage)`.
- UI: chip multi-select en `TipRecipientPicker`.
- `v_payment_tips` y `fn_tips_by_employee` se actualizan para resolver: si hay splits, los usa; si no, cae al `tip_recipient_user_id` único.
- **DoD**: documentado y testeado; activado por feature flag por business.

### F3 — Hardening + métricas

**F3.1 — Backfill histórico**
- Script idempotente que asigna `tip_recipient_user_id` retroactivamente a payments con `tip_amount > 0` usando heurística: mesero de sesión > processed_by.
- **DoD**: % de payments con propina y atribución > 95% para data histórica.

**F3.2 — Dashboard métricas**
- Tarjetas en el dashboard: % órdenes con propina, monto promedio, top 5 meseros por propina del mes.
- **DoD**: las métricas refrescan sin lag visible en una jornada típica (~200 órdenes).

**F3.3 — Auditoría**
- Permiso para que admin reasigne `tip_recipient_user_id` post-cobro (con log de cambios).
- **DoD**: cualquier cambio queda registrado en `audit_logs` (tabla existente).

---

## 7. UX

### 7.1. Pantalla de cobranza

Cuando el cajero confirma un pago en efectivo y el cliente paga más del total:

```
TOTAL ORDEN ............. RD$ 5,072.62
RECIBIDO ................ RD$ 5,502.50
CAMBIO .................. RD$     0.00
─────────────────────────────────────
PROPINA VOLUNTARIA ...... RD$   429.88

Asignar propina a:
┌─────────────────────────────────┐
│ ▾ María Pérez (mesero)          │
└─────────────────────────────────┘
   ☐ Repartir entre varios (F2.5, oculto si flag off)
```

La propina aparece **sólo si > 0**; el dropdown sólo aparece **cuando hay propina**.

### 7.2. Reporte de ventas

```
RESUMEN DEL DÍA — 30 Abr 2026

Ventas facturadas .............. RD$  9,212.30
   Subtotal ....................     7,815.51
   ITBIS .......................     1,396.79

Propinas
   Legal (10%) .................     0.00
   Voluntaria ..................   780.70    ← antes oculta

────────────────────────────────────────
TOTAL CAJA ..................... RD$  9,993.00
```

### 7.3. Reporte de propinas por empleado (F2.3)

```
Propinas — 1 abr → 30 abr 2026

EMPLEADO            # PROPINAS    TOTAL          PROMEDIO
─────────────────────────────────────────────────────────
María Pérez               18      RD$ 4,250.00   RD$  236.11
Luis Rodríguez            12      RD$ 2,890.00   RD$  240.83
Sin asignar                3      RD$   145.00   RD$   48.33
─────────────────────────────────────────────────────────
TOTAL                     33      RD$ 7,285.00
```

### 7.4. Ticket de cierre de caja

```
─── CIERRE DE CAJA ───
Mesero: María
Apertura: 02:00 PM
Cierre:  10:30 PM

VENTAS FACTURADAS ....  9,212.30
PROPINAS VOLUNTARIAS .    780.70
────────────────────────────────
TOTAL CAJA ...........  9,993.00

Efectivo contado .....  9,993.00
DIFERENCIA ...........      0.00 ✓
```

---

## 8. Encaje con PRDs previos

| PRD | Relación |
|---|---|
| **PRD-01 Motor fiscal** | Solo se consume. `service_fee` y `fiscal_documents.tip` siguen siendo la fuente de la propina legal del 10%. PRD-11 nunca escribe en estas columnas. |
| **PRD-03 Reportes** | Se reusa la infraestructura de export CSV/PDF. La sección de propinas se inserta en `reports_view.dart` siguiendo el patrón de las secciones existentes. |
| **PRD-05 Printing** | El ticket de cierre se modifica vía `print_ticket_service.dart`. La sección nueva sigue el formato establecido por PRD-05 (header inverso, separadores `=`, layout 2x). |
| **PRD-10 Datáfono** | Punto de coordinación: cuando PRD-10 entregue propinas con tarjeta como un campo separado del cobro (no como exceso), `v_payment_tips` debe sumar ambas fuentes. Coordinación al cierre de PRD-10. |
| **PRD-04 Módulos venta** | El `TipRecipientPicker` se inserta en el flow de cobranza (`payments_view`); reutiliza el selector de empleados existente. |

---

## 9. Riesgos y mitigaciones

| # | Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|---|
| R1 | El cálculo per-payment ponderado no matchea la regla operativa real ("la propina va al último payment") | Media | Reportes con números distintos a los esperados | F1.1 publica los dos cálculos en la vista (`tip_amount_proportional`, `tip_amount_last_payment`) y el reporte deja al usuario elegir; en F2 se decide cuál es default. |
| R2 | Reportes legacy en producción siguen mostrando los números viejos y confunden al comerciante | Alta | Crisis de confianza en los nuevos números | DA-4: toggle "Vista anterior" durante 7 días + comunicación clara en el changelog. |
| R3 | `tip_recipient_user_id` queda NULL para 70% de los payments porque el cajero salta el dropdown | Media | Reporte por empleado inservible | F2.1 hace que el dropdown tenga preselección automática y el botón "Cobrar" la respeta sin click extra. Métrica de seguimiento en F3.2. |
| R4 | RLS de `v_payment_tips` filtra demasiado y reportes salen vacíos | Baja | Bug bloqueador | `security_invoker = on` + smoke test en F1.1 con un user no-admin contra un business con datos. |
| R5 | Migration de `payments.tip_recipient_user_id` bloquea inserts en prod por lock | Baja | Caja parada momentáneamente | `ADD COLUMN IF NOT EXISTS` con DEFAULT NULL es metadata-only en Postgres ≥ 11; no rewrite. Aplicar en horario nocturno por seguro. |
| R6 | Order con refund parcial post-cobro deja `tip_amount` negativo | Baja | Inconsistencia visible | `GREATEST(0, ...)` en la vista. Documentado en DA-1. |

---

## 10. Métricas de éxito

| Métrica | Target | Cómo se mide |
|---|---|---|
| Diferencias en cuadre de caja entre Flutter y SQL | 0 | `v_session_cash_summary.total_caja - sum(payments)` debe ser 0 ± 0.05 en 100% de las sesiones. |
| % de payments con propina y `tip_recipient_user_id` populado | > 90% (después de 30 días F2) | Query simple sobre `payments`. |
| Tiempo de respuesta `fn_tips_by_employee` para 1 mes | < 500 ms | EXPLAIN ANALYZE + telemetría Flutter. |
| Adopción reporte propinas por empleado | ≥ 1 export/semana por business activo | Telemetría event "tips_report_exported". |
| Reducción de tickets de soporte tipo "no me cuadra la caja" | -50% post F1.3 | Log de tickets de soporte (cualitativo). |

---

## 11. Próximos pasos inmediatos

1. **Aprobar el PRD** (este documento) — confirmar DA-1 a DA-5 o pedir ajustes.
2. **Decidir DA-5 (per-payment vs último payment)** — preguntar al comerciante cuál es la regla de cómo se entiende la propina cuando hay 2+ payments.
3. **Aplicar Migration F1.1** en staging:
   - Crear `v_payment_tips` y `v_session_cash_summary`.
   - Smoke test contra los 5 casos de evidencia (28 abr → 1 may).
4. **Branch `feat/prd-11-tips-visibility`** para F1.2 (reportes Flutter).
5. **Coordinar con PRD-10**: cuando entregue propinas con tarjeta como columna separada, sumarlas en `v_payment_tips`.

---

## Anexo — Datos de evidencia (rango 28 abr → 1 may 2026)

| Orden | Facturado | Pagado neto | Propina voluntaria |
|---|---:|---:|---:|
| 961db995 | 5,072.62 | 5,502.50 | 429.88 |
| a35aa7f9 | 1,623.55 | 1,756.36 | 132.81 |
| 2dffc301 | 170.55 | 185.00 | 14.45 |
| a1a0fabc | 2,111.60 | 2,290.55 | 178.95 |
| 226968cb | 290.39 | 315.00 | 24.61 |
| **Total** | **9,268.71** | **10,049.41** | **780.70** |

Validación de F1.1 = los `tip_amount` de la vista deben matchear esta tabla al centavo (modulo 0.05 por redondeo).
