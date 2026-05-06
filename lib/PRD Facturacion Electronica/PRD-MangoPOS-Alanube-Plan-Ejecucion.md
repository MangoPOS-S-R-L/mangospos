# PRD de Ejecución — Integración e-CF DGII (Alanube) en MangoPOS

| Campo | Valor |
|---|---|
| Versión | 1.0 |
| Fecha | 2026-05-05 |
| Autor | Cristian / Innovech Software LLC |
| Estado | Draft — listo para ejecución pendiente de cerrar 3 decisiones bloqueantes |
| Documento padre | `PRD-MangoPOS-Alanube-Integration.md` (PRD funcional) |
| Propósito | Plan de ejecución concreto, mapeado al estado real del repo MangoPOS |

> Este documento **no reemplaza** al PRD funcional. Lo complementa con el plan de implementación tras inventariar el código actual. Donde haya conflicto entre los dos, manda este.

---

## 1. Por qué este PRD existe

El PRD funcional asumió un modelo de datos genérico (`sales`, `companies`, tabla `electronic_documents` desde cero). El repo real tiene **infraestructura fiscal NCF físico ya construida** que el plan original ignora. Implementar el PRD funcional al pie de la letra crearía un sistema paralelo que duplica `fiscal_documents`, `ncf_sequences`, y `generate_ncf()` — y rompería el flujo de cobro actual.

Este PRD ajusta el plan para **extender** la infraestructura existente en vez de duplicarla.

---

## 2. Hechos del repo (cambian el plan)

### 2.1 Lo que ya existe y vamos a reusar

