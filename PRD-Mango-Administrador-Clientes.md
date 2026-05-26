# PRD — Mango Administrador: Gestión de Clientes (CRM + Billing Ops)

| Campo | Valor |
|---|---|
| **Autor** | Cristian (DRI) |
| **Estado** | Draft v1 — pendiente de aprobación |
| **Fecha** | 2026-05-26 |
| **Ámbito** | Sistema interno (Mango Administrador) para operar la base de comercios pilotos y de producción de MangoPOS |
| **Repo destino** | `mango-administrador` (separado de `mangospos`) — comparte la misma instancia Supabase self-hosted |
| **Dependencias** | PRD-Azul-Subscriptions.md (esquema billing ya implementado en `mangospos`), Alanube (NCF), Resend (email transaccional), Supabase Auth con roles |

---

## 1. Contexto y problema

MangoPOS hoy tiene 25+ comercios activos en pilotaje. La operación día a día se hace mediante:

1. **SQL directo en Supabase Studio** para activar, suspender, ajustar planes, dar prórrogas. Esto es lento, sin audit trail, y propenso a error humano (un `WHERE` mal puesto puede tumbar la operación de varios comercios).
2. **Comunicación manual por WhatsApp/email** para notificar pagos pendientes, cambios de plan, anuncios de mantenimiento.
3. **Facturación NCF (DGII)** hecha caso por caso vía portal Alanube directo, sin trazabilidad de qué cobro corresponde a qué NCF.
4. **Cero visibilidad agregada**: no hay dashboard de MRR, churn, conversión trial→paid, ni alertas tempranas de cuentas en riesgo.
5. **Permisos mezclados**: el único acceso de admin es a través del Studio de Supabase con service_role key, que da poder total e indistinguible entre quien sea que la use.

A medida que la base crece de 25 a 200+ comercios, ninguno de estos métodos escala. Necesitamos un **panel de administración interno** que centralice operación de clientes, billing, facturación, comunicación, métricas y audit.

## 2. Objetivos

1. **Vista 360° de cada cliente**: en una sola pantalla, ver datos del comercio, owner, miembros, plan, billing state, historial de cobros, facturas NCF, comunicaciones enviadas, notas internas, y métricas de uso.
2. **Acciones operativas seguras**: suspender, reactivar, dar prórrogas, cambiar plan, refundar, aplicar créditos — todo con audit log y confirmación explícita.
3. **Facturación NCF integrada**: generar comprobantes fiscales electrónicos desde el panel, vincularlos al cobro Azul correspondiente, enviarlos por email, anular si aplica.
4. **Comunicaciones desde el panel**: enviar emails a uno o muchos clientes (templates + custom), ver historial.
5. **Soporte y CRM básico**: notas internas por cliente, asignación a agente, seguimiento de conversaciones.
6. **Métricas en vivo**: MRR, ARR, churn, conversión trial→paid, LTV, top clientes por uso, alertas de cuentas en riesgo.
7. **Roles y permisos granulares**: separar acceso de owner (full), support (lectura + tickets + emails), billing (cobros, refunds), read-only (analytics).
8. **Audit log inmutable**: toda acción operativa queda registrada con quién, qué, cuándo, sobre qué cliente.
9. **2FA obligatorio para todos los admins** + IP allowlist opcional.

## 3. No-objetivos (v1)

Para acotar scope realista. Estos quedan **fuera** de v1 y se evalúan en v2+:

- ❌ App móvil del admin (todo es web).
- ❌ Multi-idioma (solo español por v1).
- ❌ Multi-moneda (solo DOP).
- ❌ Pricing dinámico / experimentos A/B de precios.
- ❌ Sales pipeline (oportunidades, deals, forecasting) — esto es CRM comercial, no admin de clientes activos.
- ❌ Soporte conversacional embebido (no implementamos chat propio — referenciamos canales externos: WhatsApp Business, email).
- ❌ Integraciones con contabilidad externa (QuickBooks, etc.). Exportación CSV sí.
- ❌ Reportes regulatorios DGII completos (formularios 606/607). Solo NCF individual.
- ❌ Self-service de admin: configuración avanzada (workflows, automations) — todo viene hardcoded por ahora.
- ❌ Workflow approvals para acciones sensibles. Cualquier admin con rol adecuado puede ejecutar.

## 4. Decisiones arquitectónicas clave

| # | Decisión | Justificación |
|---|---|---|
| A1 | **Misma instancia Supabase que `mangospos`**, no DB separada. | Evita ETL/sync. Mango Administrador es un cliente más de la DB con un rol elevado. Si en algún momento crece, se desagrega. |
| A2 | **Autenticación independiente vía tabla `admin_users` + Supabase Auth**. Los admin NO viven en `auth.users` mezclados con comercios. | Aislamiento: un comercio comprometido no escala a admin; admins van por flujo de signup separado. |
| A3 | **Rol Postgres custom `mango_admin`** además del existente `service_role`. RLS de tablas admin restringe a este rol. | `service_role` queda solo para Edge Functions internas. Admins humanos van con `mango_admin` que tiene poderes amplios pero auditables. |
| A4 | **Audit log inmutable en tabla `admin_audit_log`**. Cada UPDATE/INSERT desde el panel pasa por una RPC que registra el log antes de ejecutar. | Sin trigger, sin override desde Studio. Es la única fuente forense de "quién hizo qué". |
| A5 | **Locked price snapshot en `memberships.locked_price_cents_monthly`** al crear suscripción. El cron de cobro usa ese campo, no `plans.price_cents_monthly`. | Cambiar precio del catálogo NO impacta suscripciones existentes hasta que el admin haga "migration" explícita. Protege contra cobros sin consent. |
| A6 | **Prórrogas como tabla aparte `admin_extensions`**, no como columna de memberships. | Mantiene auditoría: cada prórroga tiene quien, cuándo, motivo, días concedidos, expiración. |
| A7 | **NCF / Alanube como bridge table `admin_invoices`** vinculada a `azul_charges`. | 1 charge puede tener 0, 1, o N invoices a lo largo del tiempo (correcciones). Tabla aparte mantiene la integridad de `azul_charges` como auditoría de cobro y separa la dimensión fiscal. |
| A8 | **Emails enviados via Resend** (ya en uso para alanube-webhook). Tabla `admin_email_log` registra cada envío. | Reusa infra. Tracking centralizado de qué se mandó a quién. |
| A9 | **Permisos via tabla `admin_roles` + `admin_user_roles`**, NO solo via JWT claims. | Permite revocación inmediata. JWT claims se hidratan al login desde estas tablas. |
| A10 | **Todas las acciones operativas vía RPC server-side (`security definer`)**, no INSERT/UPDATE directo. | Encapsula validación, audit log, side effects (email, alerta) en una sola transacción. |
| A11 | **Realtime habilitado para `azul_webhook_events`, `azul_charges`, `memberships`** en el panel admin. | Ops en vivo: cuando un cobro falla, aparece en pantalla sin refrescar. |
| A12 | **2FA TOTP obligatorio para todos los admins** vía Supabase Auth MFA. | Mango Administrador es la llave maestra del negocio. Sin 2FA es negligencia. |

