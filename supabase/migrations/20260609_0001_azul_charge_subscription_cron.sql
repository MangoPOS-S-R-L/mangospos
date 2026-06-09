-- 20260609_0001_azul_charge_subscription_cron.sql
-- ═══════════════════════════════════════════════════════════════════════════════
-- Fase 6 — Automatización del cobro recurrente Azul.
--
-- Un job diario (pg_cron) busca las suscripciones a cobrar hoy y, por cada una,
-- invoca la Edge Function `azul-charge-subscription` vía pg_net (net.http_post)
-- con el bearer service_role. La Edge Function hace el cobro real (mTLS → Azul) y
-- actualiza memberships/azul_charges. El cron solo "encola".
--
-- Selección de "a cobrar hoy":
--   memberships con is_billing_anchor, billing_status in ('active','past_due'),
--   next_billing_date <= hoy, plan_id no nulo, current_attempt_number < 3, y con
--   una tarjeta default 'verified'. attempt_number = current_attempt_number + 1.
--
-- SECRETO: el service_role key y la URL base de las functions NO se hardcodean.
-- Viven en private.azul_cron_config (RLS denegado a todos; solo la función
-- security-definer y postgres la leen). El usuario debe poblarla una vez:
--
--   insert into private.azul_cron_config (functions_base_url, service_role_key)
--   values ('https://supabase.mangopos.do/functions/v1', '<SERVICE_ROLE_KEY>')
--   on conflict (id) do update
--     set functions_base_url = excluded.functions_base_url,
--         service_role_key   = excluded.service_role_key,
--         updated_at = now();
--
-- (Alternativa más segura si el stack tiene Supabase Vault: guardar el key en
--  vault.secrets y leerlo con vault.decrypted_secrets; aquí usamos la tabla por
--  portabilidad en self-hosted.)
--
-- Idempotente: si no hay pg_net o pg_cron, la migración no falla (solo avisa).
-- ═══════════════════════════════════════════════════════════════════════════════

begin;

create schema if not exists private;

-- Config singleton (una sola fila, id=true).
create table if not exists private.azul_cron_config (
  id boolean primary key default true check (id = true),
  functions_base_url text not null,
  service_role_key text not null,
  updated_at timestamptz not null default now()
);

alter table private.azul_cron_config enable row level security;
revoke all on private.azul_cron_config from anon, authenticated;
-- Sin políticas RLS => nadie (salvo postgres / security definer) puede leerla.

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

-- Agendar diario 07:00 UTC (~3am AST).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'azul_charge_due';
    perform cron.schedule(
      'azul_charge_due',
      '0 7 * * *',
      $cron$select private.fn_azul_run_due_charges()$cron$
    );
  else
    raise notice 'pg_cron no disponible. Agenda manual: select cron.schedule(''azul_charge_due'',''0 7 * * *'',''select private.fn_azul_run_due_charges()'');';
  end if;
exception when insufficient_privilege then
  raise notice 'Sin privilegio para pg_cron; agendar manualmente fn_azul_run_due_charges.';
end $$;

commit;
