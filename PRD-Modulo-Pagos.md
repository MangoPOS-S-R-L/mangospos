# PRD — Módulo de Pagos (Suscripciones SaaS) · Contrato POS ↔ Dashboard

**Versión:** 1.0 — 2026-06-17
**Audiencia:** equipo del Dashboard administrativo (`mangopos_administrador`).
**Autor de referencia técnica:** equipo POS (`mangospos`).
**Documentos internos relacionados (detalle de implementación):**
- `PRD-Azul-Subscriptions.md` — diseño completo del motor de cobro (1330 líneas).
- `PRD-Azul-3DSecure.md` — flujo 3D Secure 2.0.
- `PRD-Mango-Administrador-Clientes.md` — PRD del dashboard.

> **Por qué existe este documento.** El POS y el Dashboard **comparten una sola base de datos Supabase**. El módulo de pago (suscripciones SaaS vía Azul) vive en el POS, pero el Dashboard **asigna planes** y **consulta el estado de cobro** de cada comercio. Si los dos sistemas no respetan el mismo contrato de datos, pasan cosas como la detectada el 2026-06-17: un plan asignado en el Dashboard aparecía como **"Sin plan asignado"** en el POS. Este PRD define ese contrato.

---

## 1. Resumen del módulo

MangoPOS cobra la mensualidad de cada comercio contra una **tarjeta tokenizada** vía **Azul** (procesador local RD), reemplazando el cobro manual / Stripe. Hay dos caminos independientes:

- **Camino A — Registro de tarjeta (Azul Payment Page).** Form **hospedado por Azul** (el PAN nunca toca MangoPOS → **PCI SAQ A**). Con 3DS habilitado en el MID, Azul corre la autenticación en su página. Resultado: un **DataVault token** guardado en `azul_payment_methods`.
- **Camino B — Cobro recurrente (Web Services mTLS, MIT).** Cargo mensual con el token vía `ProcessPayment Sale` (`merchantInitiatedIndicator=STANDING_ORDER`, `ForceNo3DS=1`), disparado por `pg_cron`. La llamada mTLS sale por un **sidecar** (`azul-proxy`), no por las Edge Functions.

**Estado de producción (2026-06-17):**
- Camino A: **en producción y probado** (MID `39648910001`, endpoint `pagos.azul.com.do`, tarjeta real aprobada y guardada).
- Camino B: **esperando el certificado mTLS de producción** de Azul (CSR ya enviado). Sin el cert, el cobro recurrente no se ejecuta.

---

## 2. Arquitectura (alto nivel)

```
  ┌─────────────┐        ┌─────────────────────────┐
  │  POS app    │        │  Dashboard admin         │
  │ (mangospos) │        │ (mangopos_administrador) │
  └──────┬──────┘        └────────────┬─────────────┘
         │  asigna plan (plan_type)   │  consulta estado
         ▼            vía RPC         ▼
  ┌───────────────────────────────────────────────────┐
  │            Supabase (BD compartida)                │
  │  plans · plan_catalog · memberships · azul_*       │
  └───────┬───────────────────────────────┬───────────┘
          │ Edge Functions (azul-*)        │ pg_cron (diario)
          ▼                                ▼
   azul-callback / azul-charge-subscription / ...
          │  POST /call (token compartido)
          ▼
   ┌──────────────┐  mTLS (cert + Auth1/Auth2)
   │  azul-proxy  │ ─────────────────────────────►  Azul (pagos.azul.com.do)
   └──────────────┘
```

- **Payment Page (registro):** `azul-create-tokenization-session` → `azul-payment-form` (HTML auto-submit a Azul) → el navegador del cliente paga en Azul → `azul-callback` valida el hash, inserta la tarjeta y hace Void del Hold de RD$1.
- **Cobro recurrente:** `pg_cron` (07:00 UTC) → `fn_azul_run_due_charges()` → POST a `azul-charge-subscription` → sidecar mTLS → Azul.
- **PCI SAQ A:** MangoPOS nunca recibe el PAN. Solo guarda el `data_vault_token` (opaco).
- **Sidecar mTLS:** el Edge Runtime de Supabase no soporta mTLS; el `azul-proxy` (Node.js, misma red Docker) sostiene el cert + `Auth1/Auth2` y hace el handshake.

---

## 3. Modelo de datos compartido