## 5. Modelo de datos

### 5.1 Tablas existentes (lectura)

El panel lee directamente:

- `public.businesses` — datos del comercio (nombre, dominio, owner_id, tipo, dirección).
- `public.memberships` — suscripciones (con todas las columnas billing del PRD Azul).
- `public.plans` — catálogo de planes.
- `public.azul_payment_methods` — tarjetas tokenizadas (sin exponer `data_vault_token`).
- `public.azul_payment_sessions` — bitácora de intentos de tokenización.
- `public.azul_charges` — cobros mensuales (lectura completa, incluyendo raw_request/response solo para audit).
- `public.azul_webhook_events` — bitácora forense de Azul.
- `public.user_businesses` — relación user↔business con role.
- `auth.users` — usuarios autenticados (vía RPC, no SELECT directo).
- `public.profiles` — perfiles de usuario (full_name, email, etc.).

### 5.2 Tablas nuevas (admin específicas)

Todas con prefijo `admin_` para señalizar dominio. Owner: `mango_admin`. Schema: `public`.

#### 5.2.1 `admin_users`

Tabla canónica de quién puede usar el panel.

```sql
create table admin_users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete restrict unique,
  email text not null unique,
  full_name text not null,
  status text not null default 'active'
    check (status in ('active', 'disabled', 'invited')),
  totp_enrolled boolean not null default false,
  last_login_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid references admin_users(id),
  disabled_at timestamptz,
  disabled_reason text
);
```

**Notas:**
- Los admins se crean SOLO por invitación de otro admin (no hay signup público).
- `auth_user_id` los une al sistema de auth de Supabase pero permite tener cuentas admin separadas de comercios.
- `disabled` permite revocar acceso sin borrar historia.

#### 5.2.2 `admin_roles` y `admin_user_roles`

Sistema RBAC simple.

```sql
create table admin_roles (
  code text primary key,
  name text not null,
  description text,
  permissions jsonb not null default '[]'::jsonb, -- ej: ["customers.read","billing.refund","invoices.create"]
  created_at timestamptz not null default now()
);

-- Seed inicial
insert into admin_roles (code, name, description, permissions) values
  ('owner', 'Owner', 'Acceso total — modificación de roles, billing, suspensiones, facturación',
   '["*"]'::jsonb),
  ('support', 'Soporte', 'Lectura de clientes, gestión de tickets, envío de emails, NO billing',
   '["customers.read","tickets.write","communications.write","invoices.read"]'::jsonb),
  ('billing', 'Billing', 'Operaciones de cobro: refund, retry, prórrogas, créditos, facturación NCF',
   '["customers.read","billing.*","invoices.*"]'::jsonb),
  ('analyst', 'Analista', 'Solo lectura: métricas, reportes, sin acciones',
   '["customers.read","billing.read","invoices.read","metrics.read"]'::jsonb);

create table admin_user_roles (
  admin_user_id uuid not null references admin_users(id) on delete cascade,
  role_code text not null references admin_roles(code) on delete restrict,
  granted_at timestamptz not null default now(),
  granted_by uuid not null references admin_users(id),
  primary key (admin_user_id, role_code)
);
```

**Permissions string format:**
- `"customers.read"` → lectura de clientes
- `"customers.write"` → edición
- `"billing.refund"` → emitir refunds
- `"billing.*"` → todos los permisos billing
- `"*"` → todos

Una función `admin_has_permission(admin_user_id, permission)` evalúa wildcards.

#### 5.2.3 `admin_audit_log`

Append-only. Toda acción operativa queda registrada.

```sql
create table admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid not null references admin_users(id) on delete restrict,
  action text not null,                    -- ej: 'customer.suspend', 'billing.refund'
  target_type text,                        -- 'business', 'membership', 'charge', 'invoice'
  target_id uuid,                          -- id del objeto afectado
  business_id uuid references businesses(id), -- shortcut para filtrar por cliente
  before_state jsonb,                      -- snapshot antes del cambio
  after_state jsonb,                       -- snapshot después
  metadata jsonb,                          -- contexto adicional (motivo, monto, etc.)
  ip_address inet,
  user_agent text,
  performed_at timestamptz not null default now()
);

create index idx_admin_audit_log_admin on admin_audit_log(admin_user_id, performed_at desc);
create index idx_admin_audit_log_business on admin_audit_log(business_id, performed_at desc);
create index idx_admin_audit_log_action on admin_audit_log(action, performed_at desc);
```

#### 5.2.4 `admin_customer_notes`

CRM básico: notas internas por cliente.

```sql
create table admin_customer_notes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  admin_user_id uuid not null references admin_users(id) on delete restrict,
  category text not null check (category in (
    'general', 'billing_issue', 'feature_request', 'complaint',
    'compliment', 'churn_risk', 'churn_reason', 'sales_followup'
  )),
  body text not null,
  pinned boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_admin_customer_notes_business on admin_customer_notes(business_id, pinned desc, created_at desc);
```

#### 5.2.5 `admin_tickets`

Tickets de soporte (lightweight). No reemplaza un Zendesk; sirve para internal tracking.

```sql
create table admin_tickets (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete restrict,
  ticket_number text not null unique, -- ej: 'TKT-2026-00042'
  subject text not null,
  status text not null default 'open'
    check (status in ('open', 'pending_customer', 'pending_internal', 'resolved', 'closed')),
  priority text not null default 'normal'
    check (priority in ('low', 'normal', 'high', 'urgent')),
  category text not null
    check (category in ('billing', 'technical', 'feature', 'training', 'other')),
  assigned_to uuid references admin_users(id),
  opened_by uuid not null references admin_users(id),
  opened_at timestamptz not null default now(),
  resolved_at timestamptz,
  closed_at timestamptz,
  resolution_summary text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table admin_ticket_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references admin_tickets(id) on delete cascade,
  author_admin_id uuid references admin_users(id), -- null si es del cliente
  is_internal boolean not null default false, -- nota privada vs respuesta al cliente
  body text not null,
  attachments jsonb not null default '[]'::jsonb,
  sent_at timestamptz not null default now()
);
```

