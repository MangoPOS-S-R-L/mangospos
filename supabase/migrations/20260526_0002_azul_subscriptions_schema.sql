-- =============================================================================
-- PRD Azul Subscriptions §5 — Esquema base para integración Azul/DataVault.
--
-- ALCANCE (F2):
--   1. Tabla `plans` (catálogo de planes con precio mensual).
--   2. Extensión de `memberships` con columnas de billing (plan_id,
--      billing_status, trial_ends_at, current_period_*, next_billing_date,
--      consent_granted_at, contadores de reintentos, anchor flag).
--   3. 4 tablas con prefijo azul_: payment_sessions, payment_methods,
--      charges, webhook_events. El rol que el PRD asignaba a
--      `azul_subscription_state` se absorbe en `memberships` por elección
--      explícita del usuario (extender memberships en vez de tabla aparte).
--   4. Vistas públicas que ocultan secretos (data_vault_token, raw blobs).
--   5. RLS basada en `user_has_business_access` / `user_business_role`
--      siguiendo el patrón del repo.
--
-- DECISIÓN CLAVE (acordada con el usuario el 2026-05-26):
--   `memberships` es per-usuario-per-business, pero la suscripción de cobro
--   es per-business. Para reconciliar: agregamos `is_billing_anchor BOOLEAN`
--   y un partial unique index `(business_id) WHERE is_billing_anchor = true`,
--   de modo que exactamente UNA membership por business carga el estado de
--   billing. Convención: backfill posterior marcará la membership del owner.
--
-- STRANGLER FIG: este PRD NO toca `subscriptions` (que no existe), `plans`
--   (que sí creamos), ni elimina columnas existentes de `memberships`. El
--   campo legacy `memberships.plan_type` (text) queda intacto; el nuevo
--   source-of-truth es `memberships.plan_id`.
--
-- IDEMPOTENTE: CREATE TABLE IF NOT EXISTS + ADD COLUMN IF NOT EXISTS.
-- ROLLBACK: `20260526_0002_azul_subscriptions_schema_ROLLBACK.sql`.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tabla plans (catálogo de planes SaaS)
-- ---------------------------------------------------------------------------

create table if not exists public.plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  description text,
  price_cents_monthly integer not null check (price_cents_monthly >= 0),
  currency_code text not null default 'DOP' check (char_length(currency_code) = 3),
  trial_days integer not null default 14 check (trial_days >= 0 and trial_days <= 365),
  is_active boolean not null default true,
  display_order integer not null default 0,
  features jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_plans_is_active on public.plans(is_active);
create index if not exists idx_plans_display_order on public.plans(display_order) where is_active = true;

comment on table public.plans is
  'Catálogo de planes SaaS de MangoPOS para cobro vía Azul. price_cents_monthly '
  'en la unidad mínima de la moneda (centavos DOP). Modificar trial_days no '
  'afecta a suscripciones ya creadas (cada membership snapshea su trial_ends_at).';

-- Seed PLACEHOLDER. Los precios reales deben confirmarse con negocio antes de prod.
-- Convertir DOP a centavos: 1500.00 → 150000.
insert into public.plans (code, name, description, price_cents_monthly, display_order, features)
values
  ('basic',      'Basic',      'Plan inicial: 1 caja, hasta 3 usuarios, reportes básicos.',
   150000, 1,
   '["1 caja registradora", "Hasta 3 usuarios", "Reportes diarios", "Soporte email"]'::jsonb),
  ('pro',        'Pro',        'Plan profesional: cajas ilimitadas, kitchen display, multi-mesero.',
   250000, 2,
   '["Cajas ilimitadas", "Usuarios ilimitados", "KDS", "Multi-mesero", "Reportes avanzados", "Soporte prioritario"]'::jsonb),
  ('enterprise', 'Enterprise', 'Plan empresarial: multi-sucursal, API, integraciones, SLA.',
   450000, 3,
   '["Todo de Pro", "Multi-sucursal consolidada", "API access", "Integraciones a medida", "SLA 99.9%", "Soporte 24/7"]'::jsonb)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Extensión de memberships con columnas de billing
--    (idempotente vía ADD COLUMN IF NOT EXISTS)
-- ---------------------------------------------------------------------------

alter table public.memberships
  add column if not exists plan_id uuid references public.plans(id) on delete restrict,
  add column if not exists is_billing_anchor boolean not null default false,
  add column if not exists billing_status text not null default 'trial',
  add column if not exists trial_ends_at timestamptz,
  add column if not exists current_period_start date,
  add column if not exists current_period_end date,
  add column if not exists next_billing_date date,
  add column if not exists consent_granted_at timestamptz,
  add column if not exists current_attempt_number integer not null default 0,
  add column if not exists suspended_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancellation_reason text;

