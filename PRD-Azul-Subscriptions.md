# PRD — Integración Azul / DataVault para Suscripciones MangoPOS

| Campo | Valor |
|---|---|
| **Autor** | Cristian (DRI) |
| **Estado** | Draft v1 — pendiente de aprobación |
| **Fecha** | 25 mayo 2026 |
| **Ámbito** | Cobros de suscripción SaaS de MangoPOS (B2B → comercios pilotos) |
| **Procesador** | Azul / Servicios Digitales Popular — Payment Page + DataVault Web Service |
| **Ambiente inicial** | Pruebas (`pruebas.azul.com.do`) con MID `39038540035` |
| **Dependencias bloqueantes** | Doc de Web Services DataVault + habilitación IPN + (eventualmente) MID de producción |

---

## 1. Contexto y problema

MangoPOS hoy factura su SaaS a los comercios pilotos por canales no automatizados (Stripe en algunos casos, transferencia bancaria o cobro manual en otros). Esto tiene tres problemas concretos:

1. **Stripe no es viable a escala en RD.** Las tarjetas dominicanas tienen una tasa alta de declinación en Stripe por restricciones cross-border y FX. Para un SaaS local cobrando en DOP a comercios locales, el procesador local (Azul) tiene tasas de aprobación significativamente más altas y comisiones más razonables.
2. **El cobro manual no escala.** A medida que el piloto crece más allá de los primeros comercios, perseguir pagos manualmente es insostenible. Cada cliente moroso es horas perdidas en cobranza.
3. **No hay tarjeta en archivo, no hay churn involuntario controlado.** Sin un método de pago tokenizado, una declinación temporal de un mes se convierte en cancelación total del servicio porque el cliente no vuelve a llenar el formulario.

Este PRD integra Azul como procesador de cobros recurrentes para las suscripciones SaaS de MangoPOS, **no** como pasarela de pago para los clientes finales de los comercios (ese sería un PRD separado, fuera de alcance).

## 2. Objetivos

1. **Capturar una tarjeta en archivo** en el momento del registro de un comercio nuevo, sin cobrarle realmente (Hold + Void de RD$1).
2. **Cobrar mensualmente** el plan vigente del comercio contra esa tarjeta, sin intervención humana.
3. **Manejar fallos** (declinaciones temporales) con una política de reintentos clara y suspender el servicio cuando esos reintentos se agoten.
4. **Permitir al comercio cambiar su tarjeta** desde la app Flutter (Settings → Billing) sin perder el acceso al servicio.
5. **Soportar trial de 14 días** sin cobro, con tarjeta requerida al inicio.
6. **Soportar prorrateo** cuando un comercio cambia de plan a mitad de mes.
7. **Emitir comprobante PDF** vía email después de cada cobro exitoso.
8. **Auditoría completa** de toda interacción con Azul (request + response + hash + timestamp), inmutable.

## 3. No-objetivos

Para que el alcance no se infle, estos puntos quedan **explícitamente fuera** de este PRD:

- ❌ Procesar pagos de clientes finales del comercio a través de MangoPOS (ej. pagar la cuenta de un restaurante con tarjeta vía Azul). Eso es un PRD futuro.
- ❌ Facturación fiscal con NCF/DGII. Por ahora el comprobante es un PDF informativo, no un comprobante fiscal válido. Cuando se requiera NCF se hará en un PRD adicional.
- ❌ Soporte multi-moneda. Solo DOP en este PRD.
- ❌ Métodos de pago alternativos (PayPal, Google Pay, Apple Pay, transferencia, efectivo). Solo tarjeta vía Azul.
- ❌ 3D Secure / DCC / Cuotas. Pueden activarse después si Azul lo soporta sobre el MID; no es bloqueante para v1.
- ❌ Dunning sofisticado (emails progresivos, in-app messaging, descuentos retención). Por ahora solo email de fallo + suspensión.
- ❌ Reembolsos parciales o disputas. Si se requiere reembolso se hace manualmente en el portal de Azul por v1.
- ❌ Dashboard web de administración interna. La gestión interna se hace por SQL directo en Supabase por v1.

## 4. Decisiones arquitectónicas clave

| # | Decisión | Justificación |
|---|---|---|
| D1 | **AuthKey vive solo en Supabase Secrets**, nunca en cliente, nunca en código fuente, nunca en repos. | Si la AuthKey se filtra, cualquiera puede firmar transacciones contra nuestro MID. Es la credencial más sensible del sistema. |
| D2 | **Encoding UTF-8 para AuthHash** (no UTF-16LE). | Validado byte-exacto contra el golden test del archivo `Ejemplo Calculo Hash SALE.TXT`. Azul acepta ambos según el doc. UTF-8 es nativo en Deno/TypeScript (Edge Functions) y elimina una clase entera de bugs de encoding. |
| D3 | **Verificación de tarjeta = Hold de RD$1 + Void inmediato + SaveToDataVault=1.** | (a) El cliente nunca ve un cargo real en su estado de cuenta; (b) Hold se puede anular en cualquier momento (Sale solo en los primeros 20 min); (c) tokenizamos y validamos en un solo round-trip. |
| D4 | **El POST inicial a Azul lo hace el browser del cliente**, no nuestro server. | Es requerimiento explícito del doc Azul (pág. 4). Nuestro backend genera el form HTML auto-submit, lo sirve como página, el browser lo postea. |
| D5 | **Cobros recurrentes via Web Service DataVault**, no Payment Page. | Payment Page requiere browser activo del cliente. Para cobros mensuales el cliente no está presente. WS DataVault es server-to-server con el token guardado. |
| D6 | **Idempotencia por `OrderNumber` único determinístico.** | Formato: `mp_{business_id}_{intent_type}_{YYYYMM}` para cobros mensuales, `mp_tok_{uuid_v4}` para tokenizaciones. Permite que el cron corra dos veces sin doble cobro. |
| D7 | **Tablas nuevas aisladas, prefijo `azul_`. Strangler fig estricto: cero alteraciones a tablas existentes en este PRD.** | Aprendizaje de los PRDs 1-5 de MangoPOS. La integración con `subscriptions` existentes se hace solo por lectura, vía vistas o RPC. La escritura cruzada vendrá en un PRD posterior cuando esté validado el flujo. |
| D8 | **Validación de AuthHash de respuesta es obligatoria y se hace en backend.** Si falla, el callback se rechaza y la sesión queda en estado `tampered` para investigación. | Sin validación, cualquiera puede simular un callback aprobado golpeando nuestra Edge Function. Es el único mecanismo de autenticidad que tenemos hasta que Azul habilite IPN. |
| D9 | **IPN (server-to-server webhook) será la fuente de verdad eventual, no el redirect.** Hasta que Azul lo habilite, hacemos polling defensivo. | El redirect del browser puede no llegar (cliente cierra el tab, pierde conexión). IPN es garantizado por Azul. |
| D10 | **Cron en `pg_cron` invocando Edge Function vía `net.http_post`.** | pg_cron está nativo en Supabase, no requiere infraestructura adicional, y la Edge Function tiene el contexto correcto para hablar con Azul. |
| D11 | **Política de reintentos: 3 intentos en días 1, 3, 7 desde el primer fallo. Al cuarto fallo, suspensión inmediata.** | Discutido y aprobado en la fase de descubrimiento. |
| D12 | **Trial de 14 días sin cobro, tarjeta requerida al registro.** | Discutido y aprobado. Reduce fricción del registro (no se cobra ya) sin perder card-on-file (compromiso). |
| D13 | **Prorrateo lineal al cambiar de plan.** Si quedan N días del mes y cambia de plan A (precio P_A) a plan B (precio P_B), se cobra `(P_B - P_A) * N / días_del_mes` al momento del cambio. Si el resultado es negativo (downgrade), se acredita al próximo cobro. | Estándar de la industria. Simple, transparente, fácil de explicar al cliente. |

## 5. Modelo de datos

Todas las tablas nuevas viven en el schema `public` con prefijo `azul_` para señalizar dominio. Todas tienen `id uuid primary key default gen_random_uuid()`, `created_at`, `updated_at`, y RLS habilitado.

### 5.1 `azul_payment_methods`

Tarjetas tokenizadas asociadas a un `business_id`. Un business puede tener múltiples, pero solo uno marcado `is_default=true` a la vez (constraint).

