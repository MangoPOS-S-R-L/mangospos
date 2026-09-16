-- =============================================================================
-- 20260915_0006_subscription_price_override.sql
--
-- PRECIO ESPECIAL POR CLIENTE (descuento de suscripción)
--
-- QUÉ RESUELVE
--   El precio de un plan era igual para todos (plans.price_cents_monthly). No
--   había forma de cobrarle a UN cliente un monto distinto —p.ej. Pro a
--   RD$3,000 en vez de RD$4,799— sin bajarle el precio al plan entero.
--
-- DISEÑO
--   Tres columnas en la membresía ANCLA (la fila que cobra el cron):
--     price_override_cents     monto mensual acordado, en centavos.
--     price_override_plan_id   plan para el que se acordó ese monto.
--     price_override_ends_on   último día en que aplica (null = sin vencimiento).
--
--   * AMARRADO AL PLAN. Si el cliente cambia de plan, el precio especial deja
--     de aplicar solo. Sin ese candado, alguien que baja de Pro a Basic
--     (RD$1,500) seguiría pagando los RD$3,000 acordados para Pro.
--
--   * NUNCA POR ENCIMA DE LA LISTA: least(acordado, lista). Si mañana se baja
--     el precio del plan por debajo de lo acordado, el cliente paga la lista.
--     Un descuento no puede terminar encareciendo.
--
--   * UNA SOLA FUNCIÓN decide el precio efectivo, y la usan todos los caminos
--     que mueven dinero: la Edge Function azul-charge-subscription (cobro con
--     tarjeta), generate_membership_invoice (facturas), el MRR, la matriz de
--     facturación de la consola y fn_business_access_state (el monto que ve el
--     dueño en la pantalla de pago atrasado). Dos cálculos paralelos terminan
--     facturando un monto y cobrando otro.
--
--   * DEPENDE de 20260825_0001_business_access_control.sql: redefine
--     fn_business_access_state (sección 5).
--
--   * La RAZÓN del descuento NO vive acá: la app del cliente lee esta fila y la
--     razón es una nota interna ("cliente fundador", "acuerdo con X"). Queda
--     en noc_audit_log, escrita por la RPC admin (mangopos_administrador 0043).
--
-- ORDEN DE DESPLIEGUE (importa — es dinero)
--   1. Esta migración.
--   2. mangopos_administrador/supabase/migrations/0043_subscription_price_override_admin.sql
--   3. Deploy de la Edge Function azul-charge-subscription.
--   No cargar precios especiales hasta terminar el paso 3: la versión anterior
--   de la función sigue cobrando el precio de lista.
--
-- IDEMPOTENTE. ROLLBACK: 20260915_0006_subscription_price_override_ROLLBACK.sql
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columnas
-- ---------------------------------------------------------------------------
alter table public.memberships
  add column if not exists price_override_cents integer,
  -- Sin FK a plans A PROPÓSITO: memberships ya tiene una (plan_id) y una
  -- segunda vuelve AMBIGUO el embed `plan:plans(*)` de PostgREST (PGRST201),
  -- que usan el POS y mango_dashboard. Ver 20260915_0008.
  add column if not exists price_override_plan_id uuid,
  add column if not exists price_override_ends_on date;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'memberships_price_override_positive'
       and conrelid = 'public.memberships'::regclass
  ) then
    alter table public.memberships
      add constraint memberships_price_override_positive
      check (price_override_cents is null or price_override_cents > 0);
  end if;

  -- Monto y plan van juntos: un precio sin plan no sabe a qué aplicar, y un
  -- plan sin precio es basura que confunde a quien lea la fila.
  if not exists (
    select 1 from pg_constraint
     where conname = 'memberships_price_override_pair'
       and conrelid = 'public.memberships'::regclass
  ) then
    alter table public.memberships
      add constraint memberships_price_override_pair
      check ((price_override_cents is null) = (price_override_plan_id is null));
  end if;
end $$;

comment on column public.memberships.price_override_cents is
  'Precio mensual especial acordado con este cliente, en centavos. Solo aplica '
  'mientras plan_id = price_override_plan_id y no haya pasado '
  'price_override_ends_on. Nunca se cobra por encima del precio de lista.';
comment on column public.memberships.price_override_plan_id is
  'Plan para el que se acordó price_override_cents. Si el cliente cambia de '
  'plan, el precio especial deja de aplicar.';
comment on column public.memberships.price_override_ends_on is
  'Último día (inclusive, hora RD) en que aplica el precio especial. '
  'null = sin vencimiento.';