#### 5.2.6 `admin_extensions` (prórrogas)

Cada prórroga es una fila inmutable.

```sql
create table admin_extensions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete restrict,
  membership_id uuid not null references memberships(id) on delete restrict,
  granted_by uuid not null references admin_users(id),
  extension_type text not null
    check (extension_type in ('trial_extension', 'payment_grace', 'free_credit')),
  days_granted integer,                 -- para trial_extension/payment_grace
  amount_cents integer,                  -- para free_credit
  currency_code text default 'DOP',
  reason text not null,                  -- requerido — el admin justifica
  customer_facing_message text,          -- mensaje opcional que se envía al comercio
  effective_until timestamptz,           -- la fecha hasta cuando aplica
  expires_at timestamptz,                -- cuándo deja de tener efecto
  granted_at timestamptz not null default now(),
  reverted_at timestamptz,               -- si fue revertida
  reverted_by uuid references admin_users(id),
  reverted_reason text
);

create index idx_admin_extensions_business on admin_extensions(business_id);
create index idx_admin_extensions_active on admin_extensions(business_id)
  where reverted_at is null and effective_until > now();
```

#### 5.2.7 `admin_invoices` (NCF / Alanube)

Bridge entre `azul_charges` y los comprobantes fiscales.

```sql
create table admin_invoices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete restrict,
  charge_id uuid references azul_charges(id) on delete restrict, -- nullable: factura manual sin cobro
  invoice_type text not null
    check (invoice_type in ('credito_fiscal', 'consumidor_final', 'nota_credito', 'nota_debito')),

  -- Datos del comprobante
  ncf text,                              -- emitido por Alanube/DGII
  ncf_secuencia text,                    -- secuencia interna
  amount_subtotal_cents integer not null,
  itbis_cents integer not null default 0,
  amount_total_cents integer not null,
  currency_code text not null default 'DOP',
  customer_rnc text,                     -- RNC del comercio si aplica
  customer_name text not null,           -- razón social

  -- Estado del comprobante
  status text not null default 'draft'
    check (status in ('draft','submitted','accepted','rejected','cancelled')),
  alanube_id text,                       -- id externo de Alanube
  alanube_public_url text,               -- URL pública del comprobante
  alanube_xml_url text,
  alanube_pdf_url text,
  alanube_response jsonb,                -- raw de Alanube para audit
  rejection_reason text,

  -- Tracking
  emitted_by uuid references admin_users(id),
  emitted_at timestamptz,
  sent_to_customer_at timestamptz,
  cancelled_by uuid references admin_users(id),
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index idx_admin_invoices_ncf on admin_invoices(ncf) where ncf is not null;
create index idx_admin_invoices_business on admin_invoices(business_id, created_at desc);
create index idx_admin_invoices_charge on admin_invoices(charge_id) where charge_id is not null;
```

#### 5.2.8 `admin_email_log`

Tracking de todo email enviado desde el panel.

```sql
create table admin_email_log (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references businesses(id) on delete set null,
  sent_by_admin_id uuid references admin_users(id) on delete set null,
  email_to text not null,
  email_cc text[],
  email_bcc text[],
  subject text not null,
  template_code text,                    -- ej: 'trial_ending', 'invoice_sent', 'custom'
  body_html text,
  body_text text,
  attachments jsonb not null default '[]'::jsonb, -- nombres de archivos / signed URLs
  resend_id text,                        -- id devuelto por Resend
  status text not null default 'queued'
    check (status in ('queued','sent','delivered','bounced','complained','failed')),
  status_updated_at timestamptz,
  error_message text,
  sent_at timestamptz default now(),
  created_at timestamptz not null default now()
);

create index idx_admin_email_log_business on admin_email_log(business_id, sent_at desc);
create index idx_admin_email_log_status on admin_email_log(status);
```

#### 5.2.9 `admin_email_templates`

Templates reutilizables. Admin puede editar.

```sql
create table admin_email_templates (
  code text primary key,
  name text not null,
  subject text not null,
  body_html text not null,
  body_text text,
  variables jsonb not null default '[]'::jsonb, -- ej: ["business_name","amount","invoice_url"]
  is_system boolean not null default false, -- system templates no se pueden borrar
  updated_by uuid references admin_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Seed templates iniciales
insert into admin_email_templates (code, name, subject, body_html, variables, is_system) values
  ('trial_ending_3d', 'Trial terminando en 3 días', '...', '...', '["business_name","trial_ends_at","plan_name","amount"]', true),
  ('trial_ending_today', 'Trial termina hoy', '...', '...', '...', true),
  ('payment_failed', 'Cobro declinado', '...', '...', '["business_name","amount","retry_date"]', true),
  ('payment_succeeded', 'Pago recibido', '...', '...', '["business_name","amount","invoice_url"]', true),
  ('subscription_suspended', 'Cuenta suspendida', '...', '...', '...', true),
  ('subscription_reactivated', 'Cuenta reactivada', '...', '...', '...', true),
  ('plan_changed', 'Cambio de plan confirmado', '...', '...', '["old_plan","new_plan","proration_amount"]', true),
  ('custom_blank', 'Email personalizado', '', '', '[]', true);
```

#### 5.2.10 `admin_plan_versions` (versionado de precios)

Cuando un admin cambia el precio de un plan, queda como nueva versión. Las suscripciones existentes mantienen su `locked_price_cents_monthly` (en `memberships`) hasta que admin haga migración explícita.

```sql
create table admin_plan_versions (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references plans(id) on delete restrict,
  version_number integer not null,
  price_cents_monthly integer not null,
  effective_from timestamptz not null default now(),
  effective_until timestamptz, -- null = vigente
  features_snapshot jsonb not null,
  changed_by uuid references admin_users(id),
  change_reason text,
  created_at timestamptz not null default now()
);

create unique index idx_admin_plan_versions_plan_version on admin_plan_versions(plan_id, version_number);
create index idx_admin_plan_versions_current on admin_plan_versions(plan_id) where effective_until is null;
```

### 5.3 Extensiones a tablas existentes

**ALERTA** — esto requiere ALTER a `memberships` (tabla extendida en PRD Azul). Hacer en migración nueva, ambiente coordinado.