```sql
create table azul_payment_methods (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete restrict,

  -- Token y metadatos provenientes de Azul
  data_vault_token text not null,        -- ej: FE1525FD-A59B-476A-9EFA-387D510689AB
  data_vault_expiration text not null,   -- formato AAAAMM, ej: 202812
  data_vault_brand text not null,        -- VISA, MASTERCARD, AMEX, etc.
  card_number_masked text not null,      -- ej: 542418******1732
  azul_order_id_at_creation text,        -- # de orden del posproceso de creación

  -- Estado
  status text not null default 'pending_verification'
    check (status in ('pending_verification', 'verified', 'failed_verification', 'expired', 'revoked')),
  is_default boolean not null default false,

  -- Auditoría
  verification_session_id uuid references azul_payment_sessions(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoke_reason text
);

create unique index azul_payment_methods_one_default_per_business
  on azul_payment_methods(business_id) where is_default = true;

create index azul_payment_methods_business on azul_payment_methods(business_id);
create index azul_payment_methods_status on azul_payment_methods(status);
```

**Notas:**
- `data_vault_token` no es PCI scope (no es PAN, no es CVV, no es Track), pero igual lo tratamos como secreto: RLS prohíbe SELECT a clients, solo backend lo puede leer vía service_role.
- `card_number_masked` es lo único que puede mostrarse en UI: `**** **** **** 1732`.
- Un business puede tener varios payment methods en histórico (uno por cada cambio de tarjeta), pero solo uno `is_default` a la vez. El constraint parcial garantiza esto a nivel DB.

### 5.2 `azul_payment_sessions`

Cada intento de interacción con Payment Page (tokenización, verificación, eventualmente otros tipos). Es la tabla de "intents".

```sql
create table azul_payment_sessions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete restrict,

  -- Tipo y orden
  intent_type text not null
    check (intent_type in ('tokenize_and_verify', 'replace_card', 'manual_charge')),
  order_number text not null unique,    -- enviado a Azul como OrderNumber
  amount_cents integer not null,        -- siempre 100 para verificación (RD$1.00)
  currency_code text not null default 'DOP',

  -- Hash request (para auditoría — no se reusa)
  auth_hash_sent text not null,

  -- Estado de la sesión
  status text not null default 'pending'
    check (status in (
      'pending',           -- creada, esperando que el cliente complete el form
      'redirected',        -- el cliente fue redirigido a Azul
      'approved',          -- Azul devolvió aprobado y AuthHash válido
      'declined',          -- Azul devolvió declinado
      'cancelled',         -- cliente canceló en Azul
      'tampered',          -- callback recibido con AuthHash inválido
      'timeout',           -- expiró sin callback (>30 min)
      'error'              -- error técnico
    )),

  -- Respuesta de Azul (poblados al recibir callback)
  azul_order_id text,
  authorization_code text,
  response_code text,
  iso_code text,
  response_message text,
  error_description text,
  rrn text,
  auth_hash_received text,
  raw_callback_query text,              -- query string completo para auditoría

  -- Relaciones
  resulting_payment_method_id uuid references azul_payment_methods(id),

  -- Timestamps
  created_at timestamptz not null default now(),
  redirected_at timestamptz,
  completed_at timestamptz,
  expires_at timestamptz not null default (now() + interval '30 minutes'),

  -- Defensa idempotencia
  callback_count integer not null default 0,
  updated_at timestamptz not null default now()
);

create index azul_payment_sessions_business on azul_payment_sessions(business_id);
create index azul_payment_sessions_status on azul_payment_sessions(status);
create index azul_payment_sessions_order_number on azul_payment_sessions(order_number);
create index azul_payment_sessions_expires_at on azul_payment_sessions(expires_at)
  where status in ('pending', 'redirected');
```

**Notas:**
- `order_number` es UNIQUE a nivel global. Formato propuesto: `mp_tok_{base32(uuid)}` para que sea legible en logs y único cross-business.
- `callback_count` permite detectar callbacks duplicados (cliente recarga la página de Azul). El primer callback con AuthHash válido decide el resultado; los siguientes se loguean pero no alteran el estado.
- `expires_at` permite a un job de mantenimiento marcar sesiones huérfanas como `timeout` después de 30 min, evitando que queden en `pending` para siempre.

### 5.3 `azul_charges`

Cada cobro mensual concreto (o cualquier transacción de venta vía DataVault).

```sql
create table azul_charges (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete restrict,
  subscription_id uuid not null references subscriptions(id) on delete restrict,
  payment_method_id uuid not null references azul_payment_methods(id) on delete restrict,

  -- Identidad del cobro
  order_number text not null unique,    -- mp_chg_{business_id}_{YYYYMM}_{attempt}
  billing_period_start date not null,
  billing_period_end date not null,
  attempt_number integer not null default 1 check (attempt_number between 1 and 3),

  -- Monto
  amount_cents integer not null,
  itbis_cents integer not null default 0,
  currency_code text not null default 'DOP',

  -- Respuesta de Azul
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'declined', 'error', 'voided')),
  authorization_code text,
  response_code text,
  iso_code text,
  response_message text,
  error_description text,
  rrn text,
  azul_order_id text,
  raw_request jsonb,                    -- para auditoría
  raw_response jsonb,                   -- para auditoría

  -- PDF de comprobante
  receipt_pdf_path text,                -- path en Supabase Storage
  receipt_emailed_at timestamptz,

  -- Timestamps
  attempted_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index azul_charges_one_per_period_per_attempt
  on azul_charges(subscription_id, billing_period_start, attempt_number);

create index azul_charges_business on azul_charges(business_id);
create index azul_charges_subscription on azul_charges(subscription_id);
create index azul_charges_status on azul_charges(status);
create index azul_charges_attempted_at on azul_charges(attempted_at desc);
```

**Notas:**
- El UNIQUE compuesto `(subscription_id, billing_period_start, attempt_number)` garantiza que no podamos crear dos veces el mismo intento de cobro para el mismo período. Es la idempotencia a nivel DB.
- `raw_request` y `raw_response` se almacenan como `jsonb` para auditoría futura y debugging. Nunca se exponen vía API al cliente; solo lectura backend.
- `receipt_pdf_path` apunta a Supabase Storage donde vive el PDF generado.

### 5.4 `azul_webhook_events`

Log inmutable de todo lo que llegue desde Azul (callbacks de Payment Page e IPN cuando se habilite). Append-only por diseño.

```sql
create table azul_webhook_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null
    check (event_type in ('payment_page_callback', 'ipn_notification', 'webservice_response')),
  source_ip inet,
  http_method text,
  raw_url text,
  raw_query jsonb,
  raw_body text,
  raw_headers jsonb,
  related_session_id uuid references azul_payment_sessions(id),
  related_charge_id uuid references azul_charges(id),
  auth_hash_valid boolean,
  processed boolean not null default false,
  processing_error text,
  received_at timestamptz not null default now()
);

create index azul_webhook_events_received_at on azul_webhook_events(received_at desc);
create index azul_webhook_events_session on azul_webhook_events(related_session_id);
create index azul_webhook_events_charge on azul_webhook_events(related_charge_id);
create index azul_webhook_events_unprocessed on azul_webhook_events(received_at)
  where processed = false;
```

**Notas:**
- Esta tabla es **append-only por convención**: no se hace UPDATE ni DELETE excepto para marcar `processed=true`. Sirve como bitácora forense.
- Si en un futuro queremos validar firma de IP origen de Azul, `source_ip` ya está capturado.

### 5.5 `azul_subscription_state`

Esta tabla es el puente entre `subscriptions` (existente) y nuestra integración con Azul, sin tocar la tabla existente. Es un "extension table" patrón.

```sql
create table azul_subscription_state (
  subscription_id uuid primary key references subscriptions(id) on delete cascade,

  -- Estado de la integración Azul
  billing_status text not null default 'trial'
    check (billing_status in (
      'trial',              -- en período de prueba, sin cobros
      'active',             -- pagando al día
      'past_due',           -- cobro fallido, en reintentos
      'suspended',          -- reintentos agotados, acceso bloqueado
      'cancelled'           -- cancelado por el comercio o admin
    )),

  trial_ends_at timestamptz,
  next_billing_date date,               -- siguiente fecha de cobro
  last_successful_charge_id uuid references azul_charges(id),
  last_failed_charge_id uuid references azul_charges(id),
  current_attempt_number integer default 0,
  suspended_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index azul_subscription_state_billing_status on azul_subscription_state(billing_status);
create index azul_subscription_state_next_billing_date on azul_subscription_state(next_billing_date)
  where billing_status in ('active', 'past_due');
```

**Notas:**
- Esto reemplaza, para la lógica de cobro Azul, lo que `subscriptions.status` o columnas similares hagan hoy. La tabla existente sigue siendo source of truth para "qué plan tiene el comercio" pero el ciclo de vida del cobro vive acá.
- En un PRD futuro se puede consolidar; por ahora vivimos en paralelo.
- `next_billing_date` permite que el cron sea un simple `WHERE next_billing_date <= today AND billing_status = 'active'`.

