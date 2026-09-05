# PRD — Integración Pincer → MangoPOS (canal de pedidos online)

> **Estado:** Borrador para revisión
> **Fecha:** 2026-09-04
> **Dueño de producto:** Cristian Gómez
> **Contraparte:** Tamayo (Pincer)
> **Ámbito:** Que un pedido tomado en Pincer entre **solo** al POS como pedido de
> delivery/pickup, imprima comanda, llegue al KDS y siga el flujo normal de caja,
> cierre, NCF y reportes. Pincer llama a MangoPOS; MangoPOS no llama a Pincer.
> **Relación con otros PRDs:** este es el mismo motor de
> [PRD_UBER_EATS_INTEGRATION.md](PRD_UBER_EATS_INTEGRATION.md) (Fase 1), pero
> **más simple**: no hay OAuth, ni certificación, ni partnership. Lo que se
> construya aquí queda listo para Uber Eats / PedidosYa.

---

## 0. Decisión de alcance (cerrada con el dueño de producto)

El correo de Pincer pide seis cosas. **No son un producto, son tres.** El alcance
que se aprueba es solo el primero:

| # | Lo que pide Pincer | Decisión |
|---|---|---|
| A | Pedido online (delivery / para llevar) que entra solo, imprime comanda, ya viene pagado | ✅ **En alcance.** Es el canal tipo PedidosYa. Reusa `delivery_type`. |
| B | Sumar líneas a una **cuenta de mesa ya abierta** (comensal sentado ordena por QR) | ⛔ **Fuera de F1.** Requiere resolver mesa↔sesión↔check, rondas de comanda, atribución de mesero y el candado de órdenes huérfanas. Es un producto aparte (self-service en mesa). |
| C | **Pay-at-table**: leer la cuenta abierta y cobrarla desde el teléfono | ⛔ **Fuera de F1.** Toca NCF, propina, división de cuenta, cierre de caja y "quién es el cajero". El riesgo fiscal es real y no se justifica en la primera entrega. |

**Regla de oro de F1:** una orden de Pincer nace y muere como **delivery/pickup**.
Nunca toca una mesa del salón.

---

## 1. Punto por punto del correo de Tamayo

| Pedido de Pincer | Respuesta | Trabajo |
|---|---|---|
| 1. Autenticación por restaurante, revocable | Sí — API key por negocio en header `X-Api-Key`, hash en BD, revocable desde el panel | **Nuevo** (hoy solo existe API key de *lectura*) |
| 2. Crear orden con líneas, modificadores, notas, tipo de servicio | Sí para delivery/pickup. **No** para "agregar a mesa abierta" (ver §0-B) | **Nuevo** (RPC de ingesta) |
| 3. GET catálogo con id estable | Sí — `menu_items.id` es UUID y no cambia al editar nombre o precio | Casi listo (falta exponerlo) |
| 4. Leer mesas y su cuenta abierta | **No en F1** (ver §0-B/C) | — |
| 5. Registrar pago externo con referencia | Sí — `fn_process_payment_v3` ya acepta `p_reference` | Falta el método de pago "Pincer" y su tratamiento en cierre |
| 6. Idempotencia por identificador de ellos | Sí — `UNIQUE(business_id, external_order_id)`, repetición devuelve la orden ya creada | **Nuevo**, patrón ya usado en compras |
| Ambiente de pruebas | Sí — negocio de pruebas + `environment='sandbox'`; nunca imprime en Tropella | **Nuevo** (flag, no infra nueva) |
| Límites y códigos de error | Sí — tabla de errores en §5.4 + rate limit por API key | **Nuevo** |

---

## 2. Estado actual

### Ya existe (base reutilizable — no se reinventa)

- **Delivery como origen de orden.** `table_sessions.origin='delivery'` con
  `delivery_type ∈ {'own','uber_eats','pedidos_ya'}` (constraint `chk_delivery_type`)
  y el RPC `fn_open_delivery_order(p_user_id, p_delivery_type, p_people_count)`, que
  crea zona "Delivery", mesa temporal `DEL-NNN`, sesión y orden
  ([20260408_0002](../supabase/migrations/20260408_0002_delivery_system.sql)).
  → **Falta agregar `'pincer'` al CHECK.** Una línea.