```sql
alter table memberships
  add column if not exists locked_price_cents_monthly integer,
  add column if not exists locked_currency_code text default 'DOP',
  add column if not exists locked_at timestamptz,
  add column if not exists last_admin_action_id uuid; -- shortcut al último admin_audit_log
```

**Backfill al deploy**: `UPDATE memberships SET locked_price_cents_monthly = plans.price_cents_monthly, locked_at = now() FROM plans WHERE memberships.plan_id = plans.id`.

### 5.4 RLS

| Tabla | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `admin_users` | mango_admin | mango_admin (vía RPC `admin_invite_user`) | mango_admin | Nadie (soft delete vía `status='disabled'`) |
| `admin_roles` | mango_admin + authenticated (read-only) | mango_admin | mango_admin | Nadie |
| `admin_user_roles` | mango_admin | mango_admin | mango_admin | mango_admin |
| `admin_audit_log` | mango_admin | Solo vía RPC (no INSERT directo) | Nadie | Nadie |
| `admin_customer_notes` | mango_admin con permiso `customers.read` | mango_admin con `customers.write` | autor + owners | autor + owners |
| `admin_tickets` | mango_admin | mango_admin | mango_admin | Nadie (soft via status='closed') |
| `admin_ticket_messages` | mango_admin | mango_admin | autor (dentro de 5 min) | Nadie |
| `admin_extensions` | mango_admin | mango_admin con `billing.write` (vía RPC) | revert vía RPC | Nadie |
| `admin_invoices` | mango_admin con `invoices.read` | mango_admin con `invoices.create` (vía RPC) | vía RPC | Nadie |
| `admin_email_log` | mango_admin | Solo vía RPC | Nadie | Nadie |
| `admin_email_templates` | mango_admin | mango_admin con `templates.manage` | mango_admin con `templates.manage` (no system) | Solo no-system |
| `admin_plan_versions` | mango_admin | Solo vía RPC `admin_update_plan_price` | Nadie | Nadie |

### 5.5 RPCs principales (acciones admin)

Cada acción operativa se ejecuta vía RPC `security definer` que:
1. Valida que el caller es `mango_admin` con el permiso correcto.
2. Loguea en `admin_audit_log`.
3. Ejecuta el cambio atómico.
4. Dispara side effects (email, alerta) si aplica.

| RPC | Permiso requerido | Acción |
|---|---|---|
| `admin_suspend_customer(business_id, reason)` | `customers.write` | Marca memberships.billing_status='suspended', dispara email |
| `admin_reactivate_customer(business_id)` | `customers.write` | Marca 'active', resetea attempts, dispara cobro inmediato |
| `admin_grant_extension(business_id, type, days, reason)` | `billing.write` | INSERT admin_extensions, actualiza next_billing_date |
| `admin_apply_credit(business_id, amount_cents, reason)` | `billing.write` | INSERT admin_extensions tipo 'free_credit' |
| `admin_force_charge(membership_id, amount_cents, reason)` | `billing.charge` | Invoca Edge Function azul-charge-subscription con override |
| `admin_refund_charge(charge_id, amount_cents, reason)` | `billing.refund` | Marca charge para refund manual (Azul no tiene refund automatizado v1) |
| `admin_change_plan(membership_id, new_plan_id, proration_strategy)` | `billing.write` | Cambia plan_id, calcula prorrateo, dispara cobro |
| `admin_cancel_account(business_id, reason, immediate)` | `customers.delete` | Marca billing_status='cancelled', cierra sesiones, opcional immediate |
| `admin_create_invoice(charge_id, type, custom_fields)` | `invoices.create` | Crea draft invoice, llama Alanube, devuelve admin_invoices.id |
| `admin_send_invoice_email(invoice_id, override_email)` | `invoices.send` | Envía PDF al cliente, registra en admin_email_log |
| `admin_cancel_invoice(invoice_id, reason)` | `invoices.cancel` | Llama Alanube cancel, marca cancelled |
| `admin_send_email(business_id, template_code, variables, override_to)` | `communications.write` | Envía email vía Resend, registra |
| `admin_send_bulk_email(filter, template_code, variables)` | `communications.bulk` | Envío a múltiples businesses, registra cada uno |
| `admin_update_plan_price(plan_id, new_price_cents, reason)` | `plans.write` | Crea admin_plan_versions, actualiza plans (no afecta memberships existentes) |
| `admin_migrate_plan_subscribers(plan_id, target_price_cents)` | `plans.migrate` | Actualiza locked_price_cents_monthly de todos los suscriptos al plan |
| `admin_invite_admin(email, role_code)` | `admins.invite` | Crea admin_users + invita por email |
| `admin_disable_admin(admin_id, reason)` | `admins.manage` | Marca status='disabled' |

## 6. Roles y permisos

### 6.1 Roles predefinidos (seed)

| Rol | Permisos | Casos de uso |
|---|---|---|
| **Owner** | `["*"]` | Tú y socios. Acceso total incluyendo gestión de roles. |
| **Billing** | `["customers.read","billing.*","invoices.*","communications.write"]` | Contabilidad: cobros, refunds, NCF, comunicación de pagos. |
| **Support** | `["customers.read","customers.write","tickets.*","communications.write","notes.*"]` | Atención al cliente: ver datos, suspender por mal uso, abrir tickets, enviar emails. NO toca billing. |
| **Sales** | `["customers.read","communications.write","plans.read","notes.write"]` | Equipo comercial: ver clientes, contactarlos, recomendar plan, sin tocar billing ni cancelar. |
| **Analyst** | `["customers.read","billing.read","invoices.read","metrics.read"]` | Solo lectura para análisis/reportes. |

### 6.2 Permisos granulares (catálogo)

```
admins.invite           admins.manage           audit.read
customers.read          customers.write         customers.delete
billing.read            billing.write           billing.charge          billing.refund
plans.read              plans.write             plans.migrate
invoices.read           invoices.create         invoices.send           invoices.cancel
communications.write    communications.bulk     templates.manage
tickets.read            tickets.write           tickets.assign
notes.read              notes.write
metrics.read            metrics.export
settings.read           settings.write
```

## 7. Pantallas / Módulos

### 7.1 Dashboard

Página de aterrizaje. Cards principales:

