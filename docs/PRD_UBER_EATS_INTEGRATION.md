# PRD — Integración Uber Eats (Online Ordering) para MangoPOS

> **Estado:** Borrador para revisión
> **Fecha:** 2026-06-17
> **Dueño de producto:** Cristian Gómez
> **Ámbito:** Conectar MangoPOS con **Uber Eats Marketplace** para que los pedidos
> hechos en la app de Uber Eats entren **automáticamente** al POS y a cocina/KDS,
> sin captura manual. El PRD define la arquitectura completa y las fases; la
> **Fase 1 (recepción de pedidos)** se implementa primero.
> **Diferenciador:** parida de "online ordering" con Toast, reutilizando la
> infraestructura de delivery, integraciones externas (Azul/Alanube) y KDS que
> MangoPOS ya tiene.

---

## 0. Decisiones de alcance (cerradas con el dueño de producto)

| # | Decisión | Resolución |
|---|---|---|
| D1 | Vía de acceso a la API | **Partnership directo con Uber Eats** (Eats Marketplace API). Aún **no somos partner**; este PRD incluye el proceso de onboarding y construimos contra spec + sandbox mientras llega la aprobación. **No** se usa middleware (Deliverect/Otter/Cuboh). |
| D2 | Alcance de la Fase 1 | **Solo recepción de pedidos**: webhook de Uber → crea la orden en POS → va a cocina/KDS. Estados (aceptar/listo), sync de menú y disponibilidad/86 son fases posteriores. |
| D3 | Entregable inmediato | **Este PRD + plan por fases**, luego implementar Fase 1. |

### Decisiones técnicas propuestas (pendientes de tu visto bueno)

Estas las propongo yo con una recomendación; cámbialas si quieres antes de codificar.

| # | Tema | Recomendación |
|---|---|---|
| T1 | Aceptación del pedido en F1 | Aunque F1 es "solo recepción", Uber **exige aceptar/confirmar** el pedido dentro de una ventana o lo cancela. Recomiendo **auto-aceptar** en el procesador al momento de ingerir (auto-accept). El aceptar/rechazar **manual** desde la UI queda para F2. |
| T2 | Mapeo de ítems sin sync de menú | F1 no empuja menú todavía, así que los `item_id` de Uber no son nuestros `menu_items.id`. Uso tabla de mapeo `ubereats_item_map`; lo no mapeado entra como **línea ad-hoc** (nombre+precio que manda Uber, `product_id` NULL, marcada `needs_review`) para que **igual llegue a cocina**. Reconciliación 1-clic guarda el mapeo para la próxima. |
| T3 | Pago (prepago) | El cliente ya pagó en Uber. Registro el pago en POS con un **método "Uber Eats"** (sin afectar caja física), tomando el **total que reporta Uber** como fuente de verdad del cobro. |
| T4 | Total / impuestos | Guardo **el total de Uber** como lo cobrado (incluye sus promos/ajustes), pero conservo nuestras líneas para KDS/inventario. **No** dejo que el motor de impuestos sobrescriba el total al cliente. Un reporte de conciliación compara Uber vs nuestro cálculo. |
| T5 | NCF / fiscal | F1 **no** emite NCF automático (igual que el delivery actual). El tratamiento fiscal de pedidos de agregador en RD se consulta con el contador (ver [F4 NCF](PRD_OFFLINE_F4_NCF.md) y [modelo unificado de impuestos](PRD_AS_IS_BASELINE.md)). Queda como pregunta abierta P1. |
| T6 | Inventario en líneas no mapeadas | Las líneas ad-hoc (sin `product_id`) **no** disparan auto-consumo de inventario. Aceptable en F1; se corrige cuando el ítem queda mapeado o con el sync de menú (F3). Se documenta el riesgo. |
| T7 | mTLS / sidecar | **No** se necesita (a diferencia de Azul). Las llamadas salientes a `api.uber.com` son HTTPS estándar; el webhook entra al container `functions` por HTTPS. |