### 5.6 RLS Policies

Resumen (los `CREATE POLICY` completos van en la migración de DB):

| Tabla | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `azul_payment_methods` | Usuario del business (sin `data_vault_token`) | Solo `service_role` | Solo `service_role` | Nadie (soft delete vía `status='revoked'`) |
| `azul_payment_sessions` | Solo `service_role` | Solo `service_role` | Solo `service_role` | Nadie |
| `azul_charges` | Usuario del business (sin `raw_request`/`raw_response`) | Solo `service_role` | Solo `service_role` | Nadie |
| `azul_webhook_events` | Solo `service_role` | Solo `service_role` | Solo `service_role` (marcar processed) | Nadie |
| `azul_subscription_state` | Usuario del business | Solo `service_role` | Solo `service_role` | Solo cascade desde `subscriptions` |

Para exponer al cliente datos de `azul_payment_methods` y `azul_charges` sin filtrar campos sensibles, se crean vistas en `public`:

```sql
create view azul_payment_methods_public as
  select id, business_id, data_vault_brand, card_number_masked, status, is_default,
         created_at, revoked_at
  from azul_payment_methods;

create view azul_charges_public as
  select id, business_id, subscription_id, order_number,
         billing_period_start, billing_period_end, attempt_number,
         amount_cents, itbis_cents, currency_code,
         status, response_message, attempted_at, completed_at,
         receipt_pdf_path
  from azul_charges;
```

Las vistas heredan las RLS policies de las tablas base. Esto es estándar Supabase.

## 6. Algoritmo del AuthHash

### 6.1 Reglas generales

- **Algoritmo:** HMAC-SHA512.
- **Encoding:** UTF-8 (decisión D2).
- **Output:** hex lowercase de 128 caracteres.
- **Key:** la `AuthKey` que Azul entrega aparte. Nunca viaja en el POST. Vive solo en `SUPABASE_SECRET_AZUL_AUTH_KEY`.
- **Concatenación sin separadores.** Los campos se concatenan directamente, en orden estricto. Campos vacíos producen string vacío ("").

### 6.2 Orden de campos por TrxType

**Sale (venta simple):**
```
MerchantId + MerchantName + MerchantType + CurrencyCode + OrderNumber
+ Amount + ITBIS + ApprovedUrl + DeclinedUrl + CancelUrl
+ UseCustomField1 + CustomField1Label + CustomField1Value
+ UseCustomField2 + CustomField2Label + CustomField2Value
+ AuthKey
```

**Hold (pre-autorización, lo usaremos para verificación):**
- Mismo orden que Sale, pero con `TrxType=Hold` en el form. El campo `TrxType` NO entra al hash según el doc (solo viaja en el POST).

**Create (tokenización sin cobro):**
- Mismo orden que Sale. `Amount=0`, `ITBIS=000`. `TrxType=CREATE` en el form pero no en el hash.

**Sale con DataVault (cobro recurrente vía WS):**
- Esta NO usa Payment Page sino el Web Service. El orden de campos lo define el doc del Web Service DataVault (pendiente de recibir). Asumimos por ahora que será similar pero NO lo damos por seguro hasta tener el doc.

**Respuesta (validar AuthHash recibido):**
```
OrderNumber + Amount + AuthorizationCode + DateTime + ResponseCode
+ ISOCode + ResponseMessage + ErrorDescription + RRN + AuthKey
```

### 6.3 Golden test (Fase 0)

Datos del archivo `Ejemplo Calculo Hash SALE.TXT`:

| Campo | Valor |
|---|---|
| MerchantId | `39038540035` |
| MerchantName | `Prueba AZUL` |
| MerchantType | `ECommerce` |
| CurrencyCode | `$` |
| OrderNumber | `001` |
| Amount | `10000` |
| ITBIS | `000` |
| ApprovedUrl | `https://google.com` |
| DeclinedUrl | `https://google.com` |
| CancelUrl | `https://google.com` |
| UseCustomField1 | `0` |
| CustomField1Label | (vacío) |
| CustomField1Value | (vacío) |
| UseCustomField2 | `0` |
| CustomField2Label | (vacío) |
| CustomField2Value | (vacío) |
| AuthKey | `asdhakjshdkjasdasmndajksdkjaskldga8odya9d8yoasyd98asdyaisdhoaisyd0a8sydoashd8oasydoiahdpiashd09ayusidhaos8dy0a8dya08syd0a8ssdsax` |

**Hash esperado (hex lowercase):**
```
6662f1e52260cf845a848845e6769ece7ef173c2809ea215f1fc8907442a21f3
95bdfbb8422eb4d6ce8673eb6961beb730d97842e8030668516beba717ffff5b
```

**Verificación ya realizada en Python (UTF-8, HMAC-SHA512):** ✅ coincide byte-exacto.

### 6.4 Pseudocódigo

```typescript
function computeAuthHash(fields: OrderedFields, authKey: string): string {
  const concat = fields.values.join('');  // sin separadores
  const message = concat + authKey;       // AuthKey al final
  const hmac = createHmac('sha512', authKey);
  hmac.update(message, 'utf8');
  return hmac.digest('hex').toLowerCase();
}
```

**Nota técnica:** una sutileza de HMAC es que el "key" del HMAC y el "AuthKey" concatenado al mensaje son el **mismo string** en este algoritmo de Azul. Es decir, la AuthKey actúa simultáneamente como (a) clave del HMAC y (b) última parte del mensaje. Esto se ve claramente en el ejemplo PHP del archivo:

```php
return hash_hmac('sha512', $hash, $authKey);
// donde $hash ya incluye .$authKey al final
```

Esto es inusual pero es el algoritmo de Azul. Lo respetamos.

## 7. Contratos de Edge Functions

Todas las Edge Functions viven en `supabase/functions/`. Usan Deno y TypeScript. Comparten un módulo `_shared/azul.ts` para hash, request building, y validación.

### 7.1 `azul-create-tokenization-session`

**Propósito:** crear una sesión de Payment Page para tokenizar (y verificar via Hold+Void) una tarjeta nueva.

**Endpoint:** `POST /functions/v1/azul-create-tokenization-session`

**Auth:** JWT del usuario del business (no service_role). El usuario debe ser admin del business.

**Request:**
```json
{
  "business_id": "uuid",
  "return_to": "https://mangopos.do/onboarding/payment-success",  // opcional, default a página estándar
  "client_surface": "web" | "flutter_app"
}
```

**Response (200):**
```json
{
  "session_id": "uuid",
  "order_number": "mp_tok_xxx",
  "payment_page_url": "https://<edge_function_host>/azul-payment-form/<session_id>",
  "expires_at": "2026-05-25T13:30:00Z"
}
```

**Lógica:**
1. Validar que el usuario es admin del `business_id`.
2. Generar `OrderNumber` único: `mp_tok_${base32(crypto.randomUUID())}`.
3. Construir los campos del form Hold de RD$1 (Amount=100, ITBIS=000, SaveToDataVault=1, TrxType=Hold).
4. Calcular AuthHash.
5. INSERT en `azul_payment_sessions` con `status='pending'` y `intent_type='tokenize_and_verify'`.
6. Devolver URL pública firmada que sirve el form HTML auto-submit.

**Errores:**
- 403 si el usuario no es admin del business.
- 409 si el business ya tiene una sesión `pending` no expirada (evita duplicados).
- 500 con detalle si falla la generación del hash.

### 7.2 `azul-payment-form/<session_id>`

**Propósito:** servir el HTML auto-submit que postea al Payment Page de Azul.

**Endpoint:** `GET /functions/v1/azul-payment-form?session_id=<uuid>`

**Auth:** ninguna (es público por diseño — el cliente lo abre en browser sin login). La seguridad la da el `session_id` UUID v4 (suficiente entropía) y el `expires_at`.

