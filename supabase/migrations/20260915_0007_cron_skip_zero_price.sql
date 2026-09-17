-- ===========================================================================
-- 20260915_0007 — El cron de cobro NO encola suscripciones de precio 0
--
-- (Archivo reconstruido el 17/09/2026: en el commit 1df1b8f0 quedó con un
--  solo carácter. Es la función de 20260609_0001 — idéntica a la de su
--  ROLLBACK — más el filtro de precio efectivo.)
--
-- POR QUÉ
-- Con precio especial en 0 o un plan gratis, subscription_effective_price_cents
-- devuelve 0. El cron igual encolaba la suscripción, la Edge Function mandaba
-- una venta de RD$0 que Azul rechaza, la fila quedaba en `error` y al día
-- siguiente se repetía. Caso real: "cristian", un intento de RD$0 todos los
-- días a las 03:00 desde el 24/06/2026 (se vio al correr
-- VERIFICAR_20260917_0004_custom_order_id.sql).
--
-- El precio se evalúa con la MISMA fecha que usa el cobro (next_billing_date),
-- para que el cron y la función decidan igual.
--
-- Segunda barrera: azul-charge-subscription responde 422 zero_amount sin tocar
-- Azul si el precio efectivo es 0.
--
-- DEPENDE de 20260915_0006 (subscription_effective_price_cents).
-- Idempotente. Rollback: 20260915_0007_cron_skip_zero_price_ROLLBACK.sql
-- ===========================================================================

begin;

do $$
begin
  if to_regprocedure('public.subscription_effective_price_cents(uuid,date)') is null then
    raise exception
      'Falta 20260915_0006_subscription_price_override.sql. Aplicarla antes que 0007.';
  end if;
end $$;

create or replace function private.fn_azul_run_due_charges()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_cfg private.azul_cron_config%rowtype;
  v_count int := 0;
  r record;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net no disponible; el cron de cobro no puede invocar la Edge Function.';
    return 0;
  end if;

  select * into v_cfg from private.azul_cron_config where id = true;
  if not found then
    raise notice 'private.azul_cron_config sin configurar; el cron de cobro no hace nada.';
    return 0;
  end if;

  for r in
    select m.id as membership_id,
           coalesce(m.current_attempt_number, 0) + 1 as attempt_number,
           coalesce(m.next_billing_date, current_date)::text as billing_period_start
    from public.memberships m
    where m.is_billing_anchor = true
      and m.billing_status in ('active', 'past_due')
      and m.next_billing_date is not null
      and m.next_billing_date <= current_date
      and m.plan_id is not null
      and coalesce(m.current_attempt_number, 0) < 3
      and exists (
        select 1 from public.azul_payment_methods pm
        where pm.business_id = m.business_id
          and pm.is_default = true
          and pm.status = 'verified'
      )
      -- Nada que cobrar: precio efectivo 0 (o sin precio resoluble) para el
      -- período que se cobraría. Sin esto, Azul rechazaba una venta de RD$0
      -- todos los días.
      and coalesce(
            public.subscription_effective_price_cents(
              m.id, coalesce(m.next_billing_date, current_date)
            ),
            0
          ) > 0
  loop
    perform net.http_post(
      url := rtrim(v_cfg.functions_base_url, '/') || '/azul-charge-subscription',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_cfg.service_role_key
      ),
      body := jsonb_build_object(
        'membership_id', r.membership_id,
        'attempt_number', r.attempt_number,
        'billing_period_start', r.billing_period_start
      )
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

alter function private.fn_azul_run_due_charges() owner to postgres;

commit;