-- CHECK constraint sobre billing_status. Usamos DROP+ADD para que sea idempotente.
alter table public.memberships
  drop constraint if exists memberships_billing_status_check;
alter table public.memberships
  add constraint memberships_billing_status_check
  check (billing_status in ('trial', 'active', 'past_due', 'suspended', 'cancelled'));

-- CHECK: current_attempt_number entre 0 y 3 (política D11 del PRD).
alter table public.memberships
  drop constraint if exists memberships_attempt_number_check;
alter table public.memberships
  add constraint memberships_attempt_number_check
  check (current_attempt_number >= 0 and current_attempt_number <= 3);

-- Exactamente UNA membership por business carga el estado de billing.
-- El backfill (asignar is_billing_anchor=true al owner) es operación separada.
create unique index if not exists memberships_one_billing_anchor_per_business
  on public.memberships(business_id) where is_billing_anchor = true;

-- Índice para el cron que busca subs a cobrar hoy.
create index if not exists idx_memberships_next_billing_date
  on public.memberships(next_billing_date)
  where is_billing_anchor = true and billing_status in ('active', 'past_due');

create index if not exists idx_memberships_billing_status
  on public.memberships(billing_status)
  where is_billing_anchor = true;

create index if not exists idx_memberships_plan_id
  on public.memberships(plan_id) where plan_id is not null;

comment on column public.memberships.is_billing_anchor is
  'TRUE solo en la membership por-business que carga el estado de billing. '
  'Garantía por partial unique index: máx 1 por business.';
comment on column public.memberships.billing_status is
  'Ciclo de vida del cobro Azul (independiente de memberships.status que '
  'sigue siendo active/canceled/expired para la relación user-business).';
comment on column public.memberships.consent_granted_at is
  'Timestamp del consentimiento del comercio al cobro recurrente, registrado '
  'al marcar el checkbox en el signup. Crítico para defensa de chargebacks.';

-- ---------------------------------------------------------------------------
-- 3. azul_payment_sessions (intents de Payment Page)
--    Se crea antes de payment_methods. La FK circular se agrega en ALTER después.
-- ---------------------------------------------------------------------------

create table if not exists public.azul_payment_sessions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,

  intent_type text not null
    check (intent_type in ('tokenize_and_verify', 'replace_card', 'manual_charge')),
  order_number text not null unique,
  amount_cents integer not null check (amount_cents >= 0),
  currency_code text not null default 'DOP' check (char_length(currency_code) = 3),

  auth_hash_sent text not null,

  status text not null default 'pending'
    check (status in (
      'pending', 'redirected', 'approved', 'declined',
      'cancelled', 'tampered', 'timeout', 'error'
    )),

  azul_order_id text,
  authorization_code text,
  response_code text,
  iso_code text,
  response_message text,
  error_description text,
  rrn text,
  auth_hash_received text,
  raw_callback_query text,

  -- FK a payment_methods se agrega después (ver ALTER abajo).
  resulting_payment_method_id uuid,

  callback_count integer not null default 0 check (callback_count >= 0),

  created_at timestamptz not null default now(),
  redirected_at timestamptz,
  completed_at timestamptz,
  expires_at timestamptz not null default (now() + interval '30 minutes'),
  updated_at timestamptz not null default now()
);

create index if not exists idx_azul_payment_sessions_business
  on public.azul_payment_sessions(business_id);
create index if not exists idx_azul_payment_sessions_status
  on public.azul_payment_sessions(status);
create index if not exists idx_azul_payment_sessions_order_number
  on public.azul_payment_sessions(order_number);
create index if not exists idx_azul_payment_sessions_expires_pending
  on public.azul_payment_sessions(expires_at)
  where status in ('pending', 'redirected');

comment on table public.azul_payment_sessions is
  'Una fila por intento de Payment Page (tokenización, replace card). '
  'order_number es UNIQUE global. callback_count detecta reintentos del browser '
  'sin reprocesar side effects.';

-- ---------------------------------------------------------------------------
-- 4. azul_payment_methods (tarjetas tokenizadas)
-- ---------------------------------------------------------------------------