**Lógica:**
1. SELECT la sesión por id. Si no existe, expirada, o ya `status!='pending'`, devolver 410 Gone con página de error.
2. Marcar `status='redirected'` y `redirected_at=now()`.
3. Devolver HTML:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Redirigiendo a Azul...</title></head>
<body onload="document.forms[0].submit()">
  <p>Redirigiendo a la pasarela de pagos segura...</p>
  <form action="https://pruebas.azul.com.do/PaymentPage/" method="post">
    <input type="hidden" name="MerchantId" value="39038540035">
    <input type="hidden" name="MerchantName" value="MangoPOS">
    <input type="hidden" name="MerchantType" value="ECommerce">
    <input type="hidden" name="TrxType" value="Hold">
    <input type="hidden" name="CurrencyCode" value="$">
    <input type="hidden" name="OrderNumber" value="...">
    <input type="hidden" name="Amount" value="100">
    <input type="hidden" name="ITBIS" value="000">
    <input type="hidden" name="ApprovedUrl" value="https://<edge>/azul-callback?status=approved">
    <input type="hidden" name="DeclinedUrl" value="https://<edge>/azul-callback?status=declined">
    <input type="hidden" name="CancelUrl" value="https://<edge>/azul-callback?status=cancelled">
    <input type="hidden" name="UseCustomField1" value="1">
    <input type="hidden" name="CustomField1Label" value="Verificación de tarjeta">
    <input type="hidden" name="CustomField1Value" value="RD$1.00 será reembolsado automáticamente">
    <input type="hidden" name="UseCustomField2" value="0">
    <input type="hidden" name="CustomField2Label" value="">
    <input type="hidden" name="CustomField2Value" value="">
    <input type="hidden" name="SaveToDataVault" value="1">
    <input type="hidden" name="AuthHash" value="...">
    <noscript><button type="submit">Continuar</button></noscript>
  </form>
</body>
</html>
```

**Notas:**
- Auto-submit con `onload`, fallback `<noscript>` para edge cases.
- `CustomField1` se usa para que el tarjetahabiente vea claramente en la página de Azul el propósito del RD$1.
- ApprovedUrl/DeclinedUrl/CancelUrl todos van al mismo handler con query param `status` distinto. Esto simplifica el routing.

### 7.3 `azul-callback`

**Propósito:** recibir el redirect de Azul (Approved/Declined/Cancel) y procesar.

**Endpoint:** `GET /functions/v1/azul-callback?status=<status>&<azul_params>`

**Auth:** ninguna. La autenticidad la da la validación del `AuthHash` recibido en query.

**Lógica:**

```
1. Log RAW del request en azul_webhook_events (siempre, antes de cualquier validación).
2. Si status === 'cancelled':
     - SELECT session por OrderNumber.
     - UPDATE status='cancelled'.
     - Redirigir cliente a `${return_to}?result=cancelled`.
     - END.
3. Si status in ('approved', 'declined'):
     a. SELECT session por OrderNumber recibido en query.
     b. Si no existe → 404, log como tampered.
     c. Si session.status != 'redirected' (ya procesada) → callback_count++, redirigir
        cliente al estado actual final. NO reprocesar.
     d. Validar AuthHash recibido:
        - Reconstruir cadena: OrderNumber + Amount + AuthorizationCode + DateTime
          + ResponseCode + ISOCode + ResponseMessage + ErrorDescription + RRN + AuthKey
        - Calcular HMAC-SHA512.
        - Comparar con AuthHash recibido (constant-time).
        - Si no coincide → UPDATE status='tampered', log, redirect a página de error,
          alertar admins. END.
     e. Si AuthHash válido:
        - UPDATE session con todos los campos de respuesta (azul_order_id, auth_code, etc.)
        - Si status === 'approved':
            i.  INSERT en azul_payment_methods con el DataVaultToken recibido,
                status='verified', is_default=true (y unset cualquier otro is_default).
            ii. Disparar (fire-and-forget con retry) azul-void-hold con el AzulOrderId.
            iii. UPDATE session.status='approved' y resulting_payment_method_id.
            iv. Si esta es la primera tarjeta verificada del business, crear/actualizar
                azul_subscription_state según el plan elegido (billing_status='trial',
                trial_ends_at=now()+14d, next_billing_date=trial_ends_at+1d).
            v.  Redirigir cliente a `${return_to}?result=approved`.
        - Si status === 'declined':
            i.  UPDATE session.status='declined'.
            ii. Redirigir cliente a `${return_to}?result=declined&reason=${response_message}`.
4. UPDATE webhook_event.processed=true.
```

**Notas críticas:**
- El log a `azul_webhook_events` es **lo primero**, antes de cualquier validación. Sirve como bitácora aunque el procesamiento falle.
- La comparación del AuthHash es **constant-time** para evitar timing attacks (en TypeScript: comparar arrays byte por byte sin early-exit).
- Si llega un callback con `OrderNumber` que ya tiene `status='approved'`, **no se reprocesa**. Solo se loguea y se redirige. Esto previene doble tokenización si Azul reintenta el redirect.

### 7.4 `azul-void-hold`

**Propósito:** ejecutar el Void del Hold de RD$1 inmediatamente después de tokenizar.

**Endpoint:** `POST /functions/v1/azul-void-hold` (interno, invocado solo por `azul-callback`)

**Auth:** service_role bearer.

**Request:**
```json
{
  "session_id": "uuid",
  "azul_order_id": "12345"
}
```

**Lógica:**
1. Construir POST a Payment Page con `TrxType=Void`, `AzulOrderID` del Hold original, mismos campos del Hold original, AuthHash recalculado.
2. Ejecutar el POST server-to-server (NO browser).
3. Loguear resultado en `azul_webhook_events` (event_type='webservice_response').
4. UPDATE session.

**Nota importante:** el doc dice que para Void de Hold no hay restricción de tiempo (a diferencia de Sale/Post que es 20 min). Aún así, este job debe ejecutarse en segundos, no en horas. Si por algún motivo falla, hay un job de retención que reintenta cada 5 min hasta éxito o hasta 24h, después alerta a admin para Void manual desde portal Azul.

**Edge case:** el doc de Payment Page describe Void en el contexto de Payment Page (con redirect). Aquí lo necesitamos sin redirect, server-to-server. **Esto requiere verificación con Azul** — es posible que necesitemos hacer el Void vía Web Services en vez de Payment Page. Item de la lista de "Solicitudes a Azul" (sección 12).

### 7.5 `azul-charge-subscription`

**Propósito:** cobrar la mensualidad de una suscripción específica vía Web Service DataVault.

**Endpoint:** `POST /functions/v1/azul-charge-subscription`

**Auth:** service_role bearer (invocado por cron o manualmente).

**Request:**
```json
{
  "subscription_id": "uuid",
  "attempt_number": 1 | 2 | 3,
  "billing_period_start": "2026-06-01"
}
```

**Lógica:**
```
1. SELECT subscription + business + plan + default payment method.
2. Validar que payment_method.status === 'verified'.
3. Calcular monto: plan.price_cents +/- ajustes de prorrateo si los hay
   (consultar tabla pendiente de diseño en Fase 4).
4. Generar order_number: mp_chg_${subscription_id}_${YYYYMM}_${attempt_number}.
5. INSERT azul_charges con status='pending'.
6. Construir request al WS DataVault de Azul:
   - DataVaultToken, Amount, ITBIS, OrderNumber, etc.
   - AuthHash con orden de campos del WS (PENDIENTE - requiere doc).
7. POST server-to-server.
8. Parsear respuesta.
9. Validar AuthHash de respuesta (si aplica al WS).
10. UPDATE azul_charges con resultado.
11. Si approved:
    - UPDATE azul_subscription_state.last_successful_charge_id, billing_status='active',
      next_billing_date = today + 1 mes, current_attempt_number=0.
    - Disparar generación de PDF + email (Fase 5).
12. Si declined:
    - UPDATE azul_subscription_state.last_failed_charge_id, billing_status='past_due',
      current_attempt_number = attempt_number.
    - Si attempt_number < 3: schedule next attempt (cron lo recoge en día 3 o 7).
    - Si attempt_number === 3: UPDATE billing_status='suspended', suspended_at=now().