---

## 1. Estado actual — qué ya existe y qué falta

### Ya existe (base reutilizable)

- **Concepto de delivery/agregador en el esquema.** `table_sessions.origin = 'delivery'`
  con `delivery_type ∈ {'own','uber_eats','pedidos_ya'}` (constraint `chk_delivery_type`),
  y el RPC [`fn_open_delivery_order(p_user_id, p_delivery_type, p_people_count)`](../supabase/migrations/20260408_0002_delivery_system.sql)
  que crea zona "Delivery" (sort_index 902), mesa temporal `DEL-NNN`, sesión y orden.
  → **Hoy un Uber Eats se mete a mano; la integración automatiza la entrada.**
- **Listado de delivery** `fn_list_delivery_orders(business_id)` ya devuelve
  `delivery_type`, `customer_name` y `delivery_address`
  ([20260606_0001](../supabase/migrations/20260606_0001_delivery_address.sql)).
- **Patrón maduro de integraciones externas** (a copiar):
  - **Webhook inbox async**: `alanube_webhook_inbox` (receiver responde 200 < 3s,
    procesador drena) — [20260506_0001](../supabase/migrations/20260506_0001_alanube_ecf_extension.sql).
  - **Audit append-only de eventos**: `azul_webhook_events`, `fiscal_document_status_events`.
  - **Config por negocio + secreto de webhook**: `business_alanube_settings(business_id, webhook_secret, environment, ...)`.
  - **Idempotencia** por `external_id`/`order_number` UNIQUE.
  - **Secretos** en env del container `functions`, validados en startup por
    [`_shared/env.ts`](../supabase/functions/_shared/env.ts).
  - **Cliente HTTP saliente** desde edge functions con `fetch` (ver `_shared/azul-api.ts`).
- **KDS en tiempo real**: el KDS escucha `order_items` por Realtime
  (`rt:kds_order_items:{businessId}`). Una orden ingerida que mande ítems a cocina
  **aparece sola** en el KDS, sin código nuevo de UI para F1.
- **Catálogo limpio**: `menu_items` (vendible, con `image_url`, `is_active`, auto-86),
  `categories`, `modifier_groups`/`modifiers`, combos y `promotions` — listo para el
  sync de menú de F3.
- **Métodos de pago por negocio**: `payment_methods(business_id, name, code, position, icon)`
  con seed inicial (schema.sql:485) — se agrega un método "Uber Eats".

### Falta (lo que construye este PRD)

1. **Partnership + credenciales** con Uber (gating, ver §3).
2. **Vínculo tienda Uber ↔ negocio MangoPOS** (`uber_store_id` → `business_id`).
3. **Edge functions**: receiver del webhook + procesador async + cliente OAuth de Uber.
4. **RPC de ingestión** que convierte un pedido de Uber en orden/ítems/modificadores.
5. **Tablas nuevas**: inbox de webhooks Uber, registro de pedidos Uber, mapeo de ítems, config de tienda.
6. **UI mínima F1**: que el pedido aparezca en la pantalla Delivery + aviso (sonido/badge);
   reconciliación de ítems no mapeados.

---

## 2. Objetivo y métricas de éxito (Fase 1)

**Objetivo:** un pedido creado en Uber Eats aparece en el POS y en cocina **en < 10 s**,
sin intervención manual, con los ítems, cantidades, modificadores, instrucciones del
cliente y nombre/dirección correctos.

**Métricas:**
- ≥ 99% de pedidos recibidos resultan en una orden creada (resto en inbox con error visible).
- Latencia webhook→orden visible en KDS < 10 s p95.
- 0 pedidos duplicados (idempotencia por `uber_order_id`).
- 0 pedidos "perdidos" silenciosamente: todo webhook queda en `ubereats_webhook_inbox`,
  procesado o con `error` legible.

---