- **KPIs hoy**: MRR actual, MRR ayer, # clientes activos, # nuevos esta semana, # en past_due, # suspendidos.
- **Alertas**: cobros que fallaron en últimas 24h, sesiones tampered, tickets sin respuesta >24h, businesses con AUTH_KEY mTLS expirando.
- **Actividad reciente**: últimas 20 acciones del admin log (con quién hizo qué).
- **Cobros próximos 7 días**: lista de businesses con `next_billing_date` en la ventana, ordenados por fecha.
- **Trial terminando**: businesses con `trial_ends_at` en los próximos 7 días.
- **Top errores Azul**: agrupados por response_message en últimas 24h.

### 7.2 Clientes (lista + 360°)

#### Lista

Tabla paginada con filtros:
- Nombre del negocio (search).
- Owner email.
- Plan (basic/pro/enterprise).
- `billing_status` (multi-select: trial, active, past_due, suspended, cancelled).
- Fecha registro (rango).
- Próximo cobro (rango).
- Tags / categorías (futuro).

Columnas:
- Business name + branch.
- Owner email.
- Plan + precio actual.
- Status (badge color-coded).
- Trial ends / Next billing.
- MRR (computed: locked_price_cents_monthly).
- Acciones rápidas (3 dots → suspender, dar prórroga, enviar email, abrir 360).

#### Vista 360° (al clickear)

Una pantalla con tabs/secciones:

**Header**: business name, status badge, owner email, plan, fecha registro, próximo cobro. Botones de acción rápida: suspender, reactivar, enviar email, abrir ticket, ver en POS (impersonate).

**Tabs:**

1. **Resumen**:
   - Cards: status, plan, trial ends, next billing, MRR, churned (si aplica), días como cliente.
   - Timeline: últimas 10 acciones (cobros, cambios, tickets, emails enviados).
   - Notas pinneadas (admin_customer_notes pinned=true).

2. **Datos del negocio**:
   - Nombre, dominio, tipo, país, dirección, teléfono.
   - RNC (si tienen).
   - Owner: full_name, email, fecha registro.
   - Miembros: lista de `memberships` con role, email, fecha alta.
   - Botón "Editar datos" (escribe en businesses).

3. **Suscripción**:
   - Plan actual + precio locked.
   - Trial info.
   - Período de facturación actual.
   - Histórico de cambios de plan.
   - Prórrogas activas (admin_extensions).
   - Botones: cambiar plan, dar prórroga, aplicar crédito, cancelar.

4. **Método de pago**:
   - Tarjeta default (brand + last4 + expiración + status).
   - Histórico de tarjetas (revoked/expired).
   - Sesiones recientes (azul_payment_sessions).
   - Botón "Forzar agregar tarjeta" (envía link al cliente).

5. **Cobros**:
   - Tabla de `azul_charges` con filtros (status, fecha).
   - Por cada cobro: fecha, monto, status, response_message, NCF asociada si aplica.
   - Acciones: ver detalle (raw_request/response), forzar reintento (si declined), refund manual.

6. **Facturas (NCF)**:
   - Lista de `admin_invoices` por business.
   - Por cada una: NCF, fecha emisión, monto, status, link al PDF.
   - Acciones: ver PDF, reenviar al cliente, anular.
   - Botón "Crear factura manual" (sin charge asociado, ej: cobro offline).

7. **Comunicaciones**:
   - Lista de `admin_email_log` por business.
   - Por cada uno: subject, sent_at, status, template usado.
   - Acciones: ver body, reenviar.
   - Botón "Enviar nuevo email".

8. **Tickets**:
   - Lista de `admin_tickets` por business.
   - Botón "Abrir ticket".

9. **Notas internas** (CRM):
   - Lista de `admin_customer_notes` con categoría y autor.
   - Pin/unpin.
   - Crear nota nueva.

10. **Audit**:
    - Lista de `admin_audit_log` filtrado por business_id.
    - Quién hizo qué, cuándo, before/after.

### 7.3 Billing — vista global

Pantalla agregadora de cobros (no por cliente).

- **Cobros del día/semana/mes**: tabla con filtros (status, business, monto).
- **En riesgo**: businesses con attempt > 0 (segundo o tercer intento).
- **Failed**: cobros declined hoy/semana, agrupados por motivo.
- **Próximos**: lista de `next_billing_date` futuros (próximos 7 días).
- **Refunds pendientes**: cobros marcados para refund manual.
- **Bulk actions**: seleccionar varios y forzar reintento masivo.

### 7.4 Planes y precios

- Tabla de `plans` con precio actual, # suscriptos, MRR del plan.
- Por cada plan: editar nombre, descripción, features, precio.
- Cambiar precio:
  - Confirma con dialog destacando que NO afecta suscripciones existentes hasta migración explícita.
  - Crea `admin_plan_versions` row.
- Botón "Migrar suscriptos al precio actual": muestra cuántos serían afectados, requiere confirmación + razón.
- Histórico de versiones de precio.

### 7.5 Facturas (NCF)

Lista global de `admin_invoices` con filtros.

- Por cada una: business, NCF, monto, status, link al cliente.
- Bulk: enviar todas las facturas pendientes del mes.
- Reportes mensuales: total facturado, breakdown por tipo (crédito fiscal vs consumidor final).

### 7.6 Comunicaciones

- Editor de templates (Markdown + variables).
- Bulk send: enviar un email a múltiples businesses con filtro.
- Histórico de envíos (admin_email_log) con métricas de entrega (delivered/bounced/complained).

### 7.7 Tickets

- Kanban: open / pending_customer / pending_internal / resolved.
- Filtros por agente, business, categoría, prioridad.
- Vista detalle: hilo de mensajes (interno + público).
- Notificaciones a los admins cuando llega respuesta del cliente (futuro).

### 7.8 Métricas y reportes

Pantalla con gráficos (usando `fl_chart` o equivalente):

- **MRR trend**: mensual y acumulado.
- **Churn rate mensual**.
- **Trial → paid conversion** (cohort).
- **LTV promedio**.
- **Top businesses por LTV**.
- **Distribución por plan**.
- **Mapa de cobros fallidos** por motivo.
- **Adopción de features** (cuántos businesses usan KDS, multi-mesero, etc — requiere instrumentación futura).

Exportación CSV de cualquier tabla.

### 7.9 Audit log

- Tabla paginada de `admin_audit_log`.
- Filtros: admin, action, business, fecha.
- Cada fila expandible muestra before/after JSON.
- Read-only — no se puede editar ni borrar nada.

### 7.10 Configuración

- **Admins**: lista + invitar + editar roles + deshabilitar.
- **Roles**: editar permisos de cada rol (excepto Owner).
- **Templates de email**: editor.
- **Plantillas de NCF** (futuro).
- **Mi cuenta**: cambiar password, configurar 2FA, sesiones activas.