13. Retornar resultado.
```

**Bloqueo:** esta función no puede implementarse hasta tener el doc del WS DataVault.

### 7.6 `azul-ipn-handler` (placeholder)

**Propósito:** recibir webhooks server-to-server de Azul (cuando Azul lo habilite).

**Endpoint:** `POST /functions/v1/azul-ipn-handler`

**Auth:** ninguna; autenticidad vía AuthHash + (opcionalmente) IP allowlist de Azul.

**Lógica (cuando se habilite):**
1. Log raw en `azul_webhook_events`.
2. Validar AuthHash.
3. Reconciliar con `azul_payment_sessions` o `azul_charges` según el evento.
4. Si discrepa con el estado actual (ej. callback dijo declined pero IPN dice approved), **IPN gana** y se corrige el estado, alertando a admin.

**Estado en este PRD:** stub que solo loguea. Implementación completa en PRD posterior.


## 8. Flujos completos paso a paso

### 8.1 Flujo A — Onboarding de un comercio nuevo

```
[Cliente]                   [MangoPOS Web]            [Supabase Edge Fn]      [Azul Payment Page]
   │                              │                          │                       │
   │  Visita mangopos.do/signup   │                          │                       │
   ├─────────────────────────────►│                          │                       │
   │  Completa form + elige plan  │                          │                       │
   ├─────────────────────────────►│                          │                       │
   │                              │  Crea business + sub     │                       │
   │                              │  (status=trial sin pago) │                       │
   │                              ├─────────► supabase ◄─────┤                       │
   │                              │                          │                       │
   │                              │  POST                    │                       │
   │                              │  azul-create-tokenization│                       │
   │                              ├─────────────────────────►│                       │
   │                              │                          │ INSERT session        │
   │                              │                          │ status=pending        │
   │                              │  { payment_page_url }    │                       │
   │                              │◄─────────────────────────┤                       │
   │  Redirect a payment_page_url │                          │                       │
   │◄─────────────────────────────┤                          │                       │
   │  GET /azul-payment-form/:id  │                          │                       │
   ├─────────────────────────────────────────────────────────►│                       │
   │                              │                          │ UPDATE                │
   │                              │                          │ status=redirected     │
   │  HTML auto-submit a Azul     │                          │                       │
   │◄─────────────────────────────────────────────────────────┤                       │
   │  POST tarjeta + Hold $1                                                          │
   ├──────────────────────────────────────────────────────────────────────────────────►│
   │                              │                          │           [Azul procesa Hold]
   │                              │                          │           [Marca/Visa/AMEX autorizan]
   │                              │                          │           [SaveToDataVault genera token]
   │  GET /azul-callback?status=approved&...&AuthHash=...                              │
   │◄──────────────────────────────────────────────────────────────────────────────────┤
   │                              │  Browser sigue redirect  │                       │
   │  GET /azul-callback          │                          │                       │
   ├─────────────────────────────────────────────────────────►│                       │
   │                              │                          │  INSERT webhook_event │
   │                              │                          │  Validate AuthHash ✓  │
   │                              │                          │  INSERT payment_method│
   │                              │                          │  status=verified      │
   │                              │                          │  Trigger void-hold ──►│
   │                              │                          │                       │ POST Void
   │                              │                          │                       ├────►Azul WS
   │                              │                          │                       │◄────OK
   │                              │                          │  UPDATE sub_state     │
   │                              │                          │  billing_status=trial │
   │                              │                          │  trial_ends_at=+14d   │
   │  302 → mangopos.do/onboarding/success                                            │
   │◄─────────────────────────────────────────────────────────┤                       │
   │  Página: "¡Bienvenido! Tu trial termina el 8 de junio." │                       │
```

**Tiempo total esperado:** 30 segundos a 2 minutos (depende de qué tan rápido digite el cliente la tarjeta y si hay 3D Secure).

### 8.2 Flujo B — Cobro mensual exitoso

```
[pg_cron]                  [Edge Fn azul-charge-subscription]    [Azul WS DataVault]
   │                              │                                      │
   │  Trigger: 02:00 AM diario    │                                      │
   ├─►│                                                                  │
       │  SELECT subs WHERE next_billing_date <= today                   │
       │       AND billing_status IN ('active', 'past_due')              │
       │       AND attempt_number_due_today                              │
       │  Para cada una:                                                 │
       │                                                                 │
       │  POST azul-charge-subscription                                  │
       │  { subscription_id, attempt_number: 1 }                         │
       │     │                                                           │
       │     │  INSERT azul_charges status=pending                       │
       │     │  POST WS DataVault con token + monto + AuthHash           │
       │     ├──────────────────────────────────────────────────────────►│
       │     │                                                           │  [Azul cobra]
       │     │  Response: approved + auth_code + RRN                     │
       │     │◄──────────────────────────────────────────────────────────┤
       │     │  Validate response AuthHash ✓                             │
       │     │  UPDATE azul_charges status=approved                      │
       │     │  UPDATE azul_subscription_state:                          │
       │     │     last_successful_charge_id = charge.id                 │
       │     │     billing_status = 'active'                             │
       │     │     next_billing_date = today + 1 month                   │
       │     │     current_attempt_number = 0                            │
       │     │  Trigger PDF generation + email send                      │
       │     └─►(PDF + email)                                            │
```

### 8.3 Flujo C — Cobro mensual con declinaciones y suspensión

```
Día 1 (next_billing_date):
   pg_cron → azul-charge-subscription(attempt=1)
   Azul WS → declined (response_code != ISO8583 / 00)
   UPDATE azul_subscription_state:
     billing_status = 'past_due'
     current_attempt_number = 1
     last_failed_charge_id = charge.id
   next_billing_date NO se modifica
   Email al comercio: "Cobro declinado, reintentaremos el [día 3]"

Día 3 (next_billing_date + 2):
   pg_cron busca past_due con last_attempt hace >= 2 días
   azul-charge-subscription(attempt=2)
   Azul WS → declined
   UPDATE: current_attempt_number = 2
   Email: "Segundo intento declinado, reintentaremos el [día 7]"

Día 7 (next_billing_date + 6):
   pg_cron busca past_due con attempt=2 hace >= 4 días
   azul-charge-subscription(attempt=3)
   Azul WS → declined
   UPDATE azul_subscription_state:
     billing_status = 'suspended'
     suspended_at = now()
     current_attempt_number = 3
   Email: "Tu suscripción ha sido suspendida. Actualiza tu método de pago para reactivar."
   Trigger: app Flutter muestra pantalla bloqueo + link a Settings → Billing
```

**Recuperación (no automática):** una vez el comercio actualiza tarjeta o resuelve el problema, el flujo de "reactivar" se cubre en la sección 8.6.

### 8.4 Flujo D — Cambio de tarjeta desde Settings → Billing (app Flutter)

```
[App Flutter]                [Edge Fn]                    [Azul Payment Page]
   │                              │                              │
   │  Usuario: Settings→Billing→  │                              │
   │  "Cambiar tarjeta"           │                              │
   │  POST azul-create-tokeniza...│                              │
   │  { intent_type: 'replace_card', surface: 'flutter_app' }    │
   ├─────────────────────────────►│                              │
   │                              │  INSERT session              │
   │  { payment_page_url }        │                              │
   │◄─────────────────────────────┤                              │
   │  Abre WebView con URL        │                              │
   │  (in-app browser, NO         │                              │
   │  navegador externo, para     │                              │
   │  poder detectar el callback) │                              │
   │  WebView: GET /azul-payment-form/:id                        │
   ├──────────────────────────────────────────────────────────────►│
   │  Form se auto-submit → Azul                                  │
   │  Cliente digita nueva tarjeta                                │
   │  Azul → callback                                             │
   │◄──────────────────────────────────────────────────────────────┤
   │  WebView detecta navegación a /azul-callback                 │
   │  App lee result del query param                              │
   │  (paralelo: backend procesa callback igual que en Flujo A)   │
   │  App cierra WebView                                          │
   │  Realtime listener en azul_payment_methods                   │
   │    detecta nuevo método verified → UI se actualiza           │
   │                                                              │
   │  Backend: el método anterior NO se elimina automáticamente,  │
   │  se marca como no-default. El cliente puede ver histórico.   │
```

**Detalle clave:** **nunca eliminamos el método anterior hasta confirmar que el nuevo es válido.** Si algo falla en mitad del flujo, el cliente sigue teniendo su tarjeta funcional.

### 8.5 Flujo E — Trial → primera cobranza

```
Día 0 (signup):
   Flujo A completo. azul_subscription_state.billing_status='trial',
   trial_ends_at = signup + 14 days. next_billing_date = trial_ends_at + 1 day.

Día 12 (-2 al fin del trial):
   Email automático: "Tu trial termina en 2 días. El [fecha] se cobrará RD$X."

Día 14 (fin del trial):
   Email: "Tu trial termina hoy. Mañana procesaremos el primer cobro."

Día 15 (primer cobro):
   pg_cron → azul-charge-subscription(attempt=1)
   Si approved: UPDATE billing_status='active'.
   Si declined: entra en Flujo C.
```

### 8.6 Flujo F — Reactivación post-suspensión

```
Cliente suspendido entra a la app:
   La app detecta billing_status='suspended' y muestra modal bloqueante:
     "Tu suscripción está suspendida. Actualiza tu método de pago."
   Único botón: "Actualizar tarjeta" → lanza Flujo D.

Cuando el nuevo método se verifica:
   Backend automáticamente ejecuta un cobro de reactivación inmediato:
     azul-charge-subscription(attempt=1, billing_period_start=último período fallido)
   Si approved:
     UPDATE billing_status='active'
     next_billing_date = today + 1 month
     UPDATE current_attempt_number = 0
     Email: "Reactivado exitosamente"
   Si declined nuevamente:
     Vuelve a Flujo C desde attempt=1 (NO continúa la cuenta anterior de intentos).