## 3. Onboarding / Partnership con Uber Eats (bloqueante)

> Sin esto no hay credenciales ni sandbox. Es trabajo de negocio/cuenta, en paralelo al desarrollo.

**Pasos (verificar contra developer.uber.com vigente al momento de ejecutar):**

1. **Cuenta de desarrollador Uber** y creación de una **app** en el dashboard de Uber Developer.
2. **Solicitar el programa de integraciones de Uber Eats** (Eats Marketplace / POS integration).
   Uber revisa y habilita los **scopes** de Eats (lectura/escritura de órdenes, tienda).
3. Obtener **`client_id`** y **`client_secret`** (OAuth2 *client_credentials*).
4. **Certificación**: Uber pide pasar un set de casos de prueba en **sandbox** antes de
   habilitar producción (recepción de orden, aceptación, cancelación, etc.).
5. **Activación de tiendas**: cada restaurante vincula su(s) **store(s)** Uber a nuestra
   integración. Obtenemos el **`store_id` (UUID de tienda Uber)** que mapeamos a `business_id`.
6. **Registrar la URL del webhook** y el **secreto de firma** en el dashboard de Uber.

**Lo que necesito de ti para arrancar el código de verdad:**
- `client_id` / `client_secret` de sandbox.
- Al menos un `store_id` de sandbox para pruebas.
- Confirmar la URL pública del container `functions` (la base `PUBLIC_CALLBACK_BASE_URL`)
  para registrar el webhook, y que **no haya WAF/Incapsula bloqueando las IPs de Uber**
  hacia ese endpoint (ojo: ya tuvimos un bloqueo Incapsula con Azul en el VPS).

Mientras tanto, construyo contra la **spec documentada** y con **fixtures** de payloads
de sandbox, de modo que al llegar las credenciales solo se configuren los secretos.

---

## 4. Arquitectura (Fase 1)

Reutiliza el patrón Alanube (inbox + procesador async) y el patrón Azul (cliente HTTP
saliente desde edge function). **No** requiere sidecar mTLS.

```
                    Uber Eats (servidores Uber)
                              │  POST webhook  (X-Uber-Signature: HMAC-SHA256 del body con client_secret)
                              ▼
   ┌───────────────────────────────────────────────────────────────┐
   │ Edge Function: ubereats-webhook  (PÚBLICA)                      │
   │  1. Lee raw body + headers                                      │
   │  2. INSERT en ubereats_webhook_inbox (firma válida?, payload)   │
   │  3. Responde 200 en < 3 s  (siempre, salvo firma inválida→401)  │
   └───────────────────────────────────────────────────────────────┘
                              │ (gatillo: pg_net / cron / invoke directo)
                              ▼
   ┌───────────────────────────────────────────────────────────────┐
   │ Edge Function: ubereats-processor  (SERVICE ROLE, async)       │
   │  Drena inbox no procesado por received_at:                     │
   │   a. event_type = orders.notification →                        │
   │      - OAuth: token client_credentials (cacheado)              │
   │      - GET /v2/eats/order/{id}  (detalle completo)             │
   │      - resolver business_id por uber_store_id                  │
   │      - RPC fn_ingest_ubereats_order(payload jsonb)             │
   │      - [T1] POST accept_pos_order  (auto-accept)               │
   │   b. event_type = orders.cancel / release → cancelar la orden  │
   │  Marca inbox.processed = true (o error legible)                │
   └───────────────────────────────────────────────────────────────┘
                              │ RPC (service_role)
                              ▼
   ┌───────────────────────────────────────────────────────────────┐
   │ DB: fn_ingest_ubereats_order(jsonb)  SECURITY DEFINER          │
   │  - idempotente por uber_order_id (UNIQUE)                      │
   │  - crea zona/mesa/sesión/orden estilo fn_open_delivery_order   │
   │    (origin='delivery', delivery_type='uber_eats')             │
   │  - inserta order_items (+ modifiers) resolviendo ubereats_item_map│
   │    · mapeado     → product_id real, dispara inventario         │
   │    · no mapeado  → línea ad-hoc (product_id NULL, needs_review) │
   │  - status_ext = 'sent_to_kitchen', items 'pending' (van a KDS) │
   │  - registra pago "Uber Eats" con el total de Uber [T3][T4]     │
   │  - guarda ubereats_orders (vínculo + raw + totales Uber)       │
   └───────────────────────────────────────────────────────────────┘
                              │ Realtime
                              ▼
            KDS (cocina)  +  Pantalla Delivery (POS)  +  aviso sonoro/badge
```