- **Listado y pantalla de delivery.** `fn_list_delivery_orders(business_id)` y
  [`delivery_express_view.dart`](../lib/presentation/sales/view/delivery_express_view.dart)
  con canal Realtime `delivery_orders_{businessId}` en
  [`delivery_viewmodel.dart`](../lib/presentation/sales/viewmodel/delivery_viewmodel.dart).
- **Patrón maduro de integración externa:** inbox + procesador async de
  [`alanube-webhook`](../supabase/functions/alanube-webhook/index.ts) (receiver
  trivial que responde rápido y valida por header, trabajo pesado aparte).
- **Alta de línea con impuestos correctos:** `fn_add_item_from_menu(p_order_id,
  p_menu_item_id, p_qty, p_check_position, p_is_takeout, p_notes)` — resuelve precio,
  `menu_item_taxes`, promos e inventario. **La ingesta debe llamar a este RPC, no
  hacer INSERT crudo en `order_items`**, o la orden entra sin ITBIS.
- **Pago con referencia externa:** `fn_process_payment_v3(..., p_reference,
  p_customer_rnc, p_requested_ncf_type, p_cashier_session_id DEFAULT NULL, ...)`.
- **Métodos de pago por negocio:** `payment_methods(business_id, name, code, position, icon)`.
- **Idempotencia con clave del cliente:** patrón de
  [`fn_receive_purchase_order_v2`](../supabase/migrations/20260812_0001_fn_receive_purchase_order_v2.sql)
  (`idempotency_key` + advisory lock + devolver lo ya creado).
- **KDS en tiempo real:** escucha `order_items` por Realtime. Una orden ingerida
  con ítems en `pending` **aparece sola en el KDS**, sin código nuevo.
- **Cola de impresión:** `print_jobs` + `fn_claim_print_job` + agente Node +
  [`CloudPrintQueueWorker`](../lib/core/printing/cloud_print_queue_worker.dart).

### Falta (lo que construye este PRD)

1. **Autenticación de escritura por negocio** (API key hasheada + revocación + rate limit).
2. **Edge function `pincer-orders`** + inbox + **`fn_ingest_external_order`** idempotente.
3. **`'pincer'` en `chk_delivery_type`** y método de pago `pincer`.
4. **Impresión automática de la comanda** — ver §6, **es la pieza cara**.
5. **Sección "Órdenes" en Ventas** — bandeja de pedidos entrantes (§9).
6. **GET de catálogo** para que Pincer case sus platos.
7. **Modo sandbox** por API key.

---

## 3. Arquitectura (F1)

```
                       Pincer (sus servidores)
                             │  POST /pincer-orders
                             │  X-Api-Key: <clave del restaurante>
                             │  X-Idempotency-Key: <su # de orden>
                             ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ Edge Function: pincer-orders  (PÚBLICA, service_role interno) │
  │  1. Resuelve API key → business_id + environment              │
  │  2. Guarda el payload crudo en external_order_inbox           │
  │  3. RPC fn_ingest_external_order(payload)  ← transaccional    │
  │  4. Responde 201 con { order_id, order_number, status }       │
  │     o 200 con la MISMA orden si la clave se repite            │
  └──────────────────────────────────────────────────────────────┘
                             │
                             ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ DB: fn_ingest_external_order(jsonb)  SECURITY DEFINER         │
  │  - idempotente por (business_id, external_order_id)           │
  │  - fn_open_delivery_order(...) con delivery_type='pincer'     │
  │  - por cada línea: fn_add_item_from_menu + modificadores      │
  │      · id resuelto  → precio/ITBIS/inventario correctos       │
  │      · id no resuelto → línea ad-hoc marcada needs_review     │
  │  - si viene pagada: fn_process_payment_v3 método 'pincer'     │
  │    con p_reference = referencia de la transacción             │
  │  - items en 'pending' + status_ext='sent_to_kitchen' → KDS    │
  │  - guarda external_orders (vínculo + raw + total de ellos)    │
  └──────────────────────────────────────────────────────────────┘
                             │ Realtime
             ┌───────────────┴────────────────┐
             ▼                                ▼
      KDS (ya funciona)          Sección "Órdenes" en Ventas (nueva)
                                  + aviso sonoro
                                  + IMPRESIÓN DE COMANDA (§6)
```