Tablas que **ambos** sistemas tocan o leen. (Esquema completo en `PRD-Azul-Subscriptions.md §5` y migración `20260526_0002_azul_subscriptions_schema.sql`.)

### 3.1 `plans` — catálogo de planes del **POS**
| Columna | Tipo | Significado |
|---|---|---|
| `id` | uuid | PK. **Es lo que referencia `memberships.plan_id`.** |
| `code` | text único | Código máquina: `basic`, `pro`, `enterprise`, `starter`, `trial`, `free`. |
| `name` | text | Nombre visible (live: "Básico"/"Pro"/"Enterprise"…). |
| `price_cents_monthly` | int | **Precio en centavos DOP. El cobro recurrente usa este valor.** |
| `is_active` | bool | Si se ofrece como plan seleccionable. |
| `features` | jsonb | Lista de features para la UI. |

### 3.2 `plan_catalog` — catálogo de planes del **Dashboard**
| Columna | Tipo | Significado |
|---|---|---|
| `code` | text PK | Mismo universo de códigos que `plans.code`. |
| `name` | text | Nombre visible en el Dashboard. |
| `price_monthly` | numeric | Precio en **pesos** (no centavos). |
| `is_active` | bool | Visibilidad en el Dashboard. |

> ⚠️ **Hay DOS catálogos para lo mismo.** `plans` (POS) y `plan_catalog` (Dashboard). El contrato exige mantenerlos alineados (ver §4.3).

### 3.3 `memberships` — fila ancla = estado de billing
Cada comercio tiene **exactamente una** fila con `is_billing_anchor = true` (índice único parcial). Esa fila carga el estado de cobro.

| Columna | Quién la escribe | Significado |
|---|---|---|
| `plan_id` (uuid→plans) | **POS** (motor/trigger) | **Plan que lee el POS.** Fuente que muestra la pantalla de suscripción. |
| `plan_type` (text) | **Dashboard** (RPC) | Código del plan (legacy). **Es lo que el Dashboard escribe al asignar plan.** |
| `is_billing_anchor` | POS (onboarding) | Marca la única fila de billing del comercio. |
| `billing_status` | **POS (motor)** | `trial \| active \| past_due \| suspended \| cancelled`. |
| `trial_ends_at` | POS | Fin del período de prueba. |
| `next_billing_date` | POS (motor) | Fecha del próximo cargo (el cron la usa). |
| `current_attempt_number` | POS (motor) | Reintento actual (0–3). |
| `consent_granted_at` | POS (onboarding) | Consentimiento de cobro recurrente. |
| `last_successful_charge_id` / `last_failed_charge_id` | POS (motor) | Último cargo OK / fallido. |

### 3.4 Tablas propias del POS (el Dashboard solo lee para reportería)
- `azul_payment_methods` — tarjetas tokenizadas (`data_vault_token`, marca, últimos 4, `is_default`, `status`). **El token nunca se expone**; usar la vista `azul_payment_methods_public`.
- `azul_charges` — intentos de cobro y su resultado. Reportería vía `azul_charges_public`.
- `azul_payment_sessions` — sesiones de tokenización (Payment Page).
- `azul_webhook_events` — bitácora append-only de callbacks (forense).

---

## 4. EL CONTRATO Dashboard ↔ POS  *(núcleo de este PRD)*

### 4.1 Asignación de plan — cómo funciona hoy
- **El Dashboard** asigna/cambia el plan de un comercio con el RPC `update_business_membership`, que escribe **solo `memberships.plan_type`** (texto), `status` y `end_date`. **No toca `plan_id`.**
- **El POS** muestra el plan leyendo **`memberships.plan_id`** (uuid → `plans`) de la fila `is_billing_anchor=true`. Si `plan_id` es NULL → muestra **"Sin plan asignado"**.
- **El puente:** trigger `fn_sync_membership_plan_id` (migración `20260617_0002`) hace de `plan_type` la **fuente de verdad** y deriva `plan_id` automáticamente (`plan_id = plans.id WHERE code = plan_type`). Así, lo que el Dashboard escribe en `plan_type` aparece correctamente en el POS.

```
Dashboard  ──escribe──►  memberships.plan_type ──trigger──►  memberships.plan_id  ──lee──►  POS
                          (código texto)        sync          (uuid → plans)
```

### 4.2 Reglas que el Dashboard DEBE respetar

