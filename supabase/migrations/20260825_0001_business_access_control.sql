-- ============================================================================
-- 20260825_0001_business_access_control.sql
--
-- Bloqueo del POS por falta de pago, controlado desde el panel administrativo.
--
-- CONTEXTO
-- --------
-- Hasta hoy el bloqueo vivía a medias en tres lugares que no se hablaban:
--   * `memberships.billing_status='suspended'` — lo escribe el cron de Azul
--     tras 3 cobros fallidos, pero el POS lo ignoraba (BillingGuard apagado).
--   * `businesses.status='inactive'` — lo escribe `deactivate_business()` desde
--     el panel, y el POS nunca leyó esa columna (el botón "Desactivar cuenta"
--     no bloqueaba nada).
--   * Nada permitía al operador programar un corte, dar prórroga ni explicarle
--     al dueño POR QUÉ está bloqueado.
--
-- Esta migración crea UNA sola fuente de verdad calculada
-- (`fn_business_access_state`) que consolida esas señales + los controles
-- manuales del operador, y la expone al POS por un RPC gateado por membresía.
--
-- MODELO ESCALONADO (decisión de producto 2026-08-25)
--   ok      → sin fricción.
--   warning → hay algo por resolver pero todavía hay tiempo (corte programado
--             a futuro, prórroga vigente, trial por vencer). Banner, no bloquea.
--   grace   → ya venció y corre el período de gracia. Banner rojo + regresiva.
--   locked  → pantalla completa; solo se puede pagar / contactar soporte.
--
-- SEGURIDAD DE DESPLIEGUE — el riesgo real de esta feature es bloquear a
-- clientes que sí pagan porque su `billing_status` quedó viejo de las pruebas
-- de Azul. Por eso el enforcement nace APAGADO:
--   * `platform_access_policy.enforcement_enabled = false` (kill switch global)
--   * `business_access_control.enforcement = 'inherit'` por negocio, con
--     'on'/'off' para pilotear negocio por negocio.
-- El estado se CALCULA igual con el switch apagado (para que el panel muestre
-- "este negocio se bloquearía por X"), pero se devuelve `enforced=false` y el
-- POS no bloquea. Encender es una decisión aparte y consciente.
--
-- No toca RLS de órdenes/ventas ni la cola offline: el enforcement es de UI.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) Dependencia — `is_platform_operator()` la crea el repo del panel
--    (mangopos_administrador, migración 0001_platform_operators.sql). Ambos
--    repos apuntan a la MISMA base. Fallamos temprano y con mensaje claro en
--    vez de dejar la migración aplicada a medias.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.is_platform_operator(uuid)') is null then
    raise exception
      'Falta public.is_platform_operator(uuid). Aplica primero la migración '
      '0001_platform_operators.sql del repo mangopos_administrador.';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1) Política global de la plataforma (singleton)
-- ---------------------------------------------------------------------------
create table if not exists public.platform_access_policy (
  id                      boolean primary key default true,
  enforcement_enabled     boolean     not null default false,
  default_grace_days      integer     not null default 5,
  lock_on_past_due        boolean     not null default true,
  lock_on_trial_expired   boolean     not null default false,
  offline_max_days        integer     not null default 7,
  default_customer_message text,
  contact_name            text,
  contact_phone           text,
  contact_email           text,
  updated_by              uuid references auth.users(id),
  updated_at              timestamptz not null default now(),
  constraint platform_access_policy_singleton check (id = true),
  constraint platform_access_policy_grace_days_check
    check (default_grace_days >= 0 and default_grace_days <= 90),
  constraint platform_access_policy_offline_days_check
    check (offline_max_days >= 0 and offline_max_days <= 90)
);

comment on table public.platform_access_policy is
  'Política global de bloqueo por falta de pago. Fila única (id=true). '
  'enforcement_enabled es el kill switch maestro: en false el POS nunca '
  'bloquea, aunque el estado se siga calculando para el panel. '
  'offline_max_days=0 desactiva el bloqueo por snapshot viejo.';

