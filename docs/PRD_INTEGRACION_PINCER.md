# PRD — Integración Pincer → MangoPOS (canal de pedidos online)

> **Estado:** Borrador R3 — flujo pre-filtrado acordado con Pincer
> **Fecha:** 2026-09-04 · **R2:** 2026-09-05 · **R3:** 2026-09-07
> **Dueño de producto:** Cristian Gómez
> **Contraparte:** Tamayo Belliard (Pincer) — tamayobelliardinvest@gmail.com · 829-548-1236
> **Piloto:** Tropella Coffee & Tea
> **Ámbito:** Que un pedido tomado en Pincer y **aceptado por la cajera en la tablet
> de Pincer** entre solo al POS como pedido de delivery/pickup, imprima comanda, llegue
> al KDS y siga el flujo normal de caja, cierre, NCF y reportes.
> **R3 — cambio de flujo:** el pedido ya no entra crudo al POS. Pincer lo filtra primero
> (§3.1). Elimina el rechazo por producto agotado del lado del POS y casi todo el caso
> de cancelación tardía.
> **Relación con otros PRDs:** mismo motor de
> [PRD_UBER_EATS_INTEGRATION.md](PRD_UBER_EATS_INTEGRATION.md) Fase 1, sin OAuth ni
> certificación. Lo que se construya queda listo para Uber Eats y PedidosYa.

---

## 0. Alcance (cerrado con ambas partes)

| # | Tema | Decisión |
|---|---|---|
| A | Pedido online (delivery / pickup) que entra solo, imprime comanda, ya viene pagado | ✅ **F1** |
| B | Sumar líneas a una cuenta de mesa abierta | ⛔ **2ª etapa** — acordado con Pincer el 2026-09-05 |
| C | Pay-at-table (leer y cobrar la cuenta desde el teléfono) | ⛔ **2ª etapa** |
| D | Cancelación desde Pincer hacia el POS | ✅ **F1** — es una **anulación fiscal**, no un cancel liviano (§5.5) |
| E | Cancelación desde el POS hacia Pincer (webhook saliente) | ✅ **F1** — la integración deja de ser unidireccional (§5.6) |
| F | **Aceptación del pedido en la tablet de Pincer, antes del POS** | ✅ **F1** — propuesto por Pincer el 2026-09-07, aceptado (§3.1) |
| G | Rechazo por producto agotado | ✅ Resuelto por F: nunca llega al POS |

**Regla de oro de F1:** una orden de Pincer nace y muere como delivery/pickup. Nunca
toca una mesa del salón.

---

## 1. Estado del acuerdo, punto por punto

| Tema | Pincer (2026-09-05) | Estado de nuestro lado |
|---|---|---|
| Propina | Separada como `tip_amount`, no paga ITBIS, **es del restaurante** | ⚠️ **El POS no tiene dónde guardarla** — ver §7.1 |
| Comisión | Cero. El cobro entra directo a la cuenta Azul del restaurante | ✅ Simplifica la conciliación (§7.2) |
| UUID de producto | Lo mandan en cada línea | ✅ Falta exponer el catálogo y definir altas/bajas (§6) |
| Autenticación | Proponen HMAC sobre el body en vez de allowlist por IP | ✅ Sí a HMAC — **pero no sustituye el allowlist** (§5.2) |
| Volumen | 5 pedidos/min por restaurante en pico | ✅ Límite en 60 rpm por credencial, sobra |
| RNC | Ya validan módulo 11 (9 díg.) y módulo 10 (cédula 11 díg.) | ✅ **El POS hoy no valida nada** — su validación es la única (§8) |
| Cancelaciones | Solo el cliente antes de aceptar, o el supervisor del restaurante | ✅ Corrige mi supuesto: quien cancela es el propio restaurante (§9.3) |
| Flujo de entrada | La cajera acepta en la tablet de Pincer y ahí se empuja al POS | ✅ Aceptado (§3.1) |
| Pedidos programados | No existen; todo es inmediato | ✅ Nos avisan antes de montarlos |
| Piloto | Tropella Coffee & Tea, **con comprobante fiscal** | ⚠️ **Falta la activación de Alanube, y es de nuestro lado** (§8, R8) |
| Merchant Azul de Tropella | Sale esta semana | ⚠️ Void y tarjeta se prueban después; el resto arranca antes (§8) |
| IPs de salida | Serverless, IPs dinámicas por diseño | ✅ **No hace falta: no filtramos por IP** (§5.2) |
| Idempotencia | Su número es contador por restaurante; usar su ID interno | ✅ Ya diseñado como `UNIQUE(business_id, external_order_id)` |