**Por qué el receiver ingiere en línea (a diferencia de Alanube):** Pincer necesita
saber en la misma llamada si la orden entró, para decidir si cae al respaldo manual
de su tablet. Un 202 "ya veremos" no le sirve. La ingesta es una sola transacción de
BD, es rápida. El inbox se guarda igual, **antes** de ingerir, para que ningún pedido
se pierda aunque la RPC falle.

---

## 4. Modelo de datos

Todo aditivo, `business_id`-scoped, RLS estilo Alanube. Migración propuesta
`20260905_0001_external_orders_channel.sql` (+ `_ROLLBACK.sql`).
**Nombres genéricos (`external_*`), no `pincer_*`:** el mismo motor sirve para
Uber Eats y PedidosYa.

### 4.1 `external_api_keys` — credencial por negocio
```
id             uuid pk
business_id    uuid fk businesses
channel        text not null            -- 'pincer' | 'uber_eats' | ...
key_prefix     text not null            -- 8 chars visibles, para identificarla en el panel
key_hash       text not null            -- sha256 de la clave completa; la clave se muestra UNA vez
environment    text check (sandbox|production) default 'sandbox'
scopes         text[] default '{orders:write,catalog:read}'
rate_limit_rpm int default 120
is_active      boolean default true     -- revocación = false
last_used_at   timestamptz
created_at, revoked_at
```
RLS: sin policies para `authenticated` salvo lectura del prefijo por el dueño del
negocio. Solo `service_role` valida el hash.

### 4.2 `external_order_inbox` — nada se pierde
```
id, business_id, channel, external_order_id, payload jsonb, headers jsonb,
http_status int, processed boolean, error text, received_at
```

### 4.3 `external_orders` — vínculo 1:1
```
id                uuid pk
business_id       uuid fk businesses
channel           text
external_order_id text not null            -- UNIQUE (business_id, external_order_id)
external_number   text                     -- el # corto que ve el cliente (va IMPRESO en la comanda)
order_id          uuid fk orders
session_id        uuid fk table_sessions
service_type      text                     -- 'delivery' | 'pickup'
paid_externally   boolean
external_total    numeric                  -- lo que ellos cobraron (fuente de verdad del cobro)
payment_reference text
customer_name, customer_phone, delivery_address text
customer_rnc      text
raw_order         jsonb
created_at, updated_at
```

### 4.4 `external_item_map` — solo por si acaso
```
business_id, channel, external_item_id, menu_item_id   -- UNIQUE(business_id, channel, external_item_id)
```
Pincer dijo que va a mandar **nuestro** `menu_items.id`. Si lo hace, esta tabla queda
vacía y se ignora. Existe como red: si mandan un id suyo, se mapea aquí y no se pierde
el pedido.

---

## 5. Contrato de API

Base: `https://supabase.mangopos.do/functions/v1/`
Auth: header `X-Api-Key`. Todo JSON, UTF-8. Montos en **decimal con 2 posiciones**,
no en centavos (el POS trabaja en `numeric`; convertir en el borde crea errores de
redondeo en el ITBIS).

### 5.1 `GET /pincer-catalog`
```json
{
  "business": { "id": "…", "name": "Tropella", "currency": "DOP" },
  "categories": [{ "id": "…", "name": "Platos fuertes", "position": 1 }],
  "items": [
    {
      "id": "9f3c…",                    // ESTABLE. No cambia al editar nombre ni precio.
      "name": "Pechuga a la plancha",
      "category_id": "…",
      "price": 450.00,                  // precio de menú (impuesto según config del negocio)
      "is_active": true,
      "image_url": "…",
      "modifier_groups": [
        { "id": "…", "name": "Acompañante", "min_select": 1, "max_select": 1,
          "modifiers": [{ "id": "…", "name": "Tostones", "price_delta": 0 }] }
      ]
    }
  ]
}
```