**Por qué inbox + procesador (no procesar en el receiver):** Uber reintenta si no
recibe 200 rápido; el receiver debe ser trivial y robusto. El trabajo pesado (OAuth,
GET del detalle, ingestión, accept) corre async y reintentable, igual que Alanube.

---

## 5. Modelo de datos (Fase 1)

Todo aditivo, `business_id`-scoped, RLS estilo Alanube/Azul. Migración propuesta
`20260617_0003_ubereats_integration_f1.sql` (+ su `_ROLLBACK.sql`).

### 5.1 `ubereats_store_links` — vínculo tienda Uber ↔ negocio
```
id                uuid pk
business_id       uuid fk businesses     (UNIQUE con uber_store_id)
uber_store_id     text NOT NULL UNIQUE   -- UUID de tienda en Uber
store_name        text
environment       text check (sandbox|production) default 'sandbox'
auto_accept       boolean default true   -- [T1]
is_active         boolean default true
created_at, updated_at
```
Resuelve `business_id` desde el `store_id` que viene en el webhook/detalle.

### 5.2 `ubereats_webhook_inbox` — inbox async (idéntico patrón a `alanube_webhook_inbox`)
```
id              uuid pk
event_type      text NOT NULL          -- orders.notification, orders.cancel, ...
uber_order_id   text                   -- meta.resource_id si aplica (para depurar)
payload         jsonb NOT NULL
headers         jsonb
signature_valid boolean
processed       boolean default false
processed_at    timestamptz
error           text
received_at     timestamptz default now()
-- index parcial (processed, received_at) where processed=false
```
RLS: **sin policies para authenticated** → solo `service_role`.

### 5.3 `ubereats_orders` — registro 1:1 pedido Uber ↔ orden MangoPOS
```
id                uuid pk
business_id       uuid fk businesses
uber_order_id     text NOT NULL UNIQUE   -- idempotencia
uber_display_id   text                   -- el # corto que ve el cliente/repartidor
order_id          uuid fk orders         -- nuestra orden creada
session_id        uuid fk table_sessions
status            text                   -- received|accepted|denied|cancelled|...
fulfillment_type  text                   -- DELIVERY | PICK_UP
uber_total_cents  int                    -- [T4] total que reporta Uber (cobrado)
currency_code     text
eater_name        text
delivery_address  text
placed_at         timestamptz
raw_order         jsonb                  -- detalle completo de Uber (auditoría)
created_at, updated_at
```

### 5.4 `ubereats_item_map` — mapeo ítem Uber → `menu_items` [T2]
```
id              uuid pk
business_id     uuid fk businesses
uber_item_id    text NOT NULL          -- (UNIQUE con business_id)
menu_item_id    uuid fk menu_items
created_at
```
F1: se llena por reconciliación 1-clic. F3 (sync de menú) lo llena automáticamente
al publicar el menú con nuestros IDs como external IDs.

### 5.5 Cambios mínimos a tablas existentes
- `order_items`: hacer **`product_id` NULLABLE** (hoy probablemente NOT NULL) y agregar
  `external_item_name text` + `needs_review boolean default false` para las líneas ad-hoc.
  ⚠️ **Área sensible** (KDS, inventario, pagos). Verificar consumidores de `product_id`
  antes de tocar; alternativa más conservadora: producto placeholder "Uber Eats (sin mapear)"
  por negocio. Se decide en implementación (P2).