comment on column public.platform_access_policy.offline_max_days is
  'Días que el POS puede operar sin poder verificar el estado contra el '
  'servidor antes de bloquear. Evita que desconecten el internet para escapar '
  'del bloqueo. 0 = nunca bloquear por falta de verificación.';

insert into public.platform_access_policy (id) values (true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2) Control de acceso por negocio
-- ---------------------------------------------------------------------------
create table if not exists public.business_access_control (
  business_id       uuid primary key references public.businesses(id) on delete cascade,

  -- 'auto'           → el estado sale de billing + businesses.status
  -- 'forced_locked'  → el operador cortó el acceso a mano
  -- 'forced_open'    → el operador garantiza acceso (usar override_until para
  --                    prórrogas con vencimiento; sin fecha es indefinido)
  lock_mode         text        not null default 'auto',

  -- Enforcement por negocio: 'inherit' usa el switch global.
  enforcement       text        not null default 'inherit',

  scheduled_lock_at timestamptz,          -- fecha de corte programada
  override_until    timestamptz,          -- prórroga: acceso garantizado hasta
  grace_days        integer,              -- null = hereda default_grace_days

  lock_reason       text,                 -- interno, para auditoría/soporte
  customer_message  text,                 -- lo que ve el dueño en el POS
  contact_name      text,
  contact_phone     text,

  locked_at         timestamptz,          -- cuándo se forzó el bloqueo manual
  locked_by         uuid references auth.users(id),
  updated_by        uuid references auth.users(id),
  updated_at        timestamptz not null default now(),
  created_at        timestamptz not null default now(),

  constraint business_access_control_lock_mode_check
    check (lock_mode in ('auto', 'forced_locked', 'forced_open')),
  constraint business_access_control_enforcement_check
    check (enforcement in ('inherit', 'on', 'off')),
  constraint business_access_control_grace_days_check
    check (grace_days is null or (grace_days >= 0 and grace_days <= 90))
);

comment on table public.business_access_control is
  'Controles manuales del operador sobre el acceso al POS de un negocio. '
  'La ausencia de fila equivale a lock_mode=auto + enforcement=inherit: el '
  'estado se deriva solo de memberships.billing_status y businesses.status.';

comment on column public.business_access_control.lock_mode is
  'auto | forced_locked (corte manual) | forced_open (prórroga/whitelist). '
  'forced_locked y forced_open son mutuamente excluyentes por construcción: '
  'admin_set_business_access limpia el uno al setear el otro.';

create index if not exists idx_business_access_control_scheduled
  on public.business_access_control(scheduled_lock_at)
  where scheduled_lock_at is not null;

create index if not exists idx_business_access_control_forced
  on public.business_access_control(lock_mode)
  where lock_mode <> 'auto';