### 5.2 `POST /pincer-orders`
```json
{
  "external_order_id": "PIN-2026-000123",   // idempotencia
  "external_number": "A-142",               // se IMPRIME en la comanda
  "service_type": "delivery",               // delivery | pickup
  "placed_at": "2026-09-04T18:22:11Z",
  "customer": { "name": "Juan Pérez", "phone": "809…", "rnc": null,
                "address": "Calle 1 #4, Naco" },
  "payment": { "status": "paid", "total": 1250.00, "method": "card",
               "reference": "azul-8837261" },
  "lines": [
    { "menu_item_id": "9f3c…", "quantity": 2, "notes": "sin cebolla",
      "modifiers": [{ "modifier_id": "…", "quantity": 1 }] }
  ]
}
```
Respuesta `201`:
```json
{ "order_id": "…", "order_number": "DEL-018", "external_number": "A-142",
  "status": "accepted", "printed": true, "kds": true, "pos_total": 1250.00 }
```
Repetir la misma `external_order_id` devuelve `200` con **el mismo cuerpo**, sin crear
ni imprimir nada de nuevo.

### 5.3 `GET /pincer-orders/{external_order_id}`
Para que Pincer confirme el estado tras un timeout: `accepted | preparing | ready |
delivered | cancelled`, con `pos_total`.

### 5.4 Errores

| HTTP | code | Significado | ¿Reintentar? |
|---|---|---|---|
| 401 | `invalid_api_key` | Clave inválida o revocada | No |
| 403 | `channel_disabled` | El restaurante apagó Pincer en su POS | No |
| 409 | `duplicate_order` | Ya existe (se devuelve la orden) | No |
| 422 | `unknown_menu_item` | `menu_item_id` no existe en ese negocio | No — corregir el mapeo |
| 422 | `invalid_payload` | Falta un campo o el formato es inválido | No |
| 429 | `rate_limited` | Excedió `rate_limit_rpm` (header `Retry-After`) | Sí, con backoff |
| 503 | `pos_unavailable` | BD caída / mantenimiento | Sí, con backoff |
| 500 | `internal_error` | Bug nuestro, ya quedó en el inbox | Sí, y avisar |

**Regla para Pincer:** solo `429`, `503` y `500` se reintentan. Todo lo demás es
definitivo y va al respaldo manual de su tablet.

---

## 6. La comanda — la pieza que no es obvia

**Insertar la orden en la base de datos NO imprime nada.** Los bytes ESC/POS los
arma la app Flutter (`lib/services/printing/`), no el servidor: `print_jobs.data_hex`
ya viene renderizado desde el cliente. Un pedido que nace en el servidor **no tiene
quién lo imprima**.

El KDS sí lo ve solo (escucha `order_items` por Realtime). Pero el restaurante que
imprime comanda en papel no vería nada.

**Solución F1 — receptor en la app (recomendada):** una tablet del local se designa
**"estación de recepción"** (bandera por dispositivo, igual que `host_device_id` de
impresoras). Esa app escucha el canal Realtime de delivery, y al ver una orden nueva
de canal externo:
1. suena el aviso,
2. arma la comanda con el builder que ya existe (agregando `external_number`, que es
   como el personal identifica el pedido para llevar),
3. la manda por el dispatcher de cocina normal (con su fallback a `print_jobs`).

Ventajas: reusa todo el camino probado de impresión, respeta áreas de impresión y
el modo sin impresora. Riesgo: si esa tablet está apagada, no hay comanda — se mitiga
con el aviso visible en la sección Órdenes y con un segundo dispositivo de respaldo
(el claim atómico de `fn_claim_print_job` ya evita la doble impresión).

**Alternativa descartada para F1:** renderizar ESC/POS en el servidor. Sería duplicar
en TypeScript los cinco builders de ticket, la lógica de 58/80 mm y el modo raster de
Star. Mucho trabajo y dos fuentes de verdad para el mismo papel.

> **Advertencia para el contrato con Pincer:** por eso `"printed": true` en la
> respuesta significa *"encolada para imprimir"*, no *"salió el papel"*. No prometer
> lo segundo.