---

## 1.b Verificado en producción (2026-09-07)

Desplegado y probado contra el stack real con la credencial sandbox de Tropella:

- `GET /pincer-catalog` → 164 productos, 26 categorías, 39 con modificadores.
  **Cero productos sin impuesto vinculado** — el riesgo R3 no aplica en Tropella.
  Todo el menú es `inclusive`: el precio ya trae ITBIS y Ley adentro.
- Firma inválida, timestamp viejo, sin firma y API key inventada → 401 con códigos
  distinguibles. La firma de `openssl` coincide byte a byte con la de Deno.
- `POST /pincer-orders` → 201, orden `DEL-019` creada con su línea y su comanda.
- El pedido prepagado destapó R14 (exige caja abierta) y R15 (guard de sub-cobro).

## 2. Estado actual del código

### Ya existe (base reutilizable)

- **Delivery como origen.** `table_sessions.origin='delivery'` con
  `delivery_type ∈ {'own','uber_eats','pedidos_ya'}` y
  `fn_open_delivery_order(p_user_id, p_delivery_type, p_people_count)`
  ([20260408_0002](../supabase/migrations/20260408_0002_delivery_system.sql)).
  → Falta agregar `'pincer'` al CHECK. Una línea.
- **Listado y pantalla:** `fn_list_delivery_orders`,
  [`delivery_express_view.dart`](../lib/presentation/sales/view/delivery_express_view.dart),
  canal Realtime `delivery_orders_{businessId}`.
- **Patrón de webhook entrante:** [`alanube-webhook`](../supabase/functions/alanube-webhook/index.ts).
- **Patrón de HTTP saliente desde la BD:** `pg_net` ya en uso en
  [`azul_charge_subscription_cron`](../supabase/migrations/20260609_0001_azul_charge_subscription_cron.sql)
  y [`mall_export_cron`](../supabase/migrations/20260816_0001_mall_export_cron.sql)
  → **es el camino para el webhook de cancelación (§5.6)**.
- **Alta de línea con impuestos correctos:** `fn_add_item_from_menu(...)`.
  **La ingesta debe usar este RPC, no INSERT crudo**, o la orden entra sin ITBIS.
- **Pago con referencia:** `fn_process_payment_v3(..., p_reference, p_customer_rnc,
  p_requested_ncf_type, p_cashier_session_id DEFAULT NULL, ...)`.
- **Anulación con nota de crédito:** `fn_issue_credit_note()` emite E34/B04 copiando
  montos exactos del original
  ([20260903_0001](../supabase/migrations/20260903_0001_credit_note_annulment.sql)).
  Nunca tumba la anulación: si falta secuencia devuelve `no_sequence`.
- **KDS Realtime:** la orden ingerida con ítems en `pending` aparece sola.
- **Cola de impresión:** `print_jobs` + `fn_claim_print_job` + agente Node +
  [`CloudPrintQueueWorker`](../lib/core/printing/cloud_print_queue_worker.dart).

### Falta

1. API key por negocio + **secreto HMAC** + revocación + rate limit.
2. Edge functions `pincer-catalog`, `pincer-orders`, `pincer-orders/{id}/cancel`.
3. `fn_ingest_external_order` idempotente.
4. **Campo de propina en el flujo de orden** (§7.1) — no existe hoy.
5. **Impresión automática de la comanda** (§9.1) — la pieza cara.
6. **Webhook saliente de cancelación** (§5.6).
7. Sección "Órdenes" en Ventas (§10).
8. Modo sandbox por credencial.

---

## 3. Arquitectura

### 3.1 Quién filtra (cambio de R3)

El pedido **no entra crudo al POS**. Cae primero en la tablet de Pincer, la cajera lo
acepta, y recién ahí nos lo empujan. Es el flujo que Pincer ya opera con otros comercios.

```
cliente ordena → tablet Pincer → cajera ACEPTA → POST al POS → comanda + KDS
                                 └── RECHAZA → void automático, el POS nunca se entera
```

Qué nos ahorra: la bandeja de aceptación en el POS, el rechazo por producto agotado, el
aviso sonoro urgente y casi todo el caso de comanda impresa con cancelación posterior.
La sección "Órdenes" (§10) queda como **monitor**, no como bandeja de decisión.

