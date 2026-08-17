-- ═══════════════════════════════════════════════════════════════════════════════
-- 20260816_0001 — Envío diario automático del reporte de ventas a la plaza
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Hasta ahora el archivo de la plaza se subía SOLO desde la app, en el hook de
-- cierre de caja. Auditoría del SFTP real (2026-08-16) encontró dos fallas:
--
--   1. `sendOnCashClose` usa `DateTime.now()`, así que un cierre después de
--      medianoche sube el archivo del día NUEVO y deja el anterior congelado en
--      el último cierre de la tarde. El 14 y 15-ago la plaza recibió ~1/3 de la
--      venta real: faltaban las horas 18-23, que en días completos (12 y 13-ago)
--      pesaron 64-67% del día.
--   2. El formato del archivo es el del build instalado en la tablet, así que la
--      corrección BRUTO/NETO acordada con la plaza el 13-ago nunca llegó.
--
-- Este migration mueve el envío al servidor, donde ninguna de las dos aplica:
--   1. `public.mall_sales_export_log` — bitácora append-only de cada envío.
--      Antes solo existía `last_sent_at`, que se sobrescribe: no había forma de
--      saber si un día falló salvo entrar al SFTP a mirar a mano.
--   2. `private.mall_export_cron_config` — base URL + service_role (patrón
--      idéntico a private.azul_cron_config de 20260609_0001).
--   3. `private.fn_mall_export_run_daily()` — invoca la Edge Function por pg_net.
--   4. Cron HORARIO. La Edge Function decide: sube el día anterior en hora local
--      del negocio, una vez pasada la 1:00 AM, y se salta los días ya subidos.
--      Correrlo cada hora (en vez de una vez a la 1 AM) da dos cosas gratis:
--      reintento automático si el SFTP estaba caído, e inmunidad a la zona
--      horaria del servidor de Postgres — que es un error fácil de cometer y
--      difícil de notar, porque manda el día equivocado en silencio.
--
-- Sin impacto fiscal: solo lectura de ventas para un reporte externo.
-- Idempotente: si no hay pg_net o pg_cron, la migración no falla (solo avisa).
-- ═══════════════════════════════════════════════════════════════════════════════

begin;

-- 1) Bitácora de envíos ------------------------------------------------------

create table if not exists public.mall_sales_export_log (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  -- Día que contiene el archivo (NO el día en que se subió).
  file_date   date not null,
  file_name   text not null default '',
  bytes       integer not null default 0,
  row_count   integer not null default 0,
  ok          boolean not null default false,
  error       text,
  -- cron | manual | cash_close
  source      text not null default 'cron',
  created_at  timestamptz not null default now()
);

create index if not exists mall_sales_export_log_business_date_idx
  on public.mall_sales_export_log (business_id, file_date desc, created_at desc);

-- Lo consulta la Edge Function (service_role) para no repetir un día ya subido.
create index if not exists mall_sales_export_log_ok_idx
  on public.mall_sales_export_log (business_id, file_date)
  where ok;

alter table public.mall_sales_export_log enable row level security;

-- Mismo criterio que business_sales_export_config: solo owner/admin.
-- Solo lectura — las filas las escribe la Edge Function con service_role.
drop policy if exists mall_export_log_read on public.mall_sales_export_log;
create policy mall_export_log_read on public.mall_sales_export_log
  for select
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner'::text, 'admin'::text])
  );

comment on table public.mall_sales_export_log is
  'Bitácora de envíos del reporte de ventas a la plaza comercial (SFTP). '
  'Append-only: cada intento deja fila, incluidos los fallidos.';

-- 2) Config del cron ---------------------------------------------------------

create schema if not exists private;

create table if not exists private.mall_export_cron_config (
  id                 boolean primary key default true check (id = true),
  functions_base_url text not null,
  service_role_key   text not null,
  updated_at         timestamptz not null default now()
);

alter table private.mall_export_cron_config enable row level security;
revoke all on private.mall_export_cron_config from anon, authenticated;
-- Sin políticas RLS => nadie salvo postgres / security definer puede leerla.

-- 3) Disparador --------------------------------------------------------------

create or replace function private.fn_mall_export_run_daily()
returns boolean
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_cfg private.mall_export_cron_config%rowtype;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net no disponible; el cron no puede invocar la Edge Function.';
    return false;
  end if;

  select * into v_cfg from private.mall_export_cron_config where id = true;
  if not found then
    raise notice 'private.mall_export_cron_config sin configurar; el cron no hace nada.';
    return false;
  end if;

  -- Body vacío = modo cron: la Edge Function recorre todas las configs
  -- habilitadas y resuelve fecha y hora de corte en la TZ de cada negocio.
  perform net.http_post(
    url := rtrim(v_cfg.functions_base_url, '/') || '/mall-sales-export',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_cfg.service_role_key
    ),
    body := '{}'::jsonb
  );
  return true;
end;
$$;

alter function private.fn_mall_export_run_daily() owner to postgres;

-- 4) Agenda ------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'mall_sales_export_daily';
    -- Cada hora en punto. La Edge Function ignora las vueltas en que aún no es
    -- la 1:00 AM local o el día ya se subió, así que el trabajo real ocurre una
    -- vez al día; las demás vueltas son el reintento.
    perform cron.schedule(
      'mall_sales_export_daily',
      '0 * * * *',
      $cron$select private.fn_mall_export_run_daily()$cron$
    );
  else
    raise notice 'pg_cron no disponible. Agenda manual: select cron.schedule(''mall_sales_export_daily'',''0 * * * *'',''select private.fn_mall_export_run_daily()'');';
  end if;
exception when insufficient_privilege then
  raise notice 'Sin privilegio para pg_cron; agendar manualmente fn_mall_export_run_daily.';
end $$;

commit;

-- ═══════════════════════════════════════════════════════════════════════════════
-- POST-MIGRACIÓN (obligatorio, si no el cron no hace nada)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- 1) Cargar la config del cron (misma base URL que usa el cron de Azul):
--
--   insert into private.mall_export_cron_config (id, functions_base_url, service_role_key)
--   values (true, 'https://supabase.mangopos.do/functions/v1', '<SERVICE_ROLE_KEY>')
--   on conflict (id) do update
--     set functions_base_url = excluded.functions_base_url,
--         service_role_key   = excluded.service_role_key,
--         updated_at         = now();
--
-- 2) Apagar el envío desde la app para no tener DOS generadores del mismo
--    archivo. Mientras la tablet siga con el build viejo, cada cierre de caja
--    pisa el archivo del día con la convención BRUTO/NETO equivocada:
--
--   update public.business_sales_export_config
--      set send_on_cash_close = false
--    where enabled = true;
--
-- 3) Probar a mano sin esperar al cron (sube el día anterior de una vez):
--
--   select private.fn_mall_export_run_daily();
--
-- 4) Backfill del 14 y 15 de agosto, que quedaron incompletos en el SFTP
--    (les faltan las horas 18-23). Vía curl contra la Edge Function:
--
--   curl -X POST https://supabase.mangopos.do/functions/v1/mall-sales-export \
--     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
--     -H "Content-Type: application/json" \
--     -d '{"business_id":"6e18428f-fdd6-4c58-af0e-dae2403fbf1d","date":"2026-08-14"}'
--
-- 5) Verificar la bitácora:
--
--   select created_at, file_date, file_name, bytes, row_count, ok, error, source
--     from public.mall_sales_export_log
--    order by created_at desc
--    limit 20;
-- ═══════════════════════════════════════════════════════════════════════════════