## 8. Flujos operativos clave

### 8.1 Suspender cliente manualmente

```
Admin (rol billing o owner) → Cliente 360° → "Suspender cuenta"
→ Dialog: motivo (textarea required, dropdown sugerencias: 'pago fraudulento', 'TOS violation', 'request del cliente')
→ Confirma
→ RPC admin_suspend_customer(business_id, reason):
    1. Validate permiso 'customers.write' o 'billing.*'
    2. UPDATE memberships SET billing_status='suspended', suspended_at=now(), cancellation_reason=motivo
       WHERE business_id=X AND is_billing_anchor=true
    3. INSERT admin_audit_log con before/after
    4. Trigger email al owner con template 'subscription_suspended'
    5. RETURN ok
→ UI refresca, muestra badge "Suspendida"
→ App POS del comercio: al próximo poll, ve billing_status='suspended' y muestra SuspendedOverlay
```

### 8.2 Dar prórroga (extender trial o gracia post-failure)

```
Admin → Cliente 360° → "Dar prórroga"
→ Dialog:
    - Tipo: trial_extension | payment_grace | free_credit
    - Días (si trial/grace): default 7
    - Monto (si credit): en DOP
    - Razón (required)
    - Mensaje opcional al cliente
→ Confirma
→ RPC admin_grant_extension(...):
    1. Validate permiso 'billing.write'
    2. INSERT admin_extensions
    3. UPDATE memberships:
       - Si trial_extension: trial_ends_at += días, next_billing_date += días
       - Si payment_grace: next_billing_date += días (no toca trial_ends_at)
       - Si free_credit: solo INSERT en extensions, el cron de cobro descuenta en próximo charge
    4. Trigger email opcional con customer_facing_message
    5. INSERT admin_audit_log
→ UI muestra prórroga activa en sección Suscripción
```

### 8.3 Cobrar manualmente (override)

```
Admin (rol billing) → Cliente 360° → Cobros → "Cobrar ahora"
→ Dialog:
    - Monto: default = plan price; permite override
    - Concepto: dropdown ('mensualidad actual', 'mes adelantado', 'ajuste', 'custom')
    - Razón required
→ Confirma
→ RPC admin_force_charge(membership_id, amount_cents, reason):
    1. Validate permiso 'billing.charge'
    2. Generate order_number = mp_chg_admin_{uuid}
    3. INSERT azul_charges (status='pending', flag is_admin_override=true en metadata)
    4. Invoca Edge Function azul-charge-subscription
    5. Actualiza estado según resultado
    6. INSERT admin_audit_log con razón
→ UI muestra resultado: approved/declined/error
→ Si approved: opcional emitir NCF de inmediato (link directo a wizard de factura)
```

### 8.4 Refund manual (post-cobro)

```
Admin (rol billing.refund) → Cliente 360° → Cobro X → "Refund"
→ Dialog:
    - Monto: parcial o total
    - Razón (required)
    - Notify customer? (checkbox)
→ Confirma
→ RPC admin_refund_charge(charge_id, amount_cents, reason):
    1. Validate permiso
    2. UPDATE azul_charges SET status='voided' (no llamamos Azul automáticamente — v1 es manual desde portal Azul)
    3. INSERT admin_audit_log con flag manual_refund_pending=true
    4. Generar admin_invoices tipo nota_credito vinculada al cobro original
    5. Si notify=true → enviar email al cliente con confirmación de refund
→ UI muestra "Refund marcado. Procesar en portal Azul: [link]"
```

### 8.5 Cambiar plan (admin override, no requiere consent adicional)

```
Admin → Cliente 360° → "Cambiar plan"
→ Dialog:
    - Nuevo plan
    - Estrategia: prorratear ahora | esperar al próximo ciclo | gratis hasta próximo ciclo
    - Locked at new price? (sí por default)
    - Razón
→ RPC admin_change_plan(membership_id, new_plan_id, strategy, reason):
    1. Validate permiso
    2. Calcula prorrateo según estrategia
    3. UPDATE memberships: plan_id, locked_price_cents_monthly
    4. Si prorratear ahora: invoca azul-charge-subscription con monto del ajuste
    5. INSERT admin_audit_log
    6. Email al cliente con template 'plan_changed'
```

### 8.6 Emitir factura NCF para un cobro

```
Admin (rol invoices.create) → Cliente 360° → Cobros → Cobro X aprobado → "Emitir NCF"
→ Wizard:
    - Tipo NCF (crédito fiscal vs consumidor final)
    - RNC si aplica
    - Concepto: pre-llenado "Suscripción MangoPOS - Plan Pro - Junio 2026"
    - Confirmar montos
→ RPC admin_create_invoice(charge_id, type, fields):
    1. Validate permiso
    2. INSERT admin_invoices status='draft'
    3. Llama Alanube API → recibe ncf + alanube_id + URLs
    4. UPDATE admin_invoices status='submitted'/'accepted'
    5. INSERT admin_audit_log
    6. RETURN invoice_id
→ UI muestra factura emitida con NCF
→ Botón "Enviar al cliente" → RPC admin_send_invoice_email → registra en admin_email_log
```

### 8.7 Cancelar cuenta (admin-initiated)

```
Admin → Cliente 360° → "Cancelar cuenta"
→ Dialog:
    - Razón (required, dropdown: 'request del cliente', 'TOS violation', 'cuenta inactiva', 'consolidación')
    - Inmediato? (checkbox) — si no, cancela al final del período pagado
    - Refund prorrateado? (checkbox)
→ RPC admin_cancel_account(business_id, reason, immediate, refund):
    1. Validate permiso
    2. UPDATE memberships SET billing_status='cancelled', cancelled_at, cancellation_reason
    3. Si immediate: also UPDATE businesses.status='inactive'
    4. Si refund: calcular monto prorrateado, trigger refund
    5. INSERT admin_audit_log
    6. Email al cliente
    7. Revoca sesiones activas del owner (security)
```

### 8.8 Reactivar cuenta suspendida (recovery flow)

```
Admin → Cliente 360° (suspended) → "Reactivar"
→ Dialog:
    - Cobrar inmediatamente? (sí por default — para confirmar tarjeta funciona)
    - Razón
→ RPC admin_reactivate_customer(business_id):
    1. UPDATE memberships SET billing_status='active', suspended_at=null, current_attempt_number=0
    2. Si cobrar: invoca azul-charge-subscription con período actual
    3. Si cobro OK: confirm, sino vuelve a 'past_due'
    4. INSERT admin_audit_log
    5. Email al cliente
```