Qué **no** resuelve: la comanda sigue sin tener quién la imprima (§9.1). El cambio de
flujo no toca esa pieza.

Lo que sí introduce: **un humano entre el pedido y el POS**. El pedido entra cuando la
cajera acepta, no cuando el cliente ordena, y ese retraso es variable (§9.4).

### 3.2 Diagrama

```
                       Pincer (sus servidores)
        POST /pincer-orders            POST /pincer-orders/{id}/cancel
        X-Api-Key + X-Pincer-Signature (HMAC-SHA256 con timestamp)
                             ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ Edge Function: pincer-orders                                  │
  │  1. API key → business_id + secreto + environment             │
  │  2. Verifica HMAC del RAW body y la ventana de 5 min          │
  │  3. Guarda en external_order_inbox (ANTES de ingerir)         │
  │  4. RPC fn_ingest_external_order(payload)  ← una transacción  │
  │  5. 201 con { order_id, order_number, status }                │
  │     o 200 con la MISMA orden si la clave se repite            │
  └──────────────────────────────────────────────────────────────┘
                             │
  ┌──────────────────────────────────────────────────────────────┐
  │ DB: fn_ingest_external_order(jsonb)  SECURITY DEFINER         │
  │  - idempotente por (business_id, external_order_id)           │
  │  - fn_open_delivery_order con delivery_type='pincer'          │
  │  - por línea: fn_add_item_from_menu + modificadores           │
  │  - tip_amount → orders.tip (columna nueva, fuera del ITBIS)   │
  │  - si viene pagada: fn_process_payment_v3, método 'pincer'    │
  │  - ítems 'pending' + status_ext='sent_to_kitchen' → KDS       │
  └──────────────────────────────────────────────────────────────┘
                             │ Realtime
             ┌───────────────┴────────────────┐
             ▼                                ▼
      KDS (ya funciona)          Sección "Órdenes" + comanda (§9.1)

  ── vuelta ──  POS cancela → trigger + pg_net → POST al webhook de Pincer (§5.6)
```

---

## 4. Modelo de datos

Migración propuesta `20260906_0001_external_orders_channel.sql` (+ `_ROLLBACK.sql`).
Nombres genéricos (`external_*`): el mismo motor sirve para Uber Eats y PedidosYa.

### 4.1 `external_api_keys`
```
id, business_id, channel ('pincer'|…)
key_prefix        text   -- 8 chars visibles en el panel
key_hash          text   -- sha256; la clave se muestra UNA sola vez
hmac_secret_enc   text   -- secreto de firma, cifrado; distinto de la API key
environment       text   -- sandbox | production
scopes            text[] default '{orders:write,orders:cancel,catalog:read}'
rate_limit_rpm    int    default 60
cancel_webhook_url text  -- a dónde avisamos si el POS cancela (§5.6)
is_active         boolean, last_used_at, created_at, revoked_at
```

### 4.2 `external_order_inbox`
`id, business_id, channel, external_order_id, payload, headers, signature_valid,
http_status, processed, error, received_at`

### 4.3 `external_orders`
```
id, business_id, channel
external_order_id  text   -- SU ID INTERNO (único global). UNIQUE(business_id, external_order_id)
external_number    text   -- su contador por restaurante; es el que se IMPRIME
order_id, session_id
service_type       text   -- delivery | pickup
paid_externally    boolean
external_total     numeric   -- lo que ellos cobraron, propina incluida
tip_amount         numeric   -- desglosado (§7.1)
payment_reference  text      -- referencia Azul
customer_name, customer_phone, delivery_address, customer_rnc
cancel_state       text   -- none | cancelled_by_pincer | cancelled_by_pos
cancel_notified_at timestamptz  -- cuándo confirmamos el webhook saliente
raw_order          jsonb
created_at, updated_at
```

### 4.4 `external_item_map`
`business_id, channel, external_item_id, menu_item_id` — red por si algún día
mandan un id suyo. Con Pincer queda vacía.

### 4.5 `external_webhook_outbox` — la vuelta
`id, business_id, channel, event ('order.cancelled'), external_order_id, payload,
attempts, next_attempt_at, delivered_at, last_error`

---

## 5. Contrato de API

Base: `https://supabase.mangopos.do/functions/v1/`. JSON UTF-8, montos decimales
con 2 posiciones (el POS trabaja en `numeric`; centavos en el borde crean errores de
redondeo en el ITBIS — ya nos pasó con Alanube: 800.01 vs 800.00).

