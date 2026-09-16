-- ROLLBACK de 20260915_0007: el cron vuelve a encolar también planes de precio 0.

begin;

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