create table if not exists public.azul_payment_methods (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,

  data_vault_token text not null,
  data_vault_expiration text not null check (data_vault_expiration ~ '^[0-9]{6}$'),
  data_vault_brand text not null,
  card_number_masked text not null,
  azul_order_id_at_creation text,

  status text not null default 'pending_verification'
    check (status in (
      'pending_verification', 'verified', 'failed_verification', 'expired', 'revoked'
    )),
  is_default boolean not null default false,

  verification_session_id uuid references public.azul_payment_sessions(id) on delete set null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoke_reason text
);

-- Exactamente una tarjeta default por business.
create unique index if not exists azul_payment_methods_one_default_per_business
  on public.azul_payment_methods(business_id) where is_default = true;

create index if not exists idx_azul_payment_methods_business
  on public.azul_payment_methods(business_id);
create index if not exists idx_azul_payment_methods_status
  on public.azul_payment_methods(status);

comment on table public.azul_payment_methods is
  'Tarjetas tokenizadas vía DataVault. data_vault_token es secreto (RLS lo '
  'oculta a clientes). card_number_masked es lo único expuesto a UI.';
comment on column public.azul_payment_methods.data_vault_token is
  'Token devuelto por Azul al guardar la tarjeta en DataVault. No es PAN ni '
  'PCI scope, pero se trata como secreto. NUNCA exponer a cliente vía API.';

-- Cerrar FK circular: sessions → payment_methods.
alter table public.azul_payment_sessions
  drop constraint if exists azul_payment_sessions_resulting_payment_method_fkey;
alter table public.azul_payment_sessions
  add constraint azul_payment_sessions_resulting_payment_method_fkey
  foreign key (resulting_payment_method_id)
  references public.azul_payment_methods(id) on delete set null;

-- ---------------------------------------------------------------------------
-- 5. azul_charges (cobros mensuales)
-- ---------------------------------------------------------------------------