### 5.1 Autenticación
```
X-Api-Key: mgp_live_a1b2c3d4…
X-Pincer-Signature: t=1757090531,v1=<hex hmac_sha256(secret, "t.rawbody")>
```
- Secreto **distinto** de la API key, entregado una sola vez, rotable sin cambiar la key.
- Ventana de 5 minutos contra `t`; fuera de eso, `401`. Comparación en tiempo constante.
- La firma se calcula sobre el **body crudo**, byte por byte, antes de parsear.

### 5.2 Allowlist de IP: no aplica — corrección de R3

En R2 pedí los rangos de salida de Pincer por precaución, heredada del PRD de Uber Eats.
**Revisado: no tenemos filtro por IP delante del endpoint.** El precedente de Incapsula
fue al revés — era el WAF **de Azul** bloqueando nuestras IPs *de salida* hacia su
ambiente de pruebas ([AZUL_TEST_LOCAL.md](../supabase/AZUL_TEST_LOCAL.md)), no un WAF
nuestro filtrando entradas. Nuestro stack es Coolify + Kong sobre el VPS, sin allowlist.

Conclusión: **no hace falta que Pincer fije región de AWS ni compre IPs dedicadas.**
El control es criptográfico: firma HMAC + ventana de 5 min + rate limit por credencial.
Queda confirmar en el VPS que no hay regla de red heredada antes del piloto.

### 5.3 `GET /pincer-catalog?updated_since=<iso8601>`
```json
{
  "business": { "id": "…", "name": "Tropella Coffee & Tea", "currency": "DOP" },
  "catalog_version": "2026-09-05T14:03:11Z",
  "categories": [{ "id": "…", "name": "Bebidas frías", "position": 1 }],
  "items": [
    { "id": "9f3c…", "name": "Latte frío", "category_id": "…", "price": 250.00,
      "is_active": true, "updated_at": "2026-09-04T18:00:00Z", "image_url": "…",
      "modifier_groups": [
        { "id": "…", "name": "Tamaño", "min_select": 1, "max_select": 1,
          "modifiers": [{ "id": "…", "name": "Grande", "price_delta": 50.00 }] }
      ] }
  ]
}
```
**Altas y bajas (§6):** un producto dado de baja sale con `is_active: false`, **nunca
desaparece del listado ni cambia de id**. Con `updated_since` piden solo el delta.

**`price_includes_tax`** dice si el precio ya trae los impuestos adentro. En Tropella
**todo el menú es `inclusive`**: los RD$375 de un bagel ya incluyen ITBIS 18% y Ley 10%.
Si el canal le suma impuestos encima al precio del catálogo, le cobra al cliente un 28%
de más. Se cobra el precio tal cual viene.

### 5.4 `POST /pincer-orders`
```json
{
  "external_order_id": "pnc_01J9X4K2M8QY",   // su ID interno, único global → idempotencia
  "external_number": "142",                   // su contador por restaurante → se IMPRIME
  "service_type": "delivery",
  "placed_at": "2026-09-05T18:22:11Z",        // cuándo ORDENÓ el cliente
  "accepted_at": "2026-09-05T18:24:02Z",      // cuándo la cajera ACEPTÓ en la tablet
  "accepted_by": "cajera@tropella",
  "customer": { "name": "Juan Pérez", "phone": "809…", "rnc": null,
                "address": "Calle 1 #4, Naco" },
  "payment": { "status": "paid", "subtotal": 1150.00, "tip_amount": 100.00,
               "total": 1250.00, "method": "card", "reference": "azul-8837261",
               "authorization_code": "OK1234" },
  "lines": [
    { "menu_item_id": "9f3c…", "quantity": 2, "notes": "sin azúcar",
      "modifiers": [{ "modifier_id": "…", "quantity": 1 }] }
  ]
}
```
`total = subtotal + tip_amount`. El ITBIS sale de nuestro catálogo sobre `subtotal`;
la propina queda fuera de la base imponible.

**`payment.status: "pending"`** (efectivo contra entrega) es un caso soportado: la orden
entra sin pago y **el POS la cobra normal** al entregar, con su NCF y su cuadre de
efectivo. Como el delivery lo pone el restaurante con su propia gente, este caso
probablemente sea frecuente y conviene probarlo primero — no depende del merchant de
Azul (§8).

Respuesta `201`:
```json
{ "order_id": "…", "order_number": "DEL-018", "external_number": "142",
  "status": "accepted", "queued_for_print": true, "kds": true,
  "pos_subtotal": 1150.00, "pos_total": 1250.00, "tip_amount": 100.00 }
```
Repetir la misma `external_order_id` devuelve `200` con el mismo cuerpo, sin crear ni
imprimir nada nuevo.