```

### 8.7 Flujo G — Cambio de plan con prorrateo

```
Día N del mes actual (M días en el mes, P_A precio plan actual, P_B precio plan nuevo):
   Cliente cambia de plan A → plan B en la app.

Cálculo:
   días_restantes = M - N + 1
   crédito_no_usado_A = P_A * días_restantes / M  (lo que sobra del cobro actual)
   cargo_prorrateado_B = P_B * días_restantes / M (lo que corresponde de B en este período)
   ajuste = cargo_prorrateado_B - crédito_no_usado_A
   
   Si ajuste > 0 (upgrade): cobrar `ajuste` inmediatamente vía DataVault.
   Si ajuste < 0 (downgrade): registrar crédito a aplicar en próximo cobro.
   Si ajuste == 0: no cobrar nada, solo actualizar el plan.
   
   En cualquier caso, próximo next_billing_date sigue siendo el mismo (no se reinicia el ciclo).
   El plan en `subscriptions` se actualiza al nuevo.

Tabla nueva opcional (azul_plan_adjustments):
   - subscription_id, applied_to_charge_id, type ('credit'|'debit'), amount_cents, reason.
   - Se aplica en el próximo cobro mensual al calcular el monto a cobrar.
```

**Edge case:** si el cliente cambia de plan varias veces en el mismo período, los ajustes se acumulan en `azul_plan_adjustments` y se liquidan todos en el próximo cobro. Esto evita cobros múltiples al cliente y simplifica la conciliación.

## 9. Manejo de errores y casos borde

| Caso | Estrategia |
|---|---|
| **Browser cerrado antes del redirect** | La sesión queda en `redirected`. Job de mantenimiento marca como `timeout` después de 30 min. Si Azul realmente procesó la transacción, se descubrirá vía IPN (cuando esté habilitado) o reconciliación manual. Por ahora, alertar a admin si una sesión cae en `timeout`. |
| **Doble callback de Azul** (cliente recarga la página) | Idempotencia: el segundo callback con mismo OrderNumber y status ya procesado no reprocesa, solo incrementa `callback_count` y redirige al cliente al estado final. |
| **AuthHash de respuesta inválido** | UPDATE status='tampered', log a webhook_events con flag, no se procesa ningún side effect (no se inserta payment_method, no se procesa subscription), alerta a admin. Cliente ve página de error genérica sin detalles. |
| **Cron corre dos veces el mismo día** (caída + reintento) | El UNIQUE `(subscription_id, billing_period_start, attempt_number)` en `azul_charges` evita doble cobro a nivel DB. El segundo intento de INSERT falla con constraint violation, y la Edge Function lo trata como "ya procesado". |
| **Web Service de Azul timeout** | Retry con backoff exponencial: 1s, 3s, 10s, 30s. Después de 4 intentos sin respuesta, marcar charge como `error` (NO declined) y alertar a admin. Los charges en `error` no cuentan para el conteo de attempts y deben revisarse manualmente. |
| **Token DataVault expirado** | Azul devolverá error específico. Marcar payment_method.status='expired', enviar email al comercio pidiendo actualizar, NO contar como attempt fallido (es problema de método, no de fondos). |
| **Cliente cancela suscripción mid-month** | UPDATE billing_status='cancelled', cancelled_at=now(). NO se hace refund automático del período en curso (el cliente disfruta hasta el final del período pagado). El acceso se mantiene hasta `next_billing_date`. |
| **Cliente cambia de método de pago durante reintentos** | El nuevo método pasa a ser default. El próximo intento del cron usa el nuevo. El conteo de attempts NO se reinicia (la suspensión sigue su curso si los reintentos restantes también fallan). Excepción: si el comercio cambia tarjeta voluntariamente, mostramos prompt opcional "¿Reintentar cobro ahora?" que sí reinicia el ciclo. |
| **Race condition: dos browsers del mismo usuario inician sesión simultáneamente** | El INSERT de session no tiene constraint que prevenga esto. Por diseño: ambas sesiones son válidas hasta que una llegue al callback. La que llegue primero gana; la otra recibe un error en su callback ("ya procesada") y se redirige al estado final. |
| **Azul cambia el formato del response sin avisar** | Validación estricta de campos esperados en el parser. Si faltan campos, marcar session como `error` y alertar. Tener un test contract de respuestas para detectar el cambio rápido. |
| **AuthKey rotada por Azul** | Procedimiento manual: actualizar `SUPABASE_SECRET_AZUL_AUTH_KEY`, las sesiones en flight con la key vieja fallarán al validar. Documentar en runbook. |

## 10. Seguridad

### 10.1 Manejo de secretos

| Secret | Storage | Quién lo lee |
|---|---|---|
| `AZUL_AUTH_KEY` | Supabase Edge Function secrets | Solo Edge Functions vía `Deno.env` |
| `AZUL_MERCHANT_ID` | Supabase Edge Function secrets (config) | Solo Edge Functions |
| `AZUL_PAYMENT_PAGE_URL` | Hardcoded por ambiente (test/prod) en una config | Edge Functions |
| Supabase service_role key | Supabase secrets | Solo Edge Functions (nunca cliente) |

**Prohibido:**
- AuthKey en código fuente, repos, logs, mensajes de error visibles al cliente.
- AuthKey en variables de entorno de la app Flutter o de la web.
- Service role key en cualquier lugar que no sea Supabase Edge Functions.

### 10.2 Validación de origen del callback

Por ahora, la única validación es el AuthHash. Esto es suficiente porque cualquier callback que llegue con AuthHash inválido se rechaza.

**Cuando Azul provea IPN**, agregar IP allowlist como segunda capa.

### 10.3 Rate limiting

- `azul-create-tokenization-session`: max 5 por usuario por hora.
- `azul-callback`: sin rate limit (es público, Azul puede reintentar).
- `azul-charge-subscription`: solo invocable con service_role; sin rate limit.

### 10.4 Auditoría

- `azul_webhook_events` es append-only por convención.
- Toda interacción con Azul queda registrada con request + response + AuthHash + IP + timestamp.
- Logs de Edge Functions se mantienen 30 días en Supabase (estándar).
- En producción se evaluará exportar a un sink permanente (S3) para retención >30 días.

### 10.5 PCI scope

**Lo que NO tocamos en ningún momento:**
- PAN (Primary Account Number / número de tarjeta completo)
- CVV / CVC
- Track data
- PIN

Todo eso vive solo en el entorno de Azul (Payment Page). MangoPOS solo maneja:
- DataVaultToken (no es PAN, no es PCI scope)
- card_number_masked (solo últimos 4)
- data_vault_brand
- data_vault_expiration

Por lo tanto, **MangoPOS está fuera del scope PCI-DSS** para esta integración. Esto es importante mantenerlo: cualquier futuro feature que toque PAN debe pasar por revisión específica.

### 10.6 RLS y service_role

- Edge Functions usan service_role solo cuando es estrictamente necesario (insertar en tablas restringidas).
- Para SELECT que el usuario tiene derecho a ver (sus propios charges), usan el JWT del usuario y dejan que RLS filtre.
- Nunca el cliente recibe service_role.


## 11. Plan de fases con definiciones de hecho

Cada fase es una unidad de trabajo cerrable. **Ninguna fase puede iniciar antes de cerrar todas sus dependencias.** Cada fase tiene un criterio binario de "hecho" (sí/no, sin grises).

### Fase 0 — Golden test del AuthHash (Dart puro)

**Objetivo:** validar que nuestra implementación del HMAC-SHA512 produce el hash exacto del ejemplo de Azul.

**Trabajo:**
1. Crear paquete `mangopos_azul` en el monorepo Flutter (o subfolder en el proyecto principal).
2. Implementar `AzulHashService` que recibe campos ordenados + AuthKey y devuelve el hash.
3. Test golden con los datos exactos del archivo TXT.
4. Test variantes: campos vacíos al inicio/medio/fin, caracteres especiales (acentos, $, &), AuthKey con caracteres especiales.

**Bloquea:** todo lo demás.

**No bloqueado por:** nada. Se puede arrancar inmediatamente.

**Definición de hecho:**
- ✅ Test passes: hash producido === `6662f1e5...ffff5b`.
- ✅ Mínimo 5 tests adicionales con variantes pasan.
- ✅ Documentado en README del paquete cómo se usa.
- ✅ El paquete no tiene dependencias externas más allá de `package:crypto`.

**Estimación:** 2-3 horas.

### Fase 1 — Solicitudes a Azul (no bloqueante para F0/F2/F3)

**Trabajo:** enviar email a oficial de negocios de Azul solicitando:

1. Confirmar si hay opción de **zero-dollar auth** (Account Verification sin reserva de fondos). Si existe, switchear de Hold+Void a esto en F3.
2. Habilitar **IPN (Instant Payment Notification)** sobre el MID de pruebas. Solicitar URL del webhook + formato.
3. **Documento técnico de Web Services Bóveda de Datos** (cobros server-to-server con token).
4. Confirmar si **Void de transacción Hold** se puede hacer vía Web Service o solo vía Payment Page (afecta F3).
5. Tarjetas de prueba específicas para forzar declinación, expirada, fondos insuficientes, error técnico (para tests de F4).

**Definición de hecho:**
- ✅ Email enviado.
- ✅ Respuesta recibida con todos los items, O alternativas identificadas si Azul no provee algo.

**Estimación:** 30 min envío + 1-7 días esperando respuesta de Azul.

### Fase 2 — Esquema de base de datos

**Trabajo:**
1. Migración Supabase con todas las tablas de sección 5.
2. RLS policies.
3. Vistas públicas.
4. Tests SQL: insertar/leer/violación de constraints/RLS deniega correctamente.
5. Seed data para tests de integración.

**No bloqueado por:** F0 (puede ir en paralelo).
**Bloqueado por:** ninguna.

**Definición de hecho:**
- ✅ Migración aplicada en ambiente de desarrollo de Supabase self-hosted (Coolify).
- ✅ Tests SQL pasan: cada tabla acepta inserts válidos y rechaza inválidos.
- ✅ RLS tests: usuario A no puede leer datos de business B.
- ✅ `gen_random_uuid()` funciona (extensión pgcrypto habilitada).

**Estimación:** 4-6 horas.

### Fase 3 — Edge Functions de tokenización + verificación

**Trabajo:**
1. Implementar módulo compartido `_shared/azul.ts` (hash, request builders, validators).
2. Implementar `azul-create-tokenization-session`.
3. Implementar `azul-payment-form` (HTML server).
4. Implementar `azul-callback`.
5. Implementar `azul-void-hold`.
6. Tests E2E: crear sesión → simular submit → callback approved → verificar payment_method creado + Void ejecutado.
7. Test con cada una de las 6 tarjetas de prueba de Azul.

**Bloqueado por:** F0 (golden test debe pasar), F2 (esquema debe existir), F1 (saber si Void de Hold es WS o PP).

**Definición de hecho:**
- ✅ Flujo completo de tokenización funciona contra `pruebas.azul.com.do` con cada tarjeta.
- ✅ payment_method.status='verified' después de Hold+Void.
- ✅ Hold queda voided en el portal de Azul (verificación manual la primera vez).
- ✅ Callback con AuthHash inválido marca session='tampered' y no crea payment_method.
- ✅ Doble callback no causa side effects duplicados.
- ✅ Logs limpios en azul_webhook_events.

**Estimación:** 12-16 horas.

### Fase 4 — Edge Function de cobro recurrente

**Trabajo:**
1. Implementar `azul-charge-subscription` con el WS DataVault.
2. Tabla `azul_plan_adjustments` para prorrateo.
3. Lógica de cálculo de monto a cobrar (precio plan + ajustes).
4. Lógica de cambio de plan con prorrateo.
5. Tests con tarjetas que aprueban y declinan.

**Bloqueado por:** F1 (doc WS DataVault), F3 (tokens funcionando).

**Definición de hecho:**
- ✅ Función invocable manualmente cobra correctamente.
- ✅ Charge approved actualiza azul_subscription_state correctamente.
- ✅ Charge declined NO incrementa attempts solo, está OK; el cron es quien decide cuándo reintentar.
- ✅ Idempotencia: invocar dos veces con mismos parámetros no duplica el cobro.
- ✅ Prorrateo: upgrade cobra ajuste inmediato, downgrade registra crédito.

**Estimación:** 16-20 horas (depende del doc del WS).

### Fase 5 — UI

**Sub-fase 5.1 — Web checkout en signup (mangopos.do)**

**Trabajo:**
1. Página de registro: form business + selección de plan + checkbox de autorización de cobro recurrente.
2. Submit → crea business + subscription + invoca `azul-create-tokenization-session` → redirect.
3. Páginas de retorno: success / declined / cancelled.
4. Email de bienvenida con info del trial.

**Definición de hecho:**
- ✅ Flujo completo desde landing hasta dashboard funcional.
- ✅ Comercio queda con `billing_status='trial'`, payment_method verified.
- ✅ Checkbox de autorización es required y se registra en `subscriptions.consent_granted_at`.

**Estimación:** 12-16 horas.

**Sub-fase 5.2 — App Flutter Settings → Billing**

**Trabajo:**
1. Pantalla "Mi suscripción": plan actual, próximo cobro, historial de cobros (de `azul_charges_public`).
2. Botón "Cambiar plan" con prorrateo preview.
3. Pantalla "Método de pago": muestra tarjeta default (masked + brand), botón "Cambiar tarjeta".
4. Botón abre WebView interno con el `payment_page_url`, detecta navigation a callback, cierra y refresca.
5. Pantalla "Histórico": lista de charges con link a PDF de comprobante.
6. Pantalla de bloqueo cuando `billing_status='suspended'`.

**Definición de hecho:**
- ✅ Todo lo anterior funciona en Android, iOS y Windows.
- ✅ Cambio de tarjeta funciona end-to-end.
- ✅ Pantalla de bloqueo se activa correctamente y no permite usar otras pantallas.

**Estimación:** 20-24 horas.

### Fase 6 — Automatización con pg_cron

**Trabajo:**
1. Habilitar extensión pg_cron en Supabase.
2. Job diario 02:00 AM: busca subscriptions a cobrar hoy, invoca Edge Function por cada una.
3. Job diario 03:00 AM: maintenance — marca sessions huérfanas como timeout, alerta charges en error.
4. Job diario 09:00 AM: envía recordatorios de trial ending.
5. Sistema de notificaciones email (Resend o similar).

**Bloqueado por:** F4.

**Definición de hecho:**
- ✅ Cron ejecuta diariamente sin intervención.
- ✅ Subscription con `next_billing_date=today` se cobra.
- ✅ Reintentos en días 1, 3, 7 funcionan según política.
- ✅ Suspensión automática al fallar attempt 3.
- ✅ Emails llegan correctamente.

**Estimación:** 10-14 horas.

### Fase 7 — IPN handler (cuando Azul lo habilite)

**Trabajo:**
1. Implementar `azul-ipn-handler` completo.
2. Lógica de reconciliación: IPN gana sobre callback en caso de discrepancia.
3. Documentar runbook para discrepancias detectadas.

**Bloqueado por:** F1 (Azul debe habilitar IPN).

**Definición de hecho:**
- ✅ IPN recibido se procesa correctamente.
- ✅ Discrepancia: si callback dijo X y IPN dice Y, IPN gana y se loguea alerta.

**Estimación:** 6-10 horas.

### Fase 8 — Comprobantes PDF + emails

**Trabajo:**
1. Template PDF con info del cobro (logo MangoPOS, datos comercio, plan, monto, fecha, método de pago, número de orden, RNC si aplica).
2. Generación vía Edge Function (usar `pdf-lib` o similar deno-compatible).
3. Storage en Supabase Storage bucket `azul-receipts` con RLS.
4. Email transaccional con PDF adjunto.
5. Pantalla en app Flutter para descargar receipt histórico.

**Bloqueado por:** F4.

**Definición de hecho:**
- ✅ Cobro exitoso genera PDF correcto.
- ✅ PDF llega por email en <60 segundos del cobro.
- ✅ PDF descargable desde la app.

**Estimación:** 10-14 horas.

### Fase 9 — Migración del piloto (cambio de Stripe → Azul)

**Trabajo:**
1. Para cada comercio existente con Stripe: enviar email "Estamos migrando a Azul, por favor ingresa tu tarjeta nuevamente".
2. UI especial de migración en la app.
3. Tras tokenización exitosa, cancelar subscription en Stripe.
4. Reconciliación: validar que ningún comercio queda sin método de pago activo.

**Bloqueado por:** F4, F6 (cobro automatizado funcionando).

**Definición de hecho:**
- ✅ Todos los comercios pilotos migrados.
- ✅ Stripe queda como "dormido" (subscriptions canceladas pero cuenta no cerrada por si hay disputas).
- ✅ Ningún cobro duplicado durante la transición (Stripe sigue cobrando hasta cancelación efectiva).

**Estimación:** depende del número de comercios; 1-2 horas por comercio + soporte.

## 12. Plan de pruebas

### 12.1 Tests unitarios

| Componente | Tests |
|---|---|
| `AzulHashService` (Dart) | Golden test del ejemplo + 10 variantes de campos. |
| `_shared/azul.ts` (Deno) | Mismo golden + variantes en TypeScript. |
| Cálculo de prorrateo | Casos: upgrade mid-month, downgrade mid-month, mismo precio, último día del mes, mes 28 días, año bisiesto. |
| Constructor de form HTML | Snapshot tests del HTML generado para que cualquier cambio sea explícito. |

### 12.2 Tests de integración (contra `pruebas.azul.com.do`)

**Matriz de tarjetas de prueba:**

| # | Tarjeta | Esperado |
|---|---|---|
| 1 | `4035874000424977` | Approved (Visa) |
| 2 | `5426064000424979` | Approved (Mastercard) |
| 3 | `4012000033330026` | Approved (Visa) |
| 4 | `5424180279791732` | Approved (Mastercard) |
| 5 | `6011000990099818` | Approved (Discover) |
| 6 | `4260550061845872` | Approved (Visa) |

Solicitar a Azul tarjetas adicionales para escenarios:
- Declinada por fondos insuficientes.
- Expirada.
- 3D Secure required.
- Error técnico del banco emisor.

**Escenarios E2E:**
1. Tokenización exitosa → payment_method.status='verified', Void ejecutado.
2. Cliente cancela en Azul → session.status='cancelled'.
3. AuthHash de respuesta inválido (simulado modificando query) → session.status='tampered'.
4. Doble callback → segundo no causa side effects.
5. Cobro mensual exitoso (cuando WS DataVault esté disponible).
6. Cobro declinado → reintentos en días 1, 3, 7 → suspensión.
7. Cambio de tarjeta a mitad de suspensión → reactivación.
8. Cambio de plan: upgrade Basic→Pro mid-month, downgrade Pro→Basic mid-month.

### 12.3 Tests de carga (no prioritarios para v1)

- Simular 1000 charges concurrentes a través del cron. Validar idempotencia y orden correcto.
- Para el piloto actual no es prioritario, pero documentado para cuando crezca.

## 13. Solicitudes a Azul (checklist)

Email a oficial de negocios — checklist de items a confirmar:

- [ ] **Habilitar DataVault** sobre el MID `39038540035` de pruebas.
- [ ] **Habilitar IPN** sobre el MID de pruebas + URL del webhook + documentación del formato.
- [ ] **Documento de Web Services DataVault** (cobros server-to-server con token).
- [ ] Confirmar si **zero-dollar auth** está disponible (alternativa al Hold de RD$1).
- [ ] Confirmar mecanismo de **Void sobre Hold**: ¿vía Payment Page o vía Web Service?
- [ ] **Tarjetas de prueba adicionales**: declinada por fondos, expirada, 3DS, error.
- [ ] **Documentación de errores**: catálogo de ResponseCode/IsoCode/ResponseMessage posibles.
- [ ] Política de **reintentos del lado de Azul**: ¿reintentan el callback si nuestro endpoint cae?
- [ ] **SLA y soporte**: contacto de emergencia 24/7, ventana de mantenimiento de Azul.
- [ ] Cuando se acerque go-live: **MID de producción + AuthKey de producción**, separados del de pruebas.

## 14. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| **Azul demora en proveer doc WS DataVault** | Media | Alto (bloquea F4) | F0-F3 ya cubren tokenización y verificación, valor parcial entregable. Email a Azul desde día 1. |
| **AuthHash formula del WS DataVault es diferente al de Payment Page** | Media | Medio | Aislar el cálculo de hash en módulo separado con parámetros (qué campos en qué orden). Adaptarlo cuando el doc llegue. |
| **Browser cierra antes del callback** | Alta | Medio | Job de timeout en F6, IPN como fuente de verdad eventual en F7. Por ahora aceptamos pérdida potencial de información de sesiones nunca confirmadas. |
| **Cliente disputa cargo (chargeback)** | Baja | Alto | Consent checkbox en signup con timestamp guardado. PDFs de comprobante archivados. Términos de servicio en mangopos.do que cubran el cobro recurrente. |
| **Migración de Stripe genera doble cobro temporal** | Media | Medio | Comunicación clara con clientes, ventana de gracia, monitoreo manual durante la transición. |
| **AuthKey filtrada** | Baja | Crítico | Rotación inmediata + audit de transacciones del período comprometido. Documentar procedimiento en runbook. |
| **Tarjeta del comercio expira durante uso** | Alta | Bajo | El campo `data_vault_expiration` permite detectar tarjetas próximas a expirar (job mensual: notificar 30 días antes). |
| **Falsos positivos de tampered (AuthKey mal configurada)** | Media en setup | Alto | Validar AuthKey en startup de Edge Function con un hash conocido. Si no coincide, fallar fast con alerta. |
| **Cron no corre por mantenimiento de Supabase** | Baja | Medio | Monitoreo: si no hubo cobros un día calendario hábil, alerta. Job manualmente reinvocable. |
| **Cambio de algoritmo de Azul sin aviso** | Baja | Alto | Tests E2E corren diariamente contra pruebas.azul.com.do. Detección rápida. |

## 15. Apéndices

### A. Referencias

- Documento técnico de Azul Payment Page (PDF compartido por el oficial, octubre 2024).
- Archivo `Ejemplo Calculo Hash SALE.TXT` (golden test source).
- Doc PHP de Azul (hash de respuesta — pág. 9 del PDF).

### B. URLs de ambiente

| Ambiente | Payment Page URL |
|---|---|
| Pruebas | `https://pruebas.azul.com.do/PaymentPage/` |
| Producción principal | `https://pagos.azul.com.do/PaymentPage/Default.aspx` |
| Producción contingencia | `https://contpagos.azul.com.do/PaymentPage/Default.aspx` |