-- ---------------------------------------------------------------------------
-- 3) Motor de estado — fn_business_access_state(business_id) → jsonb
--
--    Precedencia (de mayor a menor):
--      1. prórroga vigente (forced_open + override_until futuro)  → no bloquea
--      2. corte manual (forced_locked)                            → locked
--      3. businesses.status = 'inactive'                          → locked
--      4. billing_status suspended / cancelled                    → locked
--      5. corte programado ya vencido                             → locked
--      6. past_due  → gracia; vencida la gracia                   → locked
--      7. corte programado a futuro                               → warning
--      8. trial vencido (si lock_on_trial_expired)                → gracia/locked
--      9. resto                                                   → ok
--
--    SECURITY DEFINER porque lee memberships/businesses/plans, tablas con RLS
--    de tenant. El gate de autorización lo pone quien la llama (el RPC del POS
--    valida membresía; los RPC del panel validan is_platform_operator).
-- ---------------------------------------------------------------------------
create or replace function public.fn_business_access_state(
  p_business_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_biz         public.businesses%rowtype;
  v_ac          public.business_access_control%rowtype;
  v_pol         public.platform_access_policy%rowtype;
  v_m           record;
  v_state       text := 'ok';
  v_reason      text := 'none';
  v_grace_days  integer;
  v_grace_ends  timestamptz;
  v_locked_at   timestamptz;
  v_enforced    boolean;
  v_due_from    date;
  v_message     text;
begin
  select * into v_biz from public.businesses where id = p_business_id;
  if v_biz.id is null then
    return null;
  end if;

  select * into v_pol from public.platform_access_policy where id = true;
  select * into v_ac  from public.business_access_control where business_id = p_business_id;

  -- Membresía ancla de billing + plan.
  select m.id            as membership_id,
         m.billing_status,
         m.trial_ends_at,
         m.next_billing_date,
         m.current_period_end,
         m.current_attempt_number,
         m.suspended_at,
         p.name           as plan_name,
         p.price_cents_monthly,
         p.currency_code
    into v_m
    from public.memberships m
    left join public.plans p on p.id = m.plan_id
   where m.business_id = p_business_id
     and m.is_billing_anchor = true
   limit 1;

  v_grace_days := coalesce(v_ac.grace_days, v_pol.default_grace_days, 5);

  -- ---- Precedencia -------------------------------------------------------
  if v_ac.lock_mode = 'forced_open'
     and (v_ac.override_until is null or v_ac.override_until > now()) then
    -- Prórroga concedida: nunca bloquea mientras esté vigente. Avisamos si
    -- tiene fecha de vencimiento para que el dueño sepa que es temporal.
    if v_ac.override_until is not null then
      v_state  := 'warning';
      v_reason := 'extension_granted';
      v_grace_ends := v_ac.override_until;
    end if;

  elsif v_ac.lock_mode = 'forced_locked' then
    v_state    := 'locked';
    v_reason   := 'manual_lock';
    v_locked_at := coalesce(v_ac.locked_at, v_ac.updated_at);

  elsif v_biz.status = 'inactive' then
    v_state  := 'locked';
    v_reason := 'account_inactive';
    v_locked_at := v_biz.updated_at;

  elsif v_m.billing_status = 'suspended' then
    v_state  := 'locked';
    v_reason := 'subscription_suspended';
    v_locked_at := v_m.suspended_at;

  elsif v_m.billing_status = 'cancelled' then
    v_state  := 'locked';
    v_reason := 'subscription_cancelled';

  elsif v_ac.scheduled_lock_at is not null and v_ac.scheduled_lock_at <= now() then
    v_state  := 'locked';
    v_reason := 'scheduled_cutoff';
    v_locked_at := v_ac.scheduled_lock_at;

  elsif v_m.billing_status = 'past_due' and coalesce(v_pol.lock_on_past_due, true) then
    -- La gracia corre desde la fecha que se debía cobrar.
    v_due_from := coalesce(v_m.next_billing_date, v_m.current_period_end, current_date);
    v_grace_ends := (v_due_from::timestamptz + make_interval(days => v_grace_days));
    v_reason := 'payment_overdue';
    if now() >= v_grace_ends then
      v_state := 'locked';
      v_locked_at := v_grace_ends;
    else
      v_state := 'grace';
    end if;

  elsif v_ac.scheduled_lock_at is not null and v_ac.scheduled_lock_at > now() then
    v_state  := 'warning';
    v_reason := 'scheduled_cutoff';
    v_grace_ends := v_ac.scheduled_lock_at;

  elsif v_m.billing_status = 'trial'
        and v_m.trial_ends_at is not null
        and coalesce(v_pol.lock_on_trial_expired, false) then
    v_grace_ends := v_m.trial_ends_at + make_interval(days => v_grace_days);
    if now() >= v_grace_ends then
      v_state  := 'locked';
      v_reason := 'trial_expired';
      v_locked_at := v_grace_ends;
    elsif now() >= v_m.trial_ends_at then
      v_state  := 'grace';
      v_reason := 'trial_expired';
    end if;
  end if;

  -- ---- ¿Se aplica realmente? --------------------------------------------
  v_enforced := case coalesce(v_ac.enforcement, 'inherit')
                  when 'on'  then true
                  when 'off' then false
                  else coalesce(v_pol.enforcement_enabled, false)
                end;

  v_message := nullif(trim(coalesce(v_ac.customer_message, '')), '');
  if v_message is null and v_state in ('grace', 'locked') then
    v_message := nullif(trim(coalesce(v_pol.default_customer_message, '')), '');
  end if;

  return jsonb_build_object(
    'business_id',        p_business_id,
    'state',              v_state,
    'reason',             v_reason,
    'enforced',           v_enforced,
    'enforcement',        coalesce(v_ac.enforcement, 'inherit'),
    'lock_mode',          coalesce(v_ac.lock_mode, 'auto'),
    'locked_at',          v_locked_at,
    'grace_ends_at',      v_grace_ends,
    'grace_days',         v_grace_days,
    'scheduled_lock_at',  v_ac.scheduled_lock_at,
    'override_until',     v_ac.override_until,
    'customer_message',   v_message,
    'lock_reason',        v_ac.lock_reason,
    'contact_name',       coalesce(nullif(trim(coalesce(v_ac.contact_name, '')), ''), v_pol.contact_name),
    'contact_phone',      coalesce(nullif(trim(coalesce(v_ac.contact_phone, '')), ''), v_pol.contact_phone),
    'contact_email',      v_pol.contact_email,
    'offline_max_days',   coalesce(v_pol.offline_max_days, 7),
    'business_status',    v_biz.status,
    'billing_status',     v_m.billing_status,
    'plan_name',          v_m.plan_name,
    'amount_cents',       v_m.price_cents_monthly,
    'currency_code',      v_m.currency_code,
    'next_billing_date',  v_m.next_billing_date,
    'trial_ends_at',      v_m.trial_ends_at,
    'attempt_number',     coalesce(v_m.current_attempt_number, 0),
    'checked_at',         now()
  );
end;
$$;

comment on function public.fn_business_access_state(uuid) is
  'Estado de acceso al POS de un negocio (ok|warning|grace|locked) + el motivo, '
  'consolidando billing_status, businesses.status y los controles manuales del '
  'operador. `enforced` indica si el POS debe aplicarlo. NO autoriza: quien la '
  'llama debe validar membresía o is_platform_operator().';

-- ---------------------------------------------------------------------------
-- 4) RPC del POS — get_my_business_access(business_id)
--    Gateada por membresía real del usuario sobre ese negocio.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_business_access(
  p_business_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.memberships m
     where m.business_id = p_business_id
       and m.user_id = auth.uid()
  ) and not exists (
    select 1 from public.businesses b
     where b.id = p_business_id
       and b.owner_id = auth.uid()
  ) and not public.is_platform_operator() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  return public.fn_business_access_state(p_business_id);