### 5.5 `POST /pincer-orders/{external_order_id}/cancel` — es una anulación fiscal

Con el flujo de §3.1, **todo lo que llegó al POS ya está en cocina**. Así que cancelar
aquí nunca es un "cancel" liviano: es anular una venta cobrada, casi siempre con
comprobante ya emitido, y eso exige **nota de crédito** (E34 / B04).

```json
{ "reason": "cliente canceló", "cancelled_by": "supervisor@pincer",
  "void_reference": "azul-void-…", "confirm_void": true }
```
Respuestas:
- `200 { "cancelled": true, "credit_note": "E34…" | null }` — anulada; si había
  comprobante se disparó `fn_issue_credit_note()`.
- `409 { "code": "requires_void_confirmation", "state": "preparing", "printed_at": "…",
  "total": 1250.00 }` — falta `confirm_void`. Es un aviso, no un rechazo: dice en qué
  estado va para que el supervisor decida con el dato delante.
- `200 { "cancelled": true, "credit_note": null, "credit_note_status": "no_sequence" }` —
  se anuló pero falta la secuencia E34. `fn_issue_credit_note()` **nunca tumba la
  anulación**; la nota queda pendiente y se reintenta.
- `404 unknown_order`.

> **Auditoría:** anular en el POS exige PIN de supervisor. Una anulación por API se salta
> ese candado. No es un bloqueo — quien cancela en la tablet es el supervisor del propio
> restaurante — pero queda registrada como `cancelled_by = 'pincer:<usuario>'` y visible
> en el historial de ventas, para que nunca aparezca una anulación sin dueño.

### 5.6 Webhook saliente: el POS canceló
`POST` a `cancel_webhook_url` con la misma firma HMAC (invertida: firmamos nosotros).
```json
{ "event": "order.cancelled", "external_order_id": "pnc_01J9X4K2M8QY",
  "cancelled_at": "…", "reason": "…", "cancelled_by": "pos", "credit_note": "E34…" }
```
Cola `external_webhook_outbox` + `pg_net`, reintentos con backoff (1m, 5m, 30m, 2h, 6h)
hasta 24 h. Esperamos `2xx`. **Es el canal por el que un cliente no se queda cobrado.**

> Detalle a tener presente: una anulación hecha con la tablet sin internet sale por
> la cola offline y el webhook se dispara al reconectar, no en el momento.

### 5.7 Errores

| HTTP | code | Significado | ¿Reintentar? |
|---|---|---|---|
| 401 | `invalid_api_key` / `invalid_signature` / `stale_timestamp` | Credencial o firma | No |
| 403 | `channel_disabled` | El restaurante apagó Pincer | No |
| 409 | `duplicate_order` | Ya existe (se devuelve la orden) | No |
| 409 | `already_in_kitchen` | Cancelación tardía (§9.3) | No |
| 422 | `unknown_menu_item` / `invalid_payload` / `tip_mismatch` | Datos | No |
| 429 | `rate_limited` (`Retry-After`) | Excedió 60 rpm | Sí, backoff |
| 503 | `pos_unavailable` | BD caída | Sí, backoff |
| 500 | `internal_error` | Bug nuestro, ya quedó en el inbox | Sí, y avisar |

Solo `429`, `503` y `500` se reintentan.

---

## 6. Altas y bajas de catálogo (su punto 3)

Pregunta de Pincer: cómo se enteran cuando el restaurante crea o da de baja un ítem.

**Recomendado: que consulten `GET /pincer-catalog?updated_since=` cada 15 minutos.**
Sin estado de nuestro lado, sin cola, sin reintentos, y si se cae un ciclo el siguiente
se pone al día solo. Para un menú de restaurante, 15 minutos de latencia no le hace
daño a nadie.

Garantías que damos:
- El `id` es un UUID que **no cambia nunca**, ni al editar nombre, precio o categoría.
- Un producto eliminado **no se borra del feed**: sale `is_active: false` para siempre.
  Si alguna vez desapareciera de golpe, Pincer se quedaría con líneas apuntando a un id
  muerto y el pedido rebotaría con `422` en pleno pico.
- Un `menu_item_id` inactivo en un pedido responde `422 unknown_menu_item`.