| Componente | Ubicación | Qué hace hoy |
|---|---|---|
| Tabla `orders` | `schema.sql:2701` | Venta principal. PK UUID. **No `sales`.** |
| Tabla `order_items` | `schema.sql:2672` | Líneas con `tax_mode`, `tax_rate`, `is_takeout`. |
| Tabla `businesses` | `schema.sql:2255` | Empresa. **No `companies`.** Con `business_name`, `address`, `phone`. |
| Tabla `user_businesses` | `schema.sql:3247` | Asociación usuario↔empresa con `role` y `permissions[]`. |
| Tabla `fiscal_documents` | `schema.sql:519` | **Ya tiene** `ncf_type` enum (incluye E31/E32/E33/E34/E44/E45), `ecf_status` (pending/sent/accepted/rejected), `customer_rnc`, `itbis_amount`, `status` (active/cancelled/modified). |
| Tabla `ncf_sequences` | `schema.sql:2946` | Rangos por `business_id`+`ncf_type` con `current_number`, `range_start/end`. |
| Función `generate_ncf(_business_id, _ncf_type)` | [migration 20260426_0001:211-272](supabase/migrations/20260426_0001_fix_ncf_collisions_and_trigger_idempotency.sql#L211) | Genera NCF secuencial idempotente con resincronización contra colisiones. |
| Función `issue_fiscal_document(_order_id, _payment_id)` | [migration 20260426_0001:274-455](supabase/migrations/20260426_0001_fix_ncf_collisions_and_trigger_idempotency.sql#L274) | **Crea fila en `fiscal_documents` post-pago.** Resuelve `ncf_type` desde `fiscal_settings.default_ncf_type` o `payments.requested_ncf_type`. |
| Función `fn_process_payment_v3` | [migration 20260426_0001:27-209](supabase/migrations/20260426_0001_fix_ncf_collisions_and_trigger_idempotency.sql#L27) | RPC de pago. Acepta `p_requested_ncf_type`. |
| `BusinessResolver.ensure()` | [lib/core/business/business_resolver.dart:16](lib/core/business/business_resolver.dart#L16) | Resuelve `business_id` actual del usuario. |
| `TaxEngine.calculateItemTax()` / `aggregateOrderTax()` | [lib/core/tax/tax_engine.dart](lib/core/tax/tax_engine.dart) | Fuente de verdad para subtotal/ITBIS. **El payload Alanube se construye desde acá.** |
| RLS helper `user_has_business_access(uid, business_id)` | función SQL existente | Política estándar; lo nuevo debe usarla. |
| `closeOrderPaid()` | [lib/presentation/sales/viewmodel/sales_viewmodel.dart:1721](lib/presentation/sales/viewmodel/sales_viewmodel.dart#L1721) | Punto de cierre de venta. **No se toca**: el gancho de emisión va a nivel SQL post-pago. |
| Pantalla fiscal existente | [lib/presentation/settings/.../fiscal/](lib/presentation/settings/more%20settings/system%20settings/fiscal/view/fiscal_receipts_view.dart) | UI base para extender — no creamos pantalla nueva top-level. |
| Modelo `FiscalNcfSequence` | [lib/data/models/fiscal_models.dart](lib/data/models/fiscal_models.dart) | Ya soporta los códigos e-CF; reusar. |

### 2.2 Lo que NO existe (y se necesita)

- `supabase/functions/` no existe. **Edge Functions no están configuradas** (`config.toml` sin sección `[functions]`).
- Extensión `pg_net` no instalada → no se puede hacer HTTP outbound desde Postgres.
- `pg_cron` no instalado → no hay scheduler nativo para retry/reconciliación.
- No hay tabla `webhook_inbox` ni `webhook_outbox`.
- No hay credenciales Alanube en ningún vault del repo.

### 2.3 Implicaciones del PRD funcional que cambian

| PRD funcional dice | Realidad del repo | Decisión nueva |
|---|---|---|
| Crear `electronic_documents` | `fiscal_documents` ya tiene 90% de las columnas | **Extender `fiscal_documents`** con columnas Alanube (alanube_document_id, public_url, pdf_url, xml_url, dgii_track_id, request_payload, response_payload). No crear tabla paralela. |
| Crear `electronic_companies` con RNC, dirección, etc. | Esos datos viven en `businesses` | **Tabla nueva `business_alanube_settings`** SOLO con: `business_id` (FK), `alanube_company_id`, `environment`, `certification_status`, `webhook_secret`, `webhooks_configured`. RNC y demás se leen vía join. |
| FK `sale_id REFERENCES sales(id)` | Tabla es `orders` | Reusar `fiscal_documents.order_id` ya existente. |
| Disparar emisión desde Flutter | El pago ya gatilla `issue_fiscal_document()` en SQL | **Extender `issue_fiscal_document`** para que tras crear la fila, encole emisión Alanube. Flutter no orquesta nada. |
| Edge Functions Deno | No disponibles | Ver decisión D-1 abajo. |

---

## 3. Decisiones bloqueantes (cerrar antes de Fase 0)

### D-1: ¿Cómo hacemos las llamadas HTTP a Alanube?

Tres opciones. **Esta decisión es estrictamente bloqueante** — sin ella no hay Fase 1.

| Opción | Esfuerzo inicial | Mantenimiento | Riesgo |
|---|---|---|---|
| **A. Habilitar Edge Functions en Supabase self-hosted** | Medio (configurar Deno runtime en Coolify) | Bajo | Medio: depende de tu instalación Coolify |
| **B. Servicio Dart sidecar** en contenedor Coolify nuevo | Alto (nuevo deploy, dominio, TLS, secrets) | Medio | Bajo: tecnología que ya dominas |
| **C. Instalar `pg_net` + `pg_cron`** y hacer todo desde Postgres | Bajo (extensiones) | Alto (debugging HTTP en SQL es doloroso) | Alto: poco observable |

**Mi recomendación: Opción A si Coolify lo soporta limpio; si te da fricción en >2h de prueba, Opción B.** Opción C solo si A y B fallan — el debugging y los retries en SQL puro envejecen mal.

**Acción:** spike de 1 día para probar A. Si funciona, A. Si no, B.

### D-2: ¿NCF físico convive con e-CF o se reemplaza?

Hoy `fiscal_documents.ncf_type` admite ambos rangos (`B0x` físicos y `Exx` electrónicos). Hay tres caminos:

- **D-2.a** — Por business: cada negocio elige uno u otro. Migración: campo `business_alanube_settings.mode` ∈ {physical, electronic, hybrid}.
- **D-2.b** — Hybrid permanente: e-CF para clientes B2B con RNC, NCF físico de consumo para resto. Más complejo pero realista en transición DGII.
- **D-2.c** — Reemplazo total: una vez activado e-CF para un business, se desactivan los rangos físicos.

**Mi recomendación: D-2.b durante 2026, evolución a D-2.c cuando DGII obligue a todos.** Esto es lo que ocurre en la realidad de los clientes.

### D-3: ¿Modo offline en MVP?

El PRD funcional lo lista. Mi recomendación es **NO en MVP**:

- DGII permite emitir hasta X horas después del hecho generador → buffer suficiente.
- En offline, `fn_process_payment_v3` no corre (es RPC). El cobro no se puede cerrar hoy sin red.
- Implementar offline robusto añade ~2 semanas y SQLite local.

**Acción:** confirmar que en MVP el cobro requiere red (status quo actual del POS).

---

## 4. Modelo de datos ajustado

### 4.1 Migración nueva: `20260506_0001_alanube_ecf_extension.sql`

```sql
-- Tabla: configuración Alanube por business (delgada, no duplica businesses)
CREATE TABLE business_alanube_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES businesses(id) ON DELETE RESTRICT,
    alanube_company_id TEXT UNIQUE NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
    certification_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (certification_status IN ('pending', 'in_progress', 'certified', 'rejected')),
    mode TEXT NOT NULL DEFAULT 'hybrid'
        CHECK (mode IN ('physical', 'electronic', 'hybrid')),
    webhook_secret TEXT,
    webhooks_configured BOOLEAN DEFAULT FALSE,
    notify_by_email BOOLEAN DEFAULT FALSE,
    logo_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (business_id, environment)
);

-- Extender fiscal_documents existente (NO crear tabla paralela)
ALTER TABLE fiscal_documents
    ADD COLUMN alanube_document_id TEXT UNIQUE,
    ADD COLUMN dgii_track_id TEXT,
    ADD COLUMN public_url TEXT,
    ADD COLUMN xml_url TEXT,
    ADD COLUMN pdf_url TEXT,
    ADD COLUMN request_payload JSONB,
    ADD COLUMN response_payload JSONB,
    ADD COLUMN submitted_at TIMESTAMPTZ,
    ADD COLUMN accepted_at TIMESTAMPTZ,
    ADD COLUMN rejected_at TIMESTAMPTZ,
    ADD COLUMN cancelled_at TIMESTAMPTZ,
    ADD COLUMN cancellation_reason TEXT,
    ADD COLUMN retry_count INTEGER DEFAULT 0,
    ADD COLUMN last_error TEXT,
    ADD COLUMN idempotency_key TEXT;

CREATE UNIQUE INDEX idx_fiscal_docs_idempotency
    ON fiscal_documents(business_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

CREATE INDEX idx_fiscal_docs_pending_emission
    ON fiscal_documents(business_id, ecf_status, created_at)
    WHERE ecf_status IN ('pending', 'sent') AND ncf_type::text LIKE 'E%';

-- Audit log
CREATE TABLE fiscal_document_status_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fiscal_document_id UUID NOT NULL REFERENCES fiscal_documents(id) ON DELETE CASCADE,
    previous_status TEXT,
    new_status TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('api_response', 'webhook', 'manual', 'retry_job')),
    payload JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_fiscal_status_events_doc
    ON fiscal_document_status_events(fiscal_document_id, created_at DESC);

-- Webhooks recibidos
CREATE TABLE alanube_webhook_inbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    headers JSONB,
    signature_valid BOOLEAN,
    processed BOOLEAN DEFAULT FALSE,
    processed_at TIMESTAMPTZ,
    error TEXT,
    received_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_webhook_inbox_unprocessed
    ON alanube_webhook_inbox(processed, received_at)
    WHERE processed = FALSE;

-- RLS reusa el helper existente
ALTER TABLE business_alanube_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY bas_select ON business_alanube_settings
    FOR SELECT USING (user_has_business_access(auth.uid(), business_id));
-- inserts vía service_role solo
```

### 4.2 Cambios a `issue_fiscal_document()`

Tras crear la fila en `fiscal_documents`, si `ncf_type::text LIKE 'E%'` y existe `business_alanube_settings` activo:

1. Generar `idempotency_key` (gen_random_uuid si no viene del payment).
2. Marcar `ecf_status = 'pending'`.
3. **NotifyEmit**: dependiendo de D-1:
   - **Opción A (Edge Functions)**: insert en `pg_listen` o disparo via `pg_notify('alanube_emit', doc_id::text)` que la Edge Function escucha.
   - **Opción B (servicio Dart)**: insert en tabla `emit_outbox`; el servicio Dart hace polling/Realtime.
   - **Opción C (pg_net)**: trigger ejecuta `net.http_post(...)` directo.

---

## 5. Plan de ejecución

### Fase 0 — Spike y decisiones (3-5 días)

- [ ] **D-1**: Spike Edge Functions en tu Coolify. Si pasa, fijar A. Si no, B.
- [ ] **D-2**: Confirmar `mode='hybrid'` como default.
- [ ] **D-3**: Confirmar "MVP requiere red para cobro".
- [ ] Solicitar JWT sandbox a Alanube.
- [ ] Crear branch `feature/ecf-alanube`.
- [ ] Health check: una llamada `GET /company` al sandbox de Alanube desde el stack elegido (A o B).

**Salida**: documento corto con D-1/D-2/D-3 cerradas + sandbox respondiendo OK.

### Fase 1 — Cimientos backend (semana 1)

- [ ] Migración `20260506_0001_alanube_ecf_extension.sql` (sección 4.1).
- [ ] Función SQL `register_alanube_company(payload jsonb) returns jsonb` que llama vía stack elegido.
- [ ] Modificar `issue_fiscal_document()` para añadir el hook NotifyEmit (sección 4.2).
- [ ] Tests SQL: insertar pago con `requested_ncf_type='E32'` y verificar que se crea `fiscal_documents` con `ecf_status='pending'` y se dispara NotifyEmit.

**Salida**: emisión automática de un documento en `fiscal_documents` tras pago, sin enviar aún a Alanube real.

### Fase 2 — Emisión E31/E32 sandbox (semana 2)

- [ ] Implementar emisor (Edge Function o servicio Dart): toma `fiscal_documents.id`, lee orden + items + business + customer, construye payload Alanube, hace `POST /invoice-fiscals`.
- [ ] El payload se construye reusando `TaxEngine.aggregateOrderTax()` — no recalcular impuestos.
- [ ] Persistir respuesta: `alanube_document_id`, `request_payload`, `response_payload`, transición `ecf_status: pending→sent`.
- [ ] Test E2E: cerrar venta en sandbox, verificar que llega a Alanube y se persiste el ID.

**Salida**: una venta E32 emitida exitosamente en sandbox de Alanube.

### Fase 3 — Webhooks y Realtime (semana 3)

- [ ] Endpoint público `/webhooks/alanube` (Edge Function pública o ruta del servicio Dart).
- [ ] Validación HMAC del header `X-Alanube-Signature` con `webhook_secret` de `business_alanube_settings`.
- [ ] Insert en `alanube_webhook_inbox` y respuesta 200 en <3s.
- [ ] Worker async (trigger sobre inbox) que procesa y actualiza `fiscal_documents` (`ecf_status: sent→accepted|rejected`, llena URLs).
- [ ] Realtime subscription en Flutter: `currentOrderProvider` o un nuevo `electronicDocumentProvider(orderId)` escucha cambios en `fiscal_documents`.

**Salida**: estado del documento llega a la UI en tiempo real sin polling.

### Fase 4 — UI Flutter (semana 3-4, paralelo con Fase 3)

- [ ] **Pantalla de venta** ([lib/presentation/sales/view/](lib/presentation/sales/view/)): banner inferior con estado del e-CF (Emitiendo / NCF asignado / Aceptado por DGII). NO bloquea cobro. Patrón Riverpod existente: `Provider<T>` para repo + `NotifierProvider` para viewmodel.
- [ ] **Configuración fiscal** ([lib/presentation/settings/more settings/system settings/fiscal/](lib/presentation/settings/more%20settings/system%20settings/fiscal/)): añadir tab "Alanube" con datos de empresa, certificación, environment switcher, webhook secret. Reusa `fiscal_viewmodel.dart`.
- [ ] **Lista de documentos electrónicos**: nuevo tab dentro de la pantalla fiscal existente con filtros (estado, tipo, fecha, RNC). Acciones por fila: ver PDF, ver XML, URL pública DGII, anular (genera E34).
- [ ] **Selector NCF en cobro**: al cobrar, si business tiene `mode='hybrid'`, dropdown E31/E32 según contexto. Si es E31, requiere RNC del cliente.

**Salida**: cajero puede emitir e-CF y ver estado sin abandonar el flujo de venta.

### Fase 5 — Resiliencia y reportes (semana 4-5)

- [ ] Job retry: cron (pg_cron si está, o cron del servicio Dart) cada 5 min para `ecf_status='sent'` con `submitted_at < now() - 5min` y `retry_count < 5`.
- [ ] Reconciliación diaria: comparar últimos 7 días vs `GET /invoice-fiscals/{id}` de Alanube, detectar drift.
- [ ] Métricas: query SQL para tasa de éxito 1er intento, p95 emisión, docs >24h pendientes.
- [ ] Anulación E34: implementar `cancel_fiscal_document(doc_id, reason)` que crea NC y enlaza al original.

**Salida**: 95% de docs emitidos en <5s, 0 docs huérfanos a 24h, alertas si algo se atasca.

### Fase 6 — Piloto producción (semana 5-6)

- [ ] Onboardear 1 cliente piloto: certificación DGII, ambiente production.
- [ ] Monitor cercano por 2 semanas.
- [ ] Iterar bugs descubiertos antes de abrir a 2-5 clientes más.

**Salida**: cliente piloto facturando real con e-CF en producción.

### Fuera de MVP (Fase 7+)

- Modo offline robusto con SQLite local (`drift`).
- Recepción de documentos de proveedores.
- Aprobación comercial de docs recibidos.
- E33 nota de débito.
- Migración masiva clientes legacy.

---

## 6. Riesgos específicos al repo

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Edge Functions no funcionan en Coolify self-hosted | Media | Alto | Spike de Fase 0 antes de comprometer arquitectura. Plan B servicio Dart listo. |
| Modificar `issue_fiscal_document()` rompe NCF físico actual | Media | Crítico | Tests de regresión sobre emisión NCF físico. Cambios aditivos solamente. |
| `TaxEngine` aggregate no produce el shape exacto que Alanube espera | Alta | Medio | Adaptador en Edge Function/servicio Dart, no tocar TaxEngine. Validar con sandbox temprano. |
| Cliente factura con NCF físico y e-CF a la vez por bug en `mode` switching | Baja | Crítico | Constraint SQL: `mode='electronic'` ⇒ todos los `ncf_sequences` físicos del business `is_active=false`. |
| Webhook llega antes de respuesta sincrónica del POST | Media | Bajo | State machine en SQL: solo permitir transiciones forward (`pending→sent→accepted`); webhook que llegue sobre estado más avanzado se ignora. |
| Volumen Alanube excede tier y dispara facturación inesperada | Media | Medio | Dashboard de uso por business; alerta a 75%. |
| RNC del cliente del cliente mal validado | Alta | Medio | Validación RNC (longitud + checksum DGII) en Flutter antes de habilitar E31. |

---

## 7. Definition of Done por fase

| Fase | Criterio "hecho" |
|---|---|
| 0 | D-1/D-2/D-3 cerradas por escrito; sandbox Alanube responde. |
| 1 | `flutter analyze` limpio; tests SQL de `issue_fiscal_document` pasan; ningún cambio rompe NCF físico. |
| 2 | Una venta E32 sandbox aparece en dashboard de Alanube con `alanube_document_id` persistido. |
| 3 | Webhook de prueba (curl con HMAC) actualiza `fiscal_documents` y la UI lo refleja en <2s vía Realtime. |
| 4 | Cajero completa cobro E31 con RNC en <30s sin abandonar pantalla de venta. |
| 5 | Doc fallado se reintenta y se acepta automáticamente; reporte de salud DGII visible al admin. |
| 6 | Cliente piloto emite ≥50 e-CF en producción con tasa de aceptación DGII ≥95%. |

---

## 8. Cosas que NO vamos a hacer (explícitas)

- **No tocar `TaxEngine`** — su salida alimenta Alanube vía adaptador.
- **No tocar `fn_process_payment_v3`** salvo si añadimos parámetro nuevo. La signatura actual es estable.
- **No crear `electronic_documents`** — extendemos `fiscal_documents`.
- **No crear pantallas top-level nuevas** — todo dentro del módulo fiscal existente y la pantalla de venta.
- **No meter JWT de Alanube en Flutter** bajo ninguna circunstancia.
- **No bloquear `closeOrderPaid()` esperando a Alanube** — la emisión es siempre async post-pago.
- **No hacer SQLite local en MVP** — D-3.

---

## 9. Próximo paso inmediato

Cerrar D-1 con un spike de 1 día. Solo después de eso este plan se mueve.

Comando sugerido para arrancar el spike:

```bash
# Verificar si Coolify expone Functions en tu Supabase
# (consultar dashboard Coolify → Supabase service → environment vars)
# Buscar: SUPABASE_FUNCTIONS_URL o similar

# Si existe carpeta funciones, crearla y deployar hello-world Deno:
mkdir -p supabase/functions/alanube-health
# escribir index.ts que haga GET https://sandbox.alanube.co/dom/v1/health
supabase functions deploy alanube-health --project-ref <self-hosted-ref>
```

Si el spike falla en <2 horas → pivote inmediato a Opción B (servicio Dart).