### 8.9 Migración masiva (cambio de precio aplicado a todos)

```
Admin (rol plans.migrate) → Planes → Plan Pro → "Migrar suscriptos al precio actual"
→ Dialog:
    - Muestra: "X businesses suscritos al Plan Pro tienen precio locked en Y. Cambiar a Z = precio actual."
    - Aviso de comunicación: "30 días antes de aplicar, recomendamos enviar email a todos. ¿Adjuntar plantilla?"
    - Fecha efectiva: hoy | dentro de X días (programable)
    - Razón
→ Si dentro de X días: crea entrada en admin_scheduled_migrations (tabla futura)
→ Si hoy: RPC admin_migrate_plan_subscribers (transacción):
    1. UPDATE memberships SET locked_price_cents_monthly = nuevo precio, locked_at=now()
       WHERE plan_id = X
    2. INSERT admin_audit_log con before/after de cada uno
    3. RETURN # afectados
→ UI muestra resumen
```

### 8.10 Onboarding manual (sales-assisted)

```
Sales/Owner → "Nuevo cliente"
→ Wizard:
    Step 1: datos del owner (email, full_name, password temporal)
    Step 2: datos del negocio (nombre, tipo, etc.)
    Step 3: plan + precio negociado (puede ser distinto del catálogo)
    Step 4: días de trial extendido si aplica
    Step 5: confirmar
→ RPC admin_create_business:
    1. Create auth.users (envía email de bienvenida con password)
    2. Create businesses
    3. Create memberships anchor con plan_id + locked_price_cents personalizado + trial_ends_at extendido
    4. INSERT admin_audit_log
    5. RETURN business_id + login URL
→ Sales comparte URL + credenciales con el cliente
```

## 9. Integraciones externas

| Integración | Para qué | Detalles |
|---|---|---|
| **Supabase** (DB + Auth) | Persistencia, auth admins | Misma instancia que `mangospos` |
| **Resend** | Envío de emails | Ya configurado en alanube-webhook |
| **Alanube** | Generación de NCF | API REST, usa `ALANUBE_JWT` ya configurado |
| **Azul** | Cobros recurrentes / refunds manuales | Solo refunds vía portal Azul v1 |
| **Slack** (futuro) | Alertas internas (cobros fallidos, tickets urgentes) | Webhook URL configurable |
| **Sentry** (futuro) | Error tracking | Recomendado para production |
| **PostHog** (futuro) | Producto analytics, feature flags | Para entender uso real del admin |

## 10. Seguridad

### 10.1 Autenticación

- **2FA TOTP obligatorio** para todos los admins. Sin 2FA enrollment, el login al panel devuelve error con instrucción de enrolar primero.
- **Sesiones expiran en 8 horas** de inactividad.
- **Re-auth para acciones sensibles**: refunds >RD$10,000, cancelar cuenta, migrar planes, modificar roles.

### 10.2 Permisos

- Permisos checkeados en CADA RPC (no se confía solo en UI).
- Wildcard `*` solo para rol Owner. Cualquier otro role debe enumerar.
- Revocación instantánea: deshabilitar admin invalida todas las sesiones activas en ≤1 min.

### 10.3 Audit log

- Append-only. RLS impide UPDATE/DELETE incluso para Owner.
- `before_state` y `after_state` son JSONB serializados.
- Retención mínima 7 años (compliance fiscal RD).
- Exportable a S3 mensualmente para backup off-DB.

### 10.4 Manejo de datos sensibles

- `data_vault_token` NUNCA se expone en pantalla. Solo se muestra `card_number_masked`.
- RNC, dirección, datos personales: visibles para roles autorizados, redacted para Analyst.
- Logs no incluyen passwords, tokens, ni full PAN.

### 10.5 IP allowlist (opcional, recomendado para producción)

- Configurable a nivel servicio: solo permitir login desde IPs específicas (oficinas, VPN del equipo).
- Bypass para emergencias vía 2FA + autorización de Owner.

### 10.6 Rate limiting

- 100 RPC calls/min por admin (excepto Owner: 500).
- Bulk emails: max 1000 destinatarios por job, max 5 bulk jobs/día por admin.

## 11. Métricas a trackear

### 11.1 Business (negocio de MangoPOS)

- **MRR** (Monthly Recurring Revenue): suma de `locked_price_cents_monthly` de memberships con `billing_status='active'`.
- **ARR** (Annual Recurring Revenue): MRR × 12.
- **Churn rate mensual**: # de cancellations este mes / # activos al inicio del mes.
- **Trial → paid conversion**: % de trials que llegan a primer cobro exitoso.
- **LTV** (Lifetime Value): MRR promedio × meses promedio activos.
- **CAC** (Customer Acquisition Cost): externo, manual por ahora.
- **Net Revenue Retention**: cómo cambia el revenue del cohort mes a mes (incluye upgrades/downgrades).

### 11.2 Operacionales

- **Cobros aprobados / declinados / errors** por período.
- **Tiempo promedio de cobro** (cron schedule → completion).
- **Tasa de aprobación Azul** (approved/total).
- **Cobros en past_due**: # de businesses con attempts > 0.
- **Tickets abiertos / resueltos / tiempo medio de resolución**.
- **Emails enviados / bounced / complained**.

### 11.3 Admin

- **Acciones por admin por período** (productividad).
- **Acciones por tipo** (refunds, suspensiones, extensions, etc.).

## 12. Plan de fases

Cada fase es independientemente entregable y aporta valor inmediato.

### Fase 0 — Setup base
- Repo `mango-administrador` con scaffold (probablemente Next.js o React + Vite, no Flutter — el admin se usa en desktop).
- Conexión a Supabase con rol `mango_admin`.
- Auth admin con 2FA enforcement.
- Schema `admin_*` aplicado.
- Seed de roles + 1 admin Owner.

**Entrega:** login funcional + dashboard vacío.
**Estimación:** 20-30h.

### Fase 1 — Vista 360° de cliente (read-only)
- Lista de clientes con filtros y search.
- Vista 360° con tabs Resumen, Datos, Suscripción, Método de pago, Cobros, Comunicaciones, Audit.
- Sin acciones todavía, solo lectura.

**Entrega:** equipo puede ver toda la info de cualquier cliente sin tocar Supabase Studio.
**Estimación:** 30-40h.