| # | Regla | Por qué |
|---|---|---|
| **R1** | Escribir el plan en la fila **`is_billing_anchor = true`** del comercio. | Hoy `update_business_membership` actualiza "la membership más reciente" (`created_at DESC`), que **puede no ser la fila ancla**. Si difieren, el POS (que lee la ancla) no verá el cambio. **→ Fix requerido en el RPC.** |
| **R2** | Usar **solo códigos que existan en ambos catálogos** (`plans.code` y `plan_catalog.code`). | Un código presente solo en `plan_catalog` (ej. `starter`) no resuelve a un `plan_id` → el POS muestra "Sin plan". |
| **R3** | **No** escribir ni mutar `plan_id`, `billing_status`, `next_billing_date`, `current_attempt_number`, `trial_ends_at`, `suspended_at`. | Esas columnas las maneja el **motor de cobro del POS**. Tocarlas desde el Dashboard rompe el ciclo de cobro/reintentos. |
| **R4** | Si el Dashboard ofrece "cancelar"/"suspender", hacerlo vía un RPC acordado que respete la máquina de estados (§5), no con UPDATE directo. | Mantener una sola autoridad sobre las transiciones de billing. |

### 4.3 Sincronización de catálogos (`plan_catalog` ↔ `plans`)

Estado verificado el 2026-06-17:

| code | `plan_catalog` (Dashboard) | `plans` (POS) | Acción |
|---|---|---|---|
| `basic` | "Básico" — 2999.99 | "Básico" — *(precio a verificar)* | precio a reconciliar |
| `pro` | "Pro" — 4799.99 | "Pro" — *(verificar)* | precio a reconciliar |
| `enterprise` | "Enterprise" — 7799.99 | "Enterprise" — *(verificar)* | precio a reconciliar |
| `starter` | "Starter" — 0 (inactivo) | *(faltaba; lo agrega mig. 20260617_0002)* | OK tras migración |
| `trial` | "Trial" — 0 | *(lo agrega la migración)* | OK tras migración |
| `free` | "Free" — 0 (inactivo) | *(lo agrega la migración)* | OK tras migración |

**Reglas de catálogo:**
- **C1.** Todo `code` usado en `plan_catalog` debe existir en `plans` (mismo `code`). Cualquier plan nuevo se crea en **ambas** tablas.
- **C2.** Los **nombres** ya coinciden; mantenerlos así para que POS y Dashboard muestren lo mismo.
- **C3.** **Los precios deben coincidir:** `plans.price_cents_monthly = round(plan_catalog.price_monthly × 100)`. **El cobro recurrente usa `plans.price_cents_monthly`** — si está en placeholder, se cobraría el monto equivocado. **Reconciliar antes de encender el Camino B.**

---

## 5. Ciclo de vida de billing (máquina de estados)

`billing_status` en la fila ancla. **Las transiciones las hace el motor del POS** (`azul-charge-subscription`); el Dashboard las **muestra**, no las muta directamente.

| Estado | Significado | Transición | Disparador |
|---|---|---|---|
| `trial` | Período de prueba activo. | → `active` (1er cargo OK) | Onboarding. |
| `active` | Cobros al día. | → `past_due` (cargo declinado) · → `cancelled` | Cargo aprobado. |
| `past_due` | Cargo declinado, reintento programado. | → `active` (reintento OK) · → `suspended` (3ra declinación) | Cargo declinado, intento < 3. |
| `suspended` | Cobro deshabilitado; el `BillingGuard` bloquea el POS. | → `active` (pago/reset) · → `cancelled` | 3ra declinación. |
| `cancelled` | Suscripción terminada (terminal). | — | Cancelación. |

> El **`BillingGuard`** del POS (`lib/presentation/billing/widgets/billing_guard.dart`) hoy está **desactivado** (`_kEnabled = false`) hasta el go-live del cobro. Cuando se active, bloquea el shell a comercios `suspended` y a `trial` sin tarjeta verificada.

---

## 6. Motor de cobro recurrente (referencia)

