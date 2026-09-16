-- =============================================================================
-- ROLLBACK de 20260915_0006_subscription_price_override.sql
--
-- ANTES de correr esto:
--   1. Redeploy de la versión anterior de azul-charge-subscription (la nueva
--      llama a subscription_effective_price_cents y, sin ella, NO cobra).
--   2. Re-aplicar en mangopos_administrador las versiones previas de las
--      funciones que 0043 redefinió: 0039 (admin_get_business_billing),
--      0033 (generate_membership_invoice), 0006 (get_billing_metrics) y
--      0042 (admin_billing_matrix), y borrar admin_set/clear_price_override.
--   Si no, esas funciones fallan en tiempo de ejecución.
--
-- Borra los precios especiales cargados. Exportarlos primero si hacen falta:
--   select business_id, price_override_cents, price_override_plan_id,
--          price_override_ends_on
--     from public.memberships where price_override_cents is not null;
-- =============================================================================

begin;

-- fn_business_access_state vuelve a su versión de 20260825_0001 (monto de
-- lista). Va PRIMERO: la versión de 0006 llama a las funciones que se borran
-- abajo y quedaría rota.
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

drop function if exists public.business_price_override_cents(uuid, text, date);
drop function if exists public.subscription_effective_price_cents(uuid, date);
drop function if exists public.subscription_price_override_cents(uuid, date);

alter table public.memberships drop constraint if exists memberships_price_override_pair;
alter table public.memberships drop constraint if exists memberships_price_override_positive;

alter table public.memberships
  drop column if exists price_override_ends_on,
  drop column if exists price_override_plan_id,
  drop column if exists price_override_cents;

commit;