- `payment_methods`: seed de un método `code='uber_eats'`, `name='Uber Eats'` por negocio
  (no afecta caja física; clasificado como prepago externo).

> El detalle de columnas/constraints definitivo se cierra al escribir la migración,
> tras `pg_get_functiondef`/inspección viva (ver memoria *BD viva diverge de migraciones*).

---

## 6. Fase 1 en detalle — recepción de pedidos

### 6.1 Edge function `ubereats-webhook` (pública)
- Verifica `X-Uber-Signature` = `HMAC-SHA256(rawBody, client_secret)` en hex. Si inválida → 401.
- INSERT en `ubereats_webhook_inbox` (event_type, payload, headers, signature_valid).
- Responde **200** inmediatamente. Dispara el procesador (pg_net / invoke / cron corto).

### 6.2 Edge function `ubereats-processor` (service role)
- **OAuth**: `POST https://auth.uber.com/oauth/v2/token` (`grant_type=client_credentials`,
  scopes de eats), cachea el `access_token` hasta su expiración.
- Por cada inbox no procesado:
  - `orders.notification`: `GET /v2/eats/order/{order_id}` → detalle; resolver `business_id`
    vía `ubereats_store_links` por `store_id`; llamar `fn_ingest_ubereats_order(detalle)`;
    si `auto_accept` → `POST /v1/eats/orders/{order_id}/accept_pos_order` [T1].
  - `orders.cancel`/`orders.release`: marcar orden `void` + `ubereats_orders.status='cancelled'`
    + avisar a cocina (KDS). (Cancelación entrante mínima en F1; flujo completo en F2.)
  - Marca `processed=true` o guarda `error` (reintentable).

### 6.3 RPC `fn_ingest_ubereats_order(p_order jsonb)` (SECURITY DEFINER)
1. **Idempotencia**: si `uber_order_id` ya existe en `ubereats_orders` → return (no duplica).
2. Crea zona/mesa/sesión/orden **reutilizando la lógica de `fn_open_delivery_order`**
   (`origin='delivery'`, `delivery_type='uber_eats'`); guarda `eater_name`, `delivery_address`,
   `uber_display_id` en la sesión/registro.
3. Por cada ítem del carrito de Uber:
   - Resolver `ubereats_item_map`. Si mapea → `order_items.product_id = menu_item_id`
     (dispara tax lines + inventario por los triggers existentes).
   - Si no mapea → línea ad-hoc: `product_id = NULL`, `external_item_name = title`,
     `unit_price` = precio de Uber, `needs_review = true` [T2][T6].
   - Modificadores → `order_item_modifiers` (name, qty, price). Instrucciones del
     cliente → `notes`.
4. `status_ext = 'sent_to_kitchen'`, ítems `status = 'pending'` → **entran al KDS**.
5. Registrar **pago prepago**: método `uber_eats`, `amount` = total de Uber [T3][T4]
   (decidir si se marca `paid` de una vez; recomendado sí, dado que ya está cobrado).
6. INSERT en `ubereats_orders` con vínculo + `raw_order` + `uber_total_cents`.

### 6.4 UI mínima F1 (Flutter)
- **Reutiliza la pantalla Delivery**: el pedido aparece solo (ya filtra `origin='delivery'`).
  Mostrar badge "Uber Eats" + el `uber_display_id` y `eater_name`/dirección.
- **Aviso de nuevo pedido**: sonido + notificación visual (Realtime sobre `ubereats_orders`
  o `table_sessions`).
- **Reconciliación de ítems** `needs_review`: una hoja para asignar `menu_item_id` al
  ítem ad-hoc; al confirmar, llena `ubereats_item_map` para la próxima.
- Sin pantalla de aceptar/rechazar todavía (eso es F2).