**Importante:** en producción, MangoPOS debe tener lógica de failover: si el POST a `pagos.azul.com.do` falla, intentar con `contpagos.azul.com.do`. El doc lo exige.

### C. Tarjetas de prueba

(Las 6 tarjetas provistas por Azul, números completos concatenados)

```
1. 4035 8740 0042 4977   Exp 202812   CVV 977
2. 5426 0640 0042 4979   Exp 202812   CVV 979
3. 4012 0000 3333 0026   Exp 202812   CVV 123
4. 5424 1802 7979 1732   Exp 202812   CVV 732
5. 6011 0009 9009 9818   Exp 202812   CVV 818
6. 4260 5500 6184 5872   Exp 202812   CVV 872
```

### D. Variables de entorno (Edge Functions)

```
AZUL_ENV=test                                   # test | production
AZUL_MERCHANT_ID=39038540035
AZUL_AUTH_KEY=<secret>                          # supabase secret
AZUL_PAYMENT_PAGE_URL=https://pruebas.azul.com.do/PaymentPage/
AZUL_MERCHANT_NAME=MangoPOS
AZUL_MERCHANT_TYPE=ECommerce
AZUL_CURRENCY_CODE=$
SUPABASE_URL=<self-hosted>
SUPABASE_SERVICE_ROLE_KEY=<secret>
PUBLIC_CALLBACK_BASE_URL=https://<edge_functions_host>
PUBLIC_RETURN_BASE_URL=https://mangopos.do
```