### Fase 2 — Acciones operativas core
- RPCs: suspend, reactivate, grant_extension, apply_credit, cancel_account.
- UI: botones en vista 360° que llaman RPCs.
- Audit log poblado correctamente.
- Templates de email para cada acción.

**Entrega:** ops puede gestionar el ciclo de vida del cliente sin SQL.
**Estimación:** 30-40h.

### Fase 3 — Facturación NCF
- Integración Alanube.
- Tabla `admin_invoices`.
- Wizard de emisión de factura.
- Envío por email con PDF adjunto.
- Anulación.

**Entrega:** facturación electrónica automatizada por cobro Azul.
**Estimación:** 40-60h (depende de complejidad Alanube).

### Fase 4 — Comunicaciones
- Editor de templates.
- Bulk send con filtros.
- Histórico con tracking de delivery.

**Entrega:** marketing/ops puede comunicarse con segmentos de clientes desde el panel.
**Estimación:** 20-30h.

### Fase 5 — Tickets y CRM
- Tablas tickets + messages + notes.
- Kanban de tickets.
- Notas internas en vista 360°.

**Entrega:** centralización del soporte.
**Estimación:** 30-40h.

### Fase 6 — Métricas y reportes
- Dashboard con KPIs.
- Gráficos de MRR, churn, conversión.
- Exportación CSV.

**Entrega:** reporting ejecutivo para owners y equipo.
**Estimación:** 25-35h.

### Fase 7 — Locked pricing + versionado de planes
- ALTER memberships con `locked_price_cents_monthly`.
- Backfill.
- Modificar Edge Function `azul-charge-subscription` para usar locked price.
- UI admin para cambiar precio + migrar.

**Entrega:** seguridad legal contra cambios de precio que afecten existing customers sin consent.
**Estimación:** 20-30h.

### Fase 8 — Onboarding asistido y bulk operations
- Wizard "nuevo cliente" para sales.
- Bulk: aplicar extension a múltiples businesses, cambiar plan masivo, etc.
- Import CSV de clientes (migración desde Stripe / manual).

**Entrega:** sales y migración escalable.
**Estimación:** 30-40h.

### Fase 9 — Seguridad endurecida y polish
- IP allowlist.
- Re-auth para acciones críticas.
- Audit log export a S3.
- Notificaciones Slack para alertas.

**Entrega:** sistema production-grade.
**Estimación:** 25-35h.

**Total estimado v1 completo: 270-400h** (1.5-2.5 meses fulltime de 1 dev senior).

## 13. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| **Admin malicioso o comprometido** | Baja | Crítico | 2FA + audit log + IP allowlist + revocación inmediata + alerta Owner ante acciones sensibles |
| **Drift entre lo que ve el admin y el estado real** (cache, Realtime falla) | Media | Medio | Realtime + refresh button en cada vista crítica; warning si data >5min |
| **Alanube cae cuando vamos a emitir NCF** | Media | Alto | Queue persistente: si Alanube responde error retryable, marcar 'submitted' y retry job cada 10 min |
| **Migración masiva de precios sin querer** | Baja | Crítico | Confirmación con texto manual ("Escribe MIGRAR para confirmar") + audit con razón obligatoria |
| **Acciones operativas sin razón documentada** | Alta | Medio | Razón required en TODAS las RPC sensibles |
| **Bulk email termina en spam** | Media | Alto | Resend con domain auth + warmup gradual + monitoring de complaint rate |
| **Refunds manuales se olvidan en portal Azul** | Alta | Alto | Tabla `admin_invoices` tipo `nota_credito` marca pending → checklist semanal de pendientes |
| **El admin se desincroniza del schema de mangospos** | Media | Alto | Migraciones DB compartidas en un solo repo (incluso si el código es separado); CI valida que el schema usado por mango-administrador matchea el actual |

## 14. Apéndices

### A. Stack tecnológico sugerido

- **Frontend**: Next.js 14 + TypeScript + Tailwind + shadcn/ui (cohesión visual rápida).
- **Backend**: Supabase Edge Functions (Deno/TypeScript) — reuso de patrón del PRD Azul.
- **DB**: Supabase Postgres (misma instancia).
- **Auth**: Supabase Auth con MFA habilitado.
- **Email**: Resend.
- **NCF**: Alanube SDK.
- **Charts**: Recharts o Tremor.
- **Tablas**: TanStack Table.

### B. URLs / endpoints clave

- Admin web: `https://admin.mangopos.do`
- Supabase API: `https://supabase.mangopos.do` (compartido con `mangospos`)
- Alanube: variables ya configuradas en stack Supabase.

### C. Glosario

- **MRR**: Monthly Recurring Revenue.
- **ARR**: Annual Recurring Revenue.
- **Churn**: cancelación / pérdida de cliente.
- **LTV**: Lifetime Value.
- **NCF**: Número de Comprobante Fiscal (DGII República Dominicana).
- **Locked price**: precio congelado al momento de suscripción, no cambia con updates del catálogo.
- **Prórroga**: extensión de trial o gracia post-failure otorgada por admin.
- **Impersonate**: login del admin como si fuera el owner del business, para ver el POS como lo ve el cliente.

### D. Cambios respecto a `mangospos`

Tablas que se modifican (ALTER):
- `memberships`: agregar `locked_price_cents_monthly`, `locked_currency_code`, `locked_at`, `last_admin_action_id`.

Tablas que no se tocan, solo se leen:
- `businesses`, `plans`, `azul_payment_methods`, `azul_payment_sessions`, `azul_charges`, `azul_webhook_events`, `auth.users`, `profiles`, `user_businesses`.

Edge Functions de `mangospos` que se modifican:
- `azul-charge-subscription`: usar `memberships.locked_price_cents_monthly` en vez de `plans.price_cents_monthly`.

### E. Decisiones pendientes (a discutir antes de Fase 0)

1. **Multi-tenant del admin**: ¿un admin puede ver solo "su" subset de clientes? V1 dice no (full visibility). Si en el futuro hay franquicias / resellers, agregar `admin_user_business_scopes`.
2. **Impersonate**: ¿permitimos al admin "loguearse como" el owner de un business para ver su POS? Útil para soporte pero requiere auditoría especial. Recomendado para Fase 5+.
3. **API externa para integraciones**: ¿exponemos endpoints REST/GraphQL para que otros sistemas (ERP, contabilidad) consuman datos? No en v1.
4. **Approval workflows**: ¿algunas acciones (refund >$X, migración masiva) requieren aprobación de 2 admins antes de ejecutar? Mejor práctica pero v2.

---

**Fin del PRD.**