### 6.5 Manejo de errores y bordes (F1)
- Webhook con firma inválida → 401, no se procesa (posible ataque/ruido).
- `store_id` sin vínculo → inbox queda con `error` "tienda no vinculada"; visible para soporte.
- GET de detalle falla → reintento por el procesador (backoff); no se pierde el pedido.
- Pedido `scheduled` (programado) → en F1 se ingiere igual al llegar la notificación de
  preparación; el caso completo de scheduling se afina en F2.
- Reintentos de Uber del mismo evento → idempotencia por `uber_order_id`.

---

## 7. Roadmap por fases

| Fase | Nombre | Contenido | Depende de |
|------|--------|-----------|------------|
| **F1** | **Recepción de pedidos** *(este entregable)* | Webhook + inbox + procesador + `fn_ingest_ubereats_order` + auto-accept + UI mínima + reconciliación de ítems. | Credenciales sandbox |
| F2 | Estados de orden | Aceptar/rechazar manual, marcar preparando/listo, tiempos de preparación, cancelación bidireccional, scheduled orders completos. | F1 |
| F3 | Sync de menú | Publicar `menu_items`/categorías/modificadores/combos/fotos/precios a Uber con nuestros IDs como external IDs → el mapeo de ítems se vuelve automático. | F1 |
| F4 | Disponibilidad / 86 | Empujar `is_active`/auto-86 y stock a Uber (marcar ítems agotados). | F3 |
| F5 | Abrir/cerrar tienda | Pausar/activar la tienda en Uber (horarios, "ocupado"). | F1 |
| F6 | Conciliación y reportes | Reporte Uber payout vs ventas POS, comisiones, fiscal/NCF de agregador, integración con cierre de caja. | F1, contador |

---

## 8. Seguridad, RLS y secretos

- **Secretos** (en env del container `functions`, validados en `_shared/env.ts`, nunca en git):
  `UBEREATS_CLIENT_ID`, `UBEREATS_CLIENT_SECRET`, `UBEREATS_ENV` (sandbox|production),
  `UBEREATS_API_BASE` (`https://api.uber.com`), `UBEREATS_AUTH_URL`
  (`https://auth.uber.com/oauth/v2/token`). El secreto de firma del webhook = `client_secret`.
- **RLS**:
  - `ubereats_webhook_inbox`: solo `service_role` (sin policies authenticated), igual que Alanube.
  - `ubereats_store_links`, `ubereats_orders`, `ubereats_item_map`: `SELECT` para usuarios
    con `user_has_business_access(auth.uid(), business_id)`; escritura solo `service_role`
    (o owner/admin para el mapeo manual, estilo `pm_write`).
- **Idempotencia**: `ubereats_orders.uber_order_id UNIQUE`.
- **Auditoría**: `ubereats_webhook_inbox` y `ubereats_orders.raw_order` guardan todo (append-only).

---

## 9. Plan de migraciones (con rollback, convención del repo)

1. `20260617_0003_ubereats_integration_f1.sql` — tablas 5.1–5.4, seed de método de pago,
   cambios mínimos a `order_items`, RLS, RPC `fn_ingest_ubereats_order`, grants.
2. `20260617_0003_ubereats_integration_f1_ROLLBACK.sql` — revierte lo anterior.

> **No aplicar a la BD viva hasta revisión.** Antes de tocar funciones fiscales/orden,
> verificar la firma viva con `pg_get_functiondef` (memoria *BD viva diverge de migraciones*).

---

## 10. Pruebas (F1)

- **Unit (Dart)**: parser de payload Uber→modelo, resolución de mapeo, líneas ad-hoc.
- **Edge functions**: verificación de firma HMAC (válida/ inválida), respuesta 200 rápida,
  drenado idempotente del inbox, refresh de token OAuth.
- **SQL**: `fn_ingest_ubereats_order` idempotente (mismo `uber_order_id` 2x = 1 orden),
  ítems mapeados vs ad-hoc, modificadores, total/pago, aparición en `fn_list_delivery_orders`.