Webhook de catálogo: se puede, reusando `external_webhook_outbox`, pero no lo pongo en
F1. Notificar cada cambio de precio de un menú que se edita a mano genera mucho ruido
para el problema que resuelve.

---

## 7. Dinero

### 7.1 Propina — hay que construirla

Pincer manda `tip_amount` separado. **El POS hoy no tiene dónde ponerlo:**
`orders` no tiene columna `tip`, `payments` tampoco, y `sales_viewmodel` no la maneja
en ningún punto del flujo de cobro. Lo único que existe es `fiscal_documents.tip`, y
ahí se rellena como **diferencia implícita**
(`tip = total − subtotal − itbis − service_fee`, ver
[20260530_0012](../supabase/migrations/20260530_0012_fix_recompute_fd_keep_base_only.sql)).
`business_settings.tip_enabled` existe en la BD pero **nadie lo lee**: es un flag muerto.

Trabajo mínimo en F1:
1. `orders.tip numeric(12,2) DEFAULT 0` — columna nueva, aditiva.
2. La propina **no entra** en la base imponible ni en el cálculo de ITBIS ni de Ley 10%
   (coincide con lo que Pincer describe).
3. `orders.total` incluye la propina, para que cuadre con lo que ellos cobraron.
4. Al emitir el comprobante, la propina viaja a `fiscal_documents.tip` **explícita**, no
   por diferencia.
5. En el cierre de caja aparece como línea propia, no revuelta con la venta.

> **Resuelto (2026-09-07):** la propina **es del restaurante**. Pincer solo pone la
> plataforma; el delivery lo hace el restaurante con su propia gente — por eso tampoco
> cobran comisión. Se registra como ingreso del restaurante. Nota menor: una orden de
> Pincer no tiene mesero asignado, así que en el reporte de propina por empleado cae en
> el canal, no en una persona.

### 7.2 Comisión cero — lo que simplifica

Que el cobro entre directo al merchant de Azul del restaurante quita el problema más
feo de los agregadores: aquí **el bruto es el neto**. El depósito de Azul ya incluye
esas ventas, así que la conciliación es contra el estado de cuenta de Azul del propio
restaurante, sin liquidación semanal de por medio.

Consecuencia práctica: el método de pago del POS debe leerse como **tarjeta cobrada por
Pincer**, no como un canal de dinero ajeno. Sigue **fuera del cuadre de efectivo**, pero
sí cuenta en el total de tarjeta del día.

### 7.3 Registro del pago

- Método por negocio: `('Pincer', 'pincer')`, con `p_reference = payment.reference`.
- **Sí exige sesión de caja abierta — corregido tras la prueba del 2026-09-07.** El PRD
  asumía que bastaba `p_cashier_session_id => null` porque el dinero no pasa por el
  cajón. Falso: `fn_process_payment_v3` corta **antes** de mirar el método
  (`if p_cashier_session_id is null then raise 'CASH_SESSION_REQUIRED'`). La ingesta
  resuelve la caja abierta del negocio con `fn_external_open_cash_session()`
  (20260907_0007), igual que hace la app. Sin caja abierta el pedido entra y la comanda
  sale, pero el cobro queda `failed` con `SIN_CAJA_ABIERTA`, para registrarlo después.
  El pago **sigue fuera del cuadre de efectivo**: `fn_process_payment_v3` solo suma al
  cajón cuando el método es `cash`.
  **Pendiente de fondo:** que el guard aplique solo a efectivo, como ya hace el módulo
  de crédito (20260714_0002). Es tocar una función fiscal divergente y merece su propia
  migración.
- **No entra al cuadre de efectivo.** Bloque aparte en el cierre. Sumarlo al efectivo
  esperado haría que el cajero cuadre corto todos los días.
- Si `payment.total` ≠ total calculado por el POS, manda el de Pincer (es lo que el
  cliente pagó) y la diferencia queda visible en `external_orders` para conciliar.

---

## 8. Fiscal

- **Validación de RNC:** Pincer ya valida módulo 11 (RNC de 9) y módulo 10 (cédula de
  11). Conviene saber que **el POS no valida RNC en ninguna parte** — no hay
  validación de dígito verificador en el código. Su validación es la única barrera, así
  que se agradece que la hayan puesto.
- Sin RNC: consumo normal. Con RNC: `fn_process_payment_v3` recibe `p_customer_rnc` y
  `p_requested_ncf_type`; el crédito fiscal sale por la vía normal.