-- ---------------------------------------------------------------------------
-- 2. Precio especial vigente de una membresía en una fecha.
--
--    p_on es la fecha contra la que se evalúa el vencimiento. Quien cobra pasa
--    el INICIO DEL PERÍODO que cobra, no "hoy": un reintento de un pago
--    atrasado no debe perder el descuento del mes al que corresponde.
--    Default: hoy en República Dominicana.
--
--    Devuelve null si no hay precio especial vigente.
-- ---------------------------------------------------------------------------
create or replace function public.subscription_price_override_cents(
  p_membership_id uuid,
  p_on            date default null
) returns integer
language sql
stable
security definer
set search_path = public
as $$
  select least(m.price_override_cents, p.price_cents_monthly)
    from public.memberships m
    join public.plans p on p.id = m.plan_id
   where m.id = p_membership_id
     and m.price_override_cents is not null
     and m.price_override_plan_id = m.plan_id
     and (
       m.price_override_ends_on is null
       or m.price_override_ends_on >= coalesce(
            p_on,
            (now() at time zone 'America/Santo_Domingo')::date
          )
     );
$$;

comment on function public.subscription_price_override_cents(uuid, date) is
  'Precio especial vigente (centavos) de una membresía en p_on, ya acotado al '
  'precio de lista. null si no tiene uno que aplique.';

-- ---------------------------------------------------------------------------
-- 3. Precio efectivo — LA función que decide cuánto se cobra.
--    Precio especial vigente si lo hay; si no, el de lista. null si la
--    membresía no tiene plan.
-- ---------------------------------------------------------------------------
create or replace function public.subscription_effective_price_cents(
  p_membership_id uuid,
  p_on            date default null
) returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
           public.subscription_price_override_cents(m.id, p_on),
           p.price_cents_monthly
         )
    from public.memberships m
    join public.plans p on p.id = m.plan_id
   where m.id = p_membership_id;
$$;

comment on function public.subscription_effective_price_cents(uuid, date) is
  'Monto mensual que se le cobra a una membresía en p_on (centavos): precio '
  'especial vigente o precio de lista. Fuente única para cobros y facturas.';

-- ---------------------------------------------------------------------------
-- 4. Variante por negocio + código de plan.
--    Las facturas manuales y el MRR trabajan con plan_type (texto) y no con la
--    membresía ancla; esto les da el mismo precio especial sin reimplementar
--    la regla. Solo aplica si el plan del ancla es ese código.
-- ---------------------------------------------------------------------------
create or replace function public.business_price_override_cents(
  p_business_id uuid,
  p_plan_code   text,
  p_on          date default null
) returns integer
language sql
stable
security definer
set search_path = public
as $$
  select public.subscription_price_override_cents(m.id, p_on)
    from public.memberships m
    join public.plans p on p.id = m.plan_id
   where m.business_id = p_business_id
     and m.is_billing_anchor = true
     and p.code = p_plan_code
   limit 1;
$$;

comment on function public.business_price_override_cents(uuid, text, date) is
  'Precio especial vigente (centavos) del negocio para el plan p_plan_code, '
  'resuelto sobre su membresía ancla. null si no aplica.';

-- ---------------------------------------------------------------------------
-- 5. fn_business_access_state — idéntica a 20260825_0001 salvo `amount_cents`,
--    que pasa a ser el precio efectivo.
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
    -- Monto EFECTIVO (precio especial incluido). Era el de lista: la pantalla
    -- de pago atrasado le pedía al cliente con descuento más de lo que el
    -- cobro le iba a debitar.
    'amount_cents',       coalesce(
                            public.subscription_effective_price_cents(
                              v_m.membership_id,
                              coalesce(v_m.next_billing_date,
                                       (now() at time zone 'America/Santo_Domingo')::date)
                            ),
                            v_m.price_cents_monthly
                          ),
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
-- 6. Permisos. Estas funciones son security definer y aceptan cualquier id:
--    abiertas a `authenticated`, cualquier usuario podría consultar lo que
--    paga otro negocio. Solo las llama service_role (Edge Function) y las RPC
--    admin (que corren como su owner).
-- ---------------------------------------------------------------------------
revoke all on function public.subscription_price_override_cents(uuid, date) from public, anon, authenticated;
revoke all on function public.subscription_effective_price_cents(uuid, date) from public, anon, authenticated;
revoke all on function public.business_price_override_cents(uuid, text, date) from public, anon, authenticated;

grant execute on function public.subscription_price_override_cents(uuid, date) to service_role;
grant execute on function public.subscription_effective_price_cents(uuid, date) to service_role;
grant execute on function public.business_price_override_cents(uuid, text, date) to service_role;

commit;