- **Cron:** `pg_cron` diario **07:00 UTC** (~3am AST) → `private.fn_azul_run_due_charges()` (mig. `20260609_0001`).
- **Elegibilidad de un comercio para ser cobrado:** `is_billing_anchor=true` **y** `plan_id IS NOT NULL` **y** `billing_status IN ('active','past_due')` **y** `next_billing_date <= hoy` **y** tarjeta default `verified`.
- **Cargo:** `azul-charge-subscription` → `ProcessPayment Sale` MIT (`STANDING_ORDER` + `ForceNo3DS=1`), monto = `plans.price_cents_monthly`.
- **Reintentos:** declinación intento 1 → `next_billing_date = hoy+2`; intento 2 → `hoy+4`; intento 3 → `suspended`.
- **Idempotencia:** `UNIQUE(membership_id, billing_period_start, attempt_number)` en `azul_charges` + `OrderNumber` determinista `MP{8hex}{YY}{MM}{intento}` (15 chars).
- **Config del cron:** `private.azul_cron_config` (`functions_base_url`, `service_role_key`) — sin RLS, solo `security definer`.

---

## 7. Seguridad y PCI

- **PCI SAQ A:** captura de tarjeta en la Payment Page hospedada por Azul; MangoPOS solo guarda el token.
- **mTLS:** el cert + `Auth1/Auth2` viven solo en el `azul-proxy`. Las Edge Functions hablan con el sidecar por token compartido (`AZUL_PROXY_AUTH_TOKEN`).
- **RLS:** `azul_*` son service_role para escritura; los comercios solo leen lo suyo (`user_has_business_access`). El `data_vault_token` **no** se expone (usar vistas `*_public`).
- **Credenciales:** todas en variables de entorno (Coolify / Docker), nunca en el repo.

---

## 8. Estado de producción (2026-06-17)

| Pieza | Estado |
|---|---|
| Payment Page (registro) en prod | ✅ Live y probado (MID `39648910001`). |
| Cobro recurrente (mTLS) | ⏳ Esperando cert de producción de Azul (CSR enviado). |
| Trigger puente `plan_id ← plan_type` (mig. `20260617_0002`) | ⏳ Escrita, **pendiente de aplicar**. |
| Reconciliación de precios `plans` ↔ `plan_catalog` | ⏳ Pendiente (antes del Camino B). |
| `BillingGuard` | ⛔ Desactivado (`_kEnabled=false`) hasta go-live. |
| `private.azul_cron_config` + cron activo | ⏳ Pendiente (parte del Camino B). |

---

## 9. Acciones requeridas del lado del Dashboard (checklist)

- [ ] **R1 — RPC `update_business_membership`:** escribir el plan en la fila `is_billing_anchor=true` (no en "la más reciente").
- [ ] **C1/C2 — Catálogos:** garantizar que todo `code`/nombre de `plan_catalog` exista igual en `plans`; cualquier plan nuevo se crea en ambas tablas.
- [ ] **C3 — Precios:** reconciliar `plans.price_cents_monthly = plan_catalog.price_monthly × 100`.
- [ ] **R3 — No mutar** columnas del motor (`plan_id`, `billing_status`, `next_billing_date`, `current_attempt_number`, `trial_ends_at`).
- [ ] **Reportería:** leer estado de cobro desde la fila ancla y las vistas `azul_charges_public` / `azul_payment_methods_public` (nunca el token).
- [ ] **R4 — Cancelar/suspender** (si aplica) vía RPC acordado, respetando la máquina de estados.

---

## 10. Inconsistencias conocidas / riesgos

1. **Doble catálogo** (`plans` vs `plan_catalog`) — fuente recurrente de divergencia (códigos y precios). *Mitigación:* reglas C1–C3; a futuro, evaluar unificar en un solo catálogo.
2. **`update_business_membership` apunta a "la membership más reciente"** — puede no ser la fila ancla → el POS no ve el cambio (R1).
3. **`plan_type` mezcla "plan" y "estado"** (`trial`/`starter` son códigos legacy). El trigger los resuelve a un `plan_id` con nombre; el período de prueba real se refleja en `billing_status`, no en `plan_type`.
4. **Precios placeholder en `plans`** podrían cobrar montos incorrectos cuando se encienda el Camino B (C3).

---

## 11. Referencias

- `PRD-Azul-Subscriptions.md` — diseño completo del motor (modelo de datos, AuthHash, contratos de Edge Functions, flujos, fases).
- `PRD-Azul-3DSecure.md` — 3D Secure 2.0.
- `PRD-Mango-Administrador-Clientes.md` — PRD del Dashboard.
- Migraciones: `20260526_0002_azul_subscriptions_schema.sql` (esquema), `20260609_0001_azul_charge_subscription_cron.sql` (cron), `20260617_0002_sync_membership_plan_id.sql` (puente plan_id).