- El NCF se emite al registrar el pago (en la ingesta), no en el checkout de Pincer. Si
  quieren mostrárselo al cliente, tienen que consultarlo después: el e-CF de Alanube es
  asíncrono.
- **Bloqueador del piloto, y es nuestro:** el piloto va **con comprobante fiscal**.
  Tropella tiene el e-CF **sin activar**: el switch de la POS no llegó a crear su fila en
  `business_alanube_settings` y quedó `pending` desde el 2026-08-29, a falta del ULID de
  la company en Alanube. Pincer avisó que "ya lo activó de su lado", pero **esto no se
  activa desde su plataforma** — es configuración nuestra en Alanube. Lo cerramos
  nosotros antes de la prueba.
- **Merchant de Azul de Tropella:** sale esta semana. Tarjeta y `ProcessVoid` se prueban
  cuando llegue. **Lo que no depende de eso arranca antes:** pedidos en efectivo contra
  entrega (§5.4), ingesta, comanda, KDS, catálogo y cierre.

---

## 9. Operación

### 9.1 La comanda — la pieza que no es obvia

**Insertar la orden en la base de datos no imprime nada.** Los bytes ESC/POS los arma
Flutter (`lib/services/printing/`): `print_jobs.data_hex` llega ya renderizado desde el
cliente. Un pedido que nace en el servidor no tiene quién lo imprima. El KDS sí lo ve
solo (escucha `order_items` por Realtime); el papel, no.

**Solución F1:** una tablet del local se designa **estación de recepción**. Escucha el
canal Realtime, suena, arma la comanda con el builder existente (con `external_number`
bien grande, que es como el personal identifica el pedido en el mostrador) y la manda
por el dispatcher de cocina normal, con su fallback a `print_jobs`.

Riesgo: tablet apagada, no hay comanda. Se mitiga con el aviso en la sección Órdenes y
un segundo dispositivo de respaldo — el claim atómico de `fn_claim_print_job` ya evita
la doble impresión.

Descartado para F1: renderizar ESC/POS en el servidor. Serían cinco builders duplicados
en TypeScript, con 58/80 mm y el modo raster de Star, y dos fuentes de verdad para el
mismo papel.

> Por eso la respuesta dice `"queued_for_print": true`, no `"printed"`. Ya está
> acordado con Pincer que ese caso no se reintenta desde su lado.

### 9.2 Estados que reportamos
`accepted → preparing → ready → delivered`, más `cancelled`. Consultables por
`GET /pincer-orders/{external_order_id}`.

### 9.3 Cancelación — cerrado en R3

Mi objeción de R2 (el restaurante comiéndose la pérdida sin opinar) **no aplica**:
Pincer aclaró que el cliente solo puede cancelar **antes** de que la cocina acepte, y
después el único que cancela es el supervisor del propio restaurante. El que decide y el
que asume son la misma persona.

Lo que queda, entonces:

| Momento | Quién | Camino |
|---|---|---|
| Antes de aceptar en la tablet | Cliente o cajera | Todo pasa en Pincer; el POS nunca se entera |
| Ya en el POS, cancelado desde Pincer | Supervisor del restaurante | §5.5, con `confirm_void` + nota de crédito |
| Ya en el POS, anulado desde el POS | Supervisor, con PIN | Flujo de anulación normal + webhook saliente (§5.6) |

### 9.4 El retraso de la aceptación

Con el flujo de §3.1 la orden entra al POS cuando la cajera acepta, no cuando el cliente
ordena. Guardamos las dos marcas (`placed_at` y `accepted_at`), pero **la venta se
contabiliza al momento de la ingesta**, que es cuando entra a la caja.

Caso borde que conviene tener presente: un pedido hecho a las 11:55 p.m. y aceptado a
las 12:05 a.m. cae en **otro día fiscal y en otra sesión de caja** — o con la caja ya
cerrada, que el diseño aguanta porque `p_cashier_session_id` va NULL (§7.3). No es un
error, pero explica descuadres aparentes en el corte del día.

---

## 10. Sección "Órdenes" en Ventas (F1c)

**Monitor**, no bandeja de decisión: con el flujo de §3.1 la aceptación ya ocurrió en la
tablet de Pincer, así que aquí nadie aprueba nada. Va aparte del delivery propio digitado
a mano que hoy vive en `/ventas?mode=delivery`.

- **Estados:** Entrantes → En preparación → Listas → Entregadas.
- **Tarjeta:** número de Pincer bien grande, tipo de servicio, cliente, hora, total,
  marca "Pagado", propina desglosada.