- **E2E sandbox**: pedido de prueba en Uber sandbox → verlo en KDS < 10 s; cancelación.
- **`flutter analyze` limpio** en los módulos tocados (sales, delivery, settings).

---

## 11. Riesgos

| Riesgo | Mitigación |
|--------|------------|
| Sin partnership aún → no se puede probar de verdad | Construir contra spec + fixtures; gating explícito en §3. |
| WAF/Incapsula bloquea webhooks de Uber al VPS | Validar alcance público del endpoint **antes** de certificar (precedente Azul). |
| Tocar `order_items.product_id` (NOT NULL→NULL) rompe KDS/inventario/pagos | Auditar consumidores; opción placeholder; pruebas de regresión (P2). |
| Totales Uber ≠ cálculo POS (promos Uber) | Total de Uber = fuente de verdad del cobro [T4]; reporte de conciliación en F6. |
| Fiscal/NCF de pedidos de agregador en RD | Diferir a F6 con el contador; F1 no emite NCF [T5]. |
| Ítems no mapeados sin inventario | Aceptado en F1; reconciliación 1-clic + sync de menú F3 [T6]. |

---

## 12. Preguntas abiertas (necesito tu respuesta para cerrar)

- **P1 (fiscal):** ¿los pedidos de Uber Eats deben emitir NCF en RD, o Uber factura al
  consumidor final? → consulta al contador (define F6 y si F1 debe etiquetar algo).
- **P2 (esquema):** para ítems no mapeados, ¿`order_items.product_id` NULLABLE +
  `external_item_name`, o **producto placeholder** "Uber Eats (sin mapear)" por negocio?
  (Recomiendo NULLABLE; menos sucio en catálogo.)
- **P3 (pago):** ¿marco la orden `paid` con método Uber Eats al ingerir (recomendado),
  o la dejo abierta hasta que cocina la complete?
- **P4 (multi-sucursal):** ¿un negocio puede tener varias tiendas Uber, o es 1:1
  `uber_store_id`↔`business_id`? (El diseño soporta 1:1; ampliar es trivial.)
- **P5 (alcance F1):** ¿el auto-accept [T1] te sirve para F1, dejando aceptar/rechazar
  manual para F2?

---

## 13. Checklist de implementación — Fase 1

- [ ] Onboarding Uber: app, scopes, credenciales sandbox, store_id de prueba, registrar webhook.
- [ ] Migración `20260617_0003_ubereats_integration_f1.sql` (+ ROLLBACK): tablas, seed pago, cambios `order_items`, RLS, `fn_ingest_ubereats_order`, grants.
- [ ] Edge function `ubereats-webhook` (firma HMAC, inbox, 200 rápido).
- [ ] Edge function `ubereats-processor` (OAuth, GET detalle, ingestión, auto-accept, cancelación).
- [ ] `_shared/ubereats.ts` (cliente OAuth + API) y `_shared/env.ts` extendido.
- [ ] `.env.example` con las nuevas variables.
- [ ] Flutter: badge/datos Uber en pantalla Delivery + aviso sonoro de nuevo pedido.
- [ ] Flutter: hoja de reconciliación de ítems `needs_review` → `ubereats_item_map`.
- [ ] Repos/datasources: registro `ubereats_orders`, mapeo, RPC.
- [ ] Pruebas (SQL idempotencia, edge HMAC, E2E sandbox) + `flutter analyze` limpio.
- [ ] Documentar despliegue (secretos en Coolify, registro de webhook) en `supabase/functions/DEPLOY.md`.

---

> **Siguiente paso sugerido:** responde P1–P5 (sobre todo P2 y P5) y confírmame si
> arranco las credenciales sandbox. Con eso implemento la migración F1 + las edge functions
> contra fixtures, listas para conectar en cuanto lleguen las credenciales de Uber.
