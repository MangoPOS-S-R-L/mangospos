-- ═══════════════════════════════════════════════════════════════════════════════
-- ¿Se está enviando TODOS LOS DÍAS el archivo de ventas a la plaza (SFTP)?
-- Negocio: 6e18428f-fdd6-4c58-af0e-dae2403fbf1d (LA COCINA MEXICANA AUTENTICA)
--
-- Fuente de verdad: public.mall_sales_export_log (bitácora append-only que
-- escribe la Edge Function `mall-sales-export`; mig 20260816_0001).
-- OJO: `file_date` es el DÍA DE LAS VENTAS, no el día en que se subió.
-- El cron corre cada hora y sube el día anterior pasada la hora local
-- configurada (send_hour_local, default 1:00 AM).
--
-- Correr en Supabase Studio → SQL Editor. Bloques independientes.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── VENTANA ESPERADA ────────────────────────────────────────────────────────
-- El archivo del día N se sube el día N+1 pasada `send_hour_local` (default 1:00
-- AM local). Entre medianoche y esa hora, el día de AYER todavía NO toca: darlo
-- por faltante es un falso positivo (pasó el 2026-08-31 a las 00:48).
-- Por eso el último día exigible se calcula, no se asume.

-- ── A) CALENDARIO DÍA A DÍA (lo que pediste: ¿faltó algún día?) ──────────────
with cfg as (
  select coalesce(send_hour_local, 1) as send_hour
    from public.business_sales_export_config
   where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
),
w as (
  select (now() at time zone 'America/Santo_Domingo')::date
           - case when extract(hour from (now() at time zone 'America/Santo_Domingo'))
                       >= (select send_hour from cfg) then 1 else 2 end as hasta
),
dias as (
  select d::date as file_date
    from generate_series(date '2026-08-11',            -- primer día enviado
                         (select hasta from w),        -- último día YA exigible
                         interval '1 day') d
),
env as (
  select file_date,
         count(*) filter (where ok)                                            as envios_ok,
         count(*) filter (where not ok)                                        as fallos,
         max(created_at) filter (where ok)                                     as subido_at,
         max(bytes)      filter (where ok)                                     as bytes,
         max(row_count)  filter (where ok)                                     as horas,
         (array_agg(source order by created_at desc) filter (where ok))[1]     as origen,
         (array_agg(error  order by created_at desc) filter (where not ok))[1] as ultimo_error
    from public.mall_sales_export_log
   where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
   group by file_date
)
select d.file_date,
       to_char(d.file_date, 'TMDy')                                as dia,
       case when coalesce(e.envios_ok,0) > 0 then '✔ ENVIADO'
            when coalesce(e.fallos,0)    > 0 then '✖ FALLÓ'
            else                                 '— SIN INTENTO' end as estado,
       (e.subido_at at time zone 'America/Santo_Domingo')          as subido_local,
       e.horas,
       e.bytes,
       e.origen,
       e.fallos,
       e.ultimo_error
  from dias d
  left join env e using (file_date)
 order by d.file_date desc;

-- ── B) RESUMEN + LISTA DE DÍAS QUE FALTAN ───────────────────────────────────
with cfg as (
  select coalesce(send_hour_local, 1) as send_hour
    from public.business_sales_export_config
   where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
),
w as (
  select (now() at time zone 'America/Santo_Domingo')::date
           - case when extract(hour from (now() at time zone 'America/Santo_Domingo'))
                       >= (select send_hour from cfg) then 1 else 2 end as hasta
),
dias as (
  select d::date as file_date
    from generate_series(date '2026-08-11', (select hasta from w), interval '1 day') d
),
ok as (
  select distinct file_date
    from public.mall_sales_export_log
   where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
     and ok
)
select (select hasta from w)                                 as ultimo_dia_exigible,
       count(*)                                              as dias_esperados,
       count(ok.file_date)                                   as dias_enviados,
       count(*) - count(ok.file_date)                        as dias_faltantes,
       string_agg(d.file_date::text, ', ' order by d.file_date)
         filter (where ok.file_date is null)                 as faltan
  from dias d
  left join ok using (file_date);

-- ── C) ÚLTIMOS 40 INTENTOS (incluye fallos y reintentos del cron) ────────────
select (created_at at time zone 'America/Santo_Domingo') as intento_local,
       file_date, file_name, row_count as horas, bytes, ok, source, error
  from public.mall_sales_export_log
 where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
 order by created_at desc
 limit 40;

-- ── D) SALUD DEL ENVÍO: config del negocio + colisiones ──────────────────────
-- Regla: dos negocios con mismo host+usuario+remote_dir+file_prefix se PISAN el
-- archivo del día. La fila de prueba "cristian" debe seguir enabled=false.
select c.business_id,
       b.business_name,
       c.enabled,
       c.send_on_cash_close,
       c.client_code,
       c.file_prefix,
       c.send_hour_local,
       c.host, c.username, c.remote_dir,
       (c.last_sent_at at time zone 'America/Santo_Domingo') as last_sent_local,
       c.last_error
  from public.business_sales_export_config c
  left join public.businesses b on b.id = c.business_id
 order by c.enabled desc, b.business_name;

-- ── E) ¿EL CRON ESTÁ VIVO? (requiere permisos sobre cron.*) ──────────────────
select jobid, jobname, schedule, active
  from cron.job
 where jobname = 'mall_sales_export_daily';

select start_time at time zone 'America/Santo_Domingo' as corrida_local,
       status, return_message
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'mall_sales_export_daily')
 order by start_time desc
 limit 24;