---

## 7. Pago externo y cierre de caja

El cobro ya ocurrió en Pincer. El POS **registra el ingreso, no lo cobra**.

- Método de pago nuevo por negocio: `('Pincer', 'pincer')`, con
  `p_reference = payment.reference`.
- **No exige sesión de caja abierta** (`p_cashier_session_id` va NULL). Un pedido a
  las 3 a.m. con la caja cerrada tiene que entrar igual. Esto es deliberado y sigue
  el mismo criterio del abono a crédito.
- **No entra al cuadre de efectivo.** En el cierre aparece como bloque aparte
  ("Ingresos por canal externo"), sin afectar el conteo del cajón. Si se suma al
  efectivo esperado, el cajero cuadra corto todos los días.
- **Divergencia de totales:** si `payment.total` de Pincer ≠ total calculado por el
  POS (promos, ITBIS, fee de delivery), se registra el pago por el total de Pincer y
  la diferencia queda visible en `external_orders` para conciliación. **No** se deja
  que el motor de impuestos reescriba lo que el cliente ya pagó.

---

## 8. Fiscal (NCF / RNC)

- Sin RNC: consumo normal, flujo fiscal del negocio sin cambios.
- Con RNC: `fn_process_payment_v3` ya acepta `p_customer_rnc` y
  `p_requested_ncf_type`; se pide crédito fiscal (B01/E31) por la vía normal.
- **Riesgo a revisar con el contador:** el NCF se emite al registrar el pago, es decir
  al momento de la ingesta, no cuando el cliente estaba en el checkout de Pincer.
  Si Pincer quiere mostrarle el NCF al cliente en su app, hace falta que consulten
  `GET /pincer-orders/{id}` después (el e-CF de Alanube es asíncrono).
- Pincer debe validar el RNC en su checkout (longitud 9/11 y dígito verificador).
  Un RNC malo hoy revienta la emisión del comprobante.

---

## 9. Sección "Órdenes" en Ventas (F2)

Lo que hoy es `/ventas?mode=delivery` se queda para el delivery propio digitado a
mano. Se agrega una **sección "Órdenes"** en el shell de ventas: bandeja de todo lo
que entra por canales externos.

- **Lista por estado:** Nuevas (badge + sonido) → En preparación → Listas → Entregadas.
- **Tarjeta:** número de Pincer bien grande (es como piden el pedido en el mostrador),
  tipo de servicio, cliente, hora, total, marca "Pagado".
- **Acciones:** ver detalle, **reimprimir comanda**, marcar lista, cancelar.
- **Rojo visible** cuando una orden entró pero la comanda no se pudo imprimir.
- **Reconciliación** de líneas `needs_review` (ítem que no resolvió) en un clic.
- Permiso nuevo `ventas.ordenes.ver` — **hay que sembrarlo en el catálogo de
  permisos de la BD o el RPC lo descarta en silencio.**

---

## 10. Fases

| Fase | Contenido | Depende de |
|---|---|---|
| **F0** | Migración: `'pincer'` en `chk_delivery_type`, método de pago, tablas §4, permiso | — |
| **F1a** | Edge functions `pincer-catalog` + `pincer-orders` + `fn_ingest_external_order` | F0 |
| **F1b** | Receptor de impresión en la app (§6) | F1a |
| **F1c** | Sección "Órdenes" (§9) | F1a |
| **F2** | Sandbox por API key + panel de credenciales (crear/revocar) | F1a |
| **F3** | `GET /pincer-orders/{id}` + estados hacia Pincer | F1c |
| **F4** *(futuro)* | Pedido a mesa abierta y pay-at-table (§0-B, §0-C) | decisión aparte |

Lo que se entrega en F1 sirve **tal cual** para Uber Eats y PedidosYa: solo cambia el
`channel` y quien traduce el payload.

---