- **Acciones:** detalle, **reimprimir comanda**, marcar lista, cancelar (dispara §5.6).
- **Rojo visible** cuando la orden entró pero la comanda no se pudo imprimir.
- Permiso `ventas.ordenes.ver` — **hay que sembrarlo en el catálogo de permisos de la
  BD o el RPC lo descarta en silencio** (ya nos pasó con los 4 permisos de crédito).

---

## 11. Fases

| Fase | Contenido |
|---|---|
| **F0** | Migración: `'pincer'` en `chk_delivery_type`, `orders.tip`, tablas §4, método de pago, permiso |
| **F1a** | `pincer-catalog` + `pincer-orders` + `fn_ingest_external_order` + HMAC |
| **F1b** | Receptor de impresión en la app (§9.1) |
| **F1c** | Sección "Órdenes" (§10) |
| **F1d** | Cancelación entrante (§5.5) + webhook saliente (§5.6) |
| **F2** | Sandbox por credencial + panel de API keys (crear / revocar / rotar secreto) |
| **F3** | Estados hacia Pincer (§9.2) |
| **F4** *(2ª etapa)* | Mesa abierta y pay-at-table |

---

## 12. Riesgos

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | Tablet receptora apagada → sin comanda | Aviso en Órdenes + segundo dispositivo + `print_jobs` |
| R2 | `fn_confirm_order_to_kitchen` **no tiene guard** y resucita órdenes pagadas (6,009 atascadas) | La ingesta no lo llama: marca los ítems directamente |
| R3 | Ítem sin ITBIS vinculado entra en 0 | `menu_item_taxes` es la única fuente; auditar Tropella antes del piloto |
| R4 | Propina revuelta con la venta o dentro de la base imponible | §7.1, columna explícita |
| R5 | Pincer reintenta en pico | 60 rpm + `Retry-After` |
| R6 | Pedido de prueba imprime en Tropella | `environment='sandbox'` obligatorio hasta certificar |
| R7 | El KDS no muestra la orden | El KDS mira `order_items.status`, no `status_ext`: dejar ítems en `pending` |
| R8 | **Tropella sin e-CF activo** y el piloto emite con RNC | Cerrar la activación en Alanube antes de la prueba (§8) |
| R9 | Anulación por API salta el PIN de supervisor | Auditada como `cancelled_by='pincer:<usuario>'` y visible en historial (§5.5) |
| R10 | Cancelación en el POS estando offline | Sale por la cola offline; el webhook se dispara al reconectar |
| R11 | ~~El WAF bloquea a Pincer~~ | **Descartado en R3:** no filtramos por IP (§5.2) |
| R12 | Pedido aceptado después de medianoche cae en otro día fiscal | Esperado, no es error; documentado en §9.4 |
| R13 | La cajera tarda en aceptar y el cliente cree que el pedido entró | Es de su lado, pero conviene medir el tiempo `placed_at → accepted_at` en el piloto |
| R14 | Pedido prepagado con la caja cerrada | El pedido entra; el cobro queda `failed` con `SIN_CAJA_ABIERTA` y se registra al abrir caja (§7.3) |
| R15 | El total del canal no cubre los ítems | `fn_process_payment_v3` **bloquea** el sub-cobro (tolerancia 3% o RD$5): el pedido entra, el cobro no. Por eso conviene que consulten el catálogo cada 15 min en vez de cachear precios |
| R16 | El canal suma impuestos sobre un precio que ya los trae | `price_includes_tax` en el catálogo (§5.3) |

---

## 13. Preguntas abiertas

- ~~**P1.** ¿De quién es la propina?~~ **Resuelto:** del restaurante (§7.1).
- ~~**P2.** Ventana de cancelación.~~ **Resuelto** por el flujo pre-filtrado (§9.3).
- ~~**P3.** Rechazo por producto agotado.~~ **Resuelto:** nunca llega al POS (§3.1).
- ~~**P5.** Pedidos programados.~~ **No existen**; avisan antes de montarlos.
- **P4.** Sandbox: negocio de pruebas en el mismo stack (rápido, suficiente) vs. clon del
  VPS. Recomiendo lo primero.
- **P6.** ¿Con qué frecuencia hay pedidos en efectivo contra entrega? Define qué tanto del
  piloto corre sin depender del merchant de Azul (§5.4, §8).
- **P7.** Confirmar en el VPS que no queda ninguna regla de red heredada delante de
  `/functions/v1/*` (§5.2).