end;
$$;

comment on function public.get_my_business_access(uuid) is
  'Estado de acceso al POS del negocio para el usuario autenticado. El POS lo '
  'llama al arrancar y al reconectar; cachea el resultado para operar offline.';

grant execute on function public.get_my_business_access(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) RLS — las tablas de control solo las tocan operadores.
--    El POS jamás lee estas tablas directo: pasa por el RPC de arriba.
-- ---------------------------------------------------------------------------
alter table public.platform_access_policy  enable row level security;
alter table public.business_access_control enable row level security;

drop policy if exists "platform_access_policy operators all" on public.platform_access_policy;
create policy "platform_access_policy operators all"
  on public.platform_access_policy
  for all
  to authenticated
  using (public.is_platform_operator())
  with check (public.is_platform_operator());

drop policy if exists "business_access_control operators all" on public.business_access_control;
create policy "business_access_control operators all"
  on public.business_access_control
  for all
  to authenticated
  using (public.is_platform_operator())
  with check (public.is_platform_operator());

-- Realtime: el POS se suscribe para que el desbloqueo desde el panel se sienta
-- inmediato. Solo publica el cambio; el contenido sigue viniendo del RPC.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.business_access_control;
    exception when duplicate_object then
      null;
    end;
  end if;
end;
$$;