## 11. Riesgos

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | La tablet receptora apagada → sin comanda | Aviso en Órdenes + segundo dispositivo + `print_jobs` como cola |
| R2 | `fn_confirm_order_to_kitchen` **no tiene guard** y puede resucitar órdenes pagadas (caso conocido: 6,009 órdenes atascadas) | La ingesta NO debe llamarlo sobre una orden ya pagada; marcar los ítems directamente |
| R3 | Ítem sin ITBIS vinculado entra en 0 | El catálogo expone qué ítems no tienen impuesto; se corrige antes de salir a producción |
| R4 | Total de Pincer ≠ total del POS | Se registra el de ellos + reporte de conciliación (§7) |
| R5 | Pincer reintenta en pico y satura | Rate limit por API key + `Retry-After` |
| R6 | Pedido de prueba imprime en Tropella | `environment='sandbox'` obligatorio hasta certificar; negocio de pruebas aparte |
| R7 | La orden entra pero el KDS no la muestra | El KDS mira `order_items.status` y `kitchen_done_at`, no `status_ext`: la ingesta debe dejar los ítems en `pending` |

---

## 12. Preguntas abiertas

- **P1.** ¿Pincer cobra propina? Hoy no viene en su payload y el POS la maneja aparte.
- **P2.** ¿Qué pasa si el restaurante cancela un pedido ya pagado en Pincer? ¿Quién
  devuelve el dinero, y se emite nota de crédito?
- **P3.** ¿Fee de la plataforma? Si Pincer retiene comisión, el ingreso bruto en el POS
  no es lo que el restaurante recibe. Definir si se registra bruto (recomendado) o neto.
- **P4.** ¿Sandbox contra qué? Opciones: negocio de pruebas en el mismo stack (rápido,
  suficiente) o el clon del VPS (más limpio, más caro de mantener).
- **P5.** Consulta al contador sobre el momento de emisión del NCF (§8).

---

## Anexo — Borrador de respuesta a Tamayo

> Tamayo, buenas.
>
> Revisé lo que necesitan y te contesto punto por punto, con lo que sí podemos y
> con lo que prefiero dejar para una segunda etapa.
>
> **Lo que hacemos primero.** El pedido de Pincer entra a MangoPOS como un pedido de
> delivery o para llevar, con sus líneas, modificadores, notas y su número de orden
> impreso en la comanda; sale en cocina y en el KDS, y el pago que ustedes ya cobraron
> queda registrado con su referencia para que el cierre cuadre. Ese es el corazón de
> lo que pediste y es lo que vamos a entregar.
>
> **Lo que sí les damos tal como lo pidieron:** credencial por restaurante que podemos
> revocar, GET del catálogo con un id estable por producto (nuestro id es un UUID que
> no cambia al editar nombre ni precio, así que casan contra eso), idempotencia por el
> identificador de ustedes — si repiten por timeout les devolvemos la orden ya creada,
> sin segunda comanda —, ambiente de pruebas separado para que nada imprima en
> Tropella mientras desarrollan, y una tabla de códigos de error que distingue lo que
> vale la pena reintentar de lo que no.
>
> **Lo que prefiero dejar para después, y por qué.** Los puntos de sumar líneas a una
> mesa abierta y de que el comensal vea y pague su cuenta desde el teléfono no son una
> extensión del primero: son otro producto. Ahí entran la división de cuentas, la
> propina, el NCF, la atribución del mesero y el cierre de caja del cajero que está en
> turno. Se puede hacer y nos interesa, pero mal hecho rompe la caja del restaurante, y
> prefiero que la primera integración salga sólida.
>
> **Un detalle técnico que conviene que sepan.** Cuando les respondamos "aceptada", eso
> significa que la orden entró y quedó encolada para imprimir. La impresora física
> depende de la red del local; si una comanda no sale, queda marcada en rojo en el POS
> para que el personal la reimprima. No es un caso de reintentar del lado de ustedes.
>
> **Lo del respaldo, de acuerdo contigo:** reintentan ante 429, 503 y 500; si aun así
> falla, el pedido sigue en su tablet para digitarlo a mano. Como respaldo, no como
> norma.
>
> Te paso la documentación de los endpoints con los ejemplos de JSON esta semana.
> Dos preguntas para dimensionar: ¿manejan propina en el checkout, y retienen comisión
> sobre el total? Eso cambia cómo registramos el ingreso.
>
> Saludos,
> Cristian