create table if not exists public.azul_charges (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  -- El PRD habla de subscription_id pero por decisión usuario el anchor es
  -- memberships. Lo nombramos membership_id para no mentir.
  membership_id uuid not null references public.memberships(id) on delete restrict,
  payment_method_id uuid not null references public.azul_payment_methods(id) on delete restrict,

  order_number text not null unique,
  billing_period_start date not null,
  billing_period_end date not null check (billing_period_end >= billing_period_start),
  attempt_number integer not null default 1 check (attempt_number between 1 and 3),

  amount_cents integer not null check (amount_cents >= 0),
  itbis_cents integer not null default 0 check (itbis_cents >= 0),
  currency_code text not null default 'DOP' check (char_length(currency_code) = 3),

  status text not null default 'pending'
    check (status in ('pending', 'approved', 'declined', 'error', 'voided')),
  authorization_code text,
  response_code text,
  iso_code text,
  response_message text,
  error_description text,
  rrn text,
  azul_order_id text,
  raw_request jsonb,
  raw_response jsonb,

  receipt_pdf_path text,
  receipt_emailed_at timestamptz,

  attempted_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Idempotencia: no podemos crear dos intentos del mismo número para el mismo
-- período de la misma membership.
create unique index if not exists azul_charges_one_per_period_per_attempt
  on public.azul_charges(membership_id, billing_period_start, attempt_number);

create index if not exists idx_azul_charges_business
  on public.azul_charges(business_id);
create index if not exists idx_azul_charges_membership
  on public.azul_charges(membership_id);
create index if not exists idx_azul_charges_status
  on public.azul_charges(status);
create index if not exists idx_azul_charges_attempted_at
  on public.azul_charges(attempted_at desc);

comment on table public.azul_charges is
  'Un registro por intento concreto de cobro vía WS DataVault. El UNIQUE '
  '(membership_id, billing_period_start, attempt_number) garantiza idempotencia '
  'a nivel DB: un cron que corra dos veces no duplica cobros.';
comment on column public.azul_charges.raw_request is
  'Auditoría del request enviado a Azul. NO exponer a cliente (puede contener '
  'metadatos sensibles del transporte).';
comment on column public.azul_charges.raw_response is
  'Auditoría del response de Azul. NO exponer a cliente.';

-- Ahora memberships puede referenciar charges. Agregamos los FKs faltantes.
alter table public.memberships
  add column if not exists last_successful_charge_id uuid,
  add column if not exists last_failed_charge_id uuid;

alter table public.memberships
  drop constraint if exists memberships_last_successful_charge_fkey;
alter table public.memberships
  add constraint memberships_last_successful_charge_fkey
  foreign key (last_successful_charge_id)
  references public.azul_charges(id) on delete set null;

alter table public.memberships
  drop constraint if exists memberships_last_failed_charge_fkey;
alter table public.memberships
  add constraint memberships_last_failed_charge_fkey
  foreign key (last_failed_charge_id)
  references public.azul_charges(id) on delete set null;

-- ---------------------------------------------------------------------------
-- 6. azul_webhook_events (log inmutable de todo lo que llegue de Azul)
-- ---------------------------------------------------------------------------

create table if not exists public.azul_webhook_events (
  id uuid primary key default gen_random_uuid(),
  event_type text not null
    check (event_type in ('payment_page_callback', 'ipn_notification', 'webservice_response')),
  source_ip inet,
  http_method text,
  raw_url text,
  raw_query jsonb,
  raw_body text,
  raw_headers jsonb,
  related_session_id uuid references public.azul_payment_sessions(id) on delete set null,
  related_charge_id uuid references public.azul_charges(id) on delete set null,
  auth_hash_valid boolean,
  processed boolean not null default false,
  processing_error text,
  received_at timestamptz not null default now()
);

create index if not exists idx_azul_webhook_events_received_at
  on public.azul_webhook_events(received_at desc);
create index if not exists idx_azul_webhook_events_session
  on public.azul_webhook_events(related_session_id);
create index if not exists idx_azul_webhook_events_charge
  on public.azul_webhook_events(related_charge_id);
create index if not exists idx_azul_webhook_events_unprocessed
  on public.azul_webhook_events(received_at)
  where processed = false;

comment on table public.azul_webhook_events is
  'Bitácora forense append-only de todo callback/IPN/WS-response de Azul. '
  'Solo se hace UPDATE para marcar processed=true. Nunca DELETE.';

-- ---------------------------------------------------------------------------
-- 7. RLS — siguiendo patrón del repo (user_has_business_access / user_business_role)
-- ---------------------------------------------------------------------------

alter table public.plans enable row level security;
alter table public.azul_payment_sessions enable row level security;
alter table public.azul_payment_methods enable row level security;
alter table public.azul_charges enable row level security;
alter table public.azul_webhook_events enable row level security;

-- plans: catálogo público para usuarios autenticados. Política unificada
-- que muestra (a) planes activos disponibles para nuevos signups, Y (b) el
-- plan al que está suscrita la membership del usuario aunque se haya
-- desactivado. Sin esto un plan deshabilitado oculta la suscripción en UI.
drop policy if exists "plans_select_active" on public.plans;
drop policy if exists "plans_select_all_service" on public.plans;
drop policy if exists "plans_select_visible" on public.plans;
create policy "plans_select_visible" on public.plans
  for select to authenticated
  using (
    is_active = true
    or id in (
      select m.plan_id from public.memberships m
      where m.user_id = auth.uid() and m.plan_id is not null
    )
  );

drop policy if exists "plans_write_service" on public.plans;
create policy "plans_write_service" on public.plans
  for all to service_role using (true) with check (true);

-- plans: usuarios anónimos (durante el signup, sin sesión todavía) deben poder
-- ver los planes activos para que el Step 1 del registro renderice las cards.
-- Sin esta policy el FutureProvider devuelve [] y la UI muestra "No hay planes".
-- Diferenciamos de plans_select_visible (authenticated) que tiene la lógica
-- extra de mostrar el plan al que ya está suscrito aunque esté desactivado —
-- caso que no aplica para anon.
drop policy if exists "plans_select_active_anon" on public.plans;
create policy "plans_select_active_anon" on public.plans
  for select to anon
  using (is_active = true);

-- azul_payment_sessions: SOLO service_role. Las sesiones contienen auth_hash
-- y datos crudos del callback; no se exponen al cliente.
drop policy if exists "azul_sessions_service" on public.azul_payment_sessions;
create policy "azul_sessions_service" on public.azul_payment_sessions
  for all to service_role using (true) with check (true);

-- azul_payment_methods: el cliente del business puede SELECT vía vista que
-- oculta data_vault_token. La tabla base la maneja solo service_role.
drop policy if exists "azul_payment_methods_service" on public.azul_payment_methods;
create policy "azul_payment_methods_service" on public.azul_payment_methods
  for all to service_role using (true) with check (true);

drop policy if exists "azul_payment_methods_select_own_business" on public.azul_payment_methods;
create policy "azul_payment_methods_select_own_business" on public.azul_payment_methods
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- azul_charges: cliente del business puede SELECT (la vista pública filtra
-- raw_request/raw_response). Mutaciones solo service_role.
drop policy if exists "azul_charges_service" on public.azul_charges;
create policy "azul_charges_service" on public.azul_charges
  for all to service_role using (true) with check (true);

drop policy if exists "azul_charges_select_own_business" on public.azul_charges;
create policy "azul_charges_select_own_business" on public.azul_charges
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- azul_webhook_events: SOLO service_role. Bitácora forense interna.
drop policy if exists "azul_webhook_events_service" on public.azul_webhook_events;
create policy "azul_webhook_events_service" on public.azul_webhook_events
  for all to service_role using (true) with check (true);

-- ---------------------------------------------------------------------------
-- 8. Vistas públicas (filtran columnas sensibles)
-- ---------------------------------------------------------------------------

-- Heredan RLS de las tablas base via security_invoker=true (PG15+).
-- Usamos CREATE OR REPLACE VIEW para no romper dependientes a futuro.
create or replace view public.azul_payment_methods_public
with (security_invoker = true)
as
  select
    id,
    business_id,
    data_vault_brand,
    card_number_masked,
    data_vault_expiration,
    status,
    is_default,
    created_at,
    revoked_at
  from public.azul_payment_methods;

comment on view public.azul_payment_methods_public is
  'Vista segura sobre azul_payment_methods. Oculta data_vault_token. '
  'security_invoker=true → respeta RLS de la tabla base.';

create or replace view public.azul_charges_public
with (security_invoker = true)
as
  select
    id,
    business_id,
    membership_id,
    order_number,
    billing_period_start,
    billing_period_end,
    attempt_number,
    amount_cents,
    itbis_cents,
    currency_code,
    status,
    response_message,
    authorization_code,
    rrn,
    attempted_at,
    completed_at,
    receipt_pdf_path,
    receipt_emailed_at
  from public.azul_charges;

comment on view public.azul_charges_public is
  'Vista segura sobre azul_charges. Oculta raw_request, raw_response, '
  'error_description. security_invoker=true → respeta RLS.';

-- ---------------------------------------------------------------------------
-- 9. Trigger updated_at en tablas nuevas
-- ---------------------------------------------------------------------------

create or replace function public.fn_azul_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_plans_updated_at on public.plans;
create trigger trg_plans_updated_at
  before update on public.plans
  for each row execute function public.fn_azul_touch_updated_at();

drop trigger if exists trg_azul_payment_sessions_updated_at on public.azul_payment_sessions;
create trigger trg_azul_payment_sessions_updated_at
  before update on public.azul_payment_sessions
  for each row execute function public.fn_azul_touch_updated_at();

drop trigger if exists trg_azul_payment_methods_updated_at on public.azul_payment_methods;
create trigger trg_azul_payment_methods_updated_at
  before update on public.azul_payment_methods
  for each row execute function public.fn_azul_touch_updated_at();

drop trigger if exists trg_azul_charges_updated_at on public.azul_charges;
create trigger trg_azul_charges_updated_at
  before update on public.azul_charges
  for each row execute function public.fn_azul_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 10. GRANTs explícitos (CRÍTICO — sin esto RLS ni se evalúa porque
--     PostgreSQL niega antes por permisos de tabla).
--     Patrón establecido en el repo: GRANT primero, RLS filtra después.
-- ---------------------------------------------------------------------------

grant select on public.plans to anon, authenticated;
grant all on public.plans to service_role;

grant all on public.azul_payment_sessions to service_role;
grant all on public.azul_payment_methods to service_role;
grant all on public.azul_charges to service_role;
grant all on public.azul_webhook_events to service_role;

-- El cliente lee tarjetas/cobros vía las vistas filtradas, no la tabla base.
grant select on public.azul_payment_methods to authenticated;
grant select on public.azul_charges to authenticated;
grant select on public.azul_payment_methods_public to authenticated;
grant select on public.azul_charges_public to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Comentarios sobre semántica de fechas calendario
-- ---------------------------------------------------------------------------

comment on column public.memberships.trial_ends_at is
  'TZ-aware: instante exacto del fin del trial. Comparar con now() en cron.';
comment on column public.memberships.next_billing_date is
  'Fecha calendario (date sin TZ) en la que toca el próximo cobro. El cron '
  'corre 02:00 UTC; para DOP (UTC-4) "hoy" es coherente con el día del '
  'comercio. Documentar al introducir multi-TZ en PRD futuro.';
comment on column public.memberships.current_period_start is
  'Fecha calendario del inicio del período mensual actualmente vigente.';
comment on column public.memberships.current_period_end is
  'Fecha calendario del fin del período mensual actualmente vigente.';

commit;