### E. Glosario

- **MID**: Merchant ID, identificador único del comercio en Azul.
- **AuthKey**: clave secreta entregada por Azul, usada para HMAC-SHA512.
- **AuthHash**: el hash HMAC-SHA512 calculado, viaja en el form.
- **DataVault**: servicio de Azul que tokeniza tarjetas para uso futuro.
- **DataVaultToken**: el token alfanumérico que representa una tarjeta tokenizada.
- **TrxType**: tipo de transacción (Sale, Hold, Post, Void, Create, Delete).
- **Hold**: pre-autorización (reserva fondos pero no cobra).
- **Post**: completar una pre-autorización (cobrar el monto reservado).
- **Void**: anular una transacción.
- **IPN**: Instant Payment Notification — webhook server-to-server de Azul.
- **RRN**: Reference Referral Number, número único de la transacción en el procesador.
- **3D Secure**: protocolo de autenticación adicional del tarjetahabiente.
- **DCC**: Dynamic Currency Conversion (no usamos en v1).
- **Prorrateo**: cálculo proporcional al tiempo restante del período.

### F. Cambios respecto a estado actual

Tablas existentes que NO se modifican en este PRD (solo se leen):
- `businesses`
- `subscriptions`
- `plans` (si existe)
- `users`

Si se requiere agregar columnas a tablas existentes (ej. `subscriptions.consent_granted_at`), esto se hace en un PRD separado de "modificaciones complementarias" para mantener el strangler fig limpio.

---

**Fin del PRD.**
