-- ═══════════════════════════════════════════════════════════════════════════════
-- ¿Por qué NO salió el archivo de un día? (negocio 6e18428f…)
-- Ajusta la fecha del bloque 1 y del bloque 7 al día que falta.
--
-- ANTES DE CULPAR A NADA: si son entre medianoche y `send_hour_local` (1:00 AM
-- por defecto), el día de AYER todavía no toca — no es una falla.
-- Correr en Supabase Studio → SQL Editor. Bloques independientes.
--
-- Lectura rápida:
--  · Bloque 1 CON filas ok=false  → sí intentó y falló: el `error` dice por qué
--    (SFTP caído, credenciales, timeout). El cron horario debió reintentar, así
--    que si hay muchas filas, el problema es del lado de la plaza/SFTP.
--  · Bloque 1 VACÍO → nunca intentó: la culpa está en el cron (bloques 3/4/5),
--    en `enabled` o en `send_hour_local` (bloque 2).
-- ═══════════════════════════════════════════════════════════════════════════════

-- 1) Intentos para el día 30 (y el 29 de referencia, que sí salió)
select (created_at at time zone 'America/Santo_Domingo') as intento_local,
       file_date, file_name, row_count as horas, bytes, ok, source, error
  from public.mall_sales_export_log
 where business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid
   and file_date >= date '2026-08-29'
 order by created_at desc;

-- 2) ¿Sigue habilitado y a qué hora local le toca? (+ hora actual del server)
select c.enabled,
       c.send_on_cash_close,
       c.send_hour_local,
       (now() at time zone 'America/Santo_Domingo') as ahora_local,
       (c.last_sent_at at time zone 'America/Santo_Domingo') as last_sent_local,
       c.last_error,
       c.client_code, c.host, c.username, c.remote_dir, c.file_prefix
  from public.business_sales_export_config c
 where c.business_id = '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid;

-- 3) Último intento de CUALQUIER negocio (¿el cron sigue vivo en general?)
select business_id,
       (max(created_at) at time zone 'America/Santo_Domingo') as ultimo_intento_local,
       count(*) as intentos
  from public.mall_sales_export_log
 group by business_id
 order by 2 desc;

-- 4) El cron: ¿agendado y activo? ¿qué devolvieron las últimas vueltas?
select jobid, jobname, schedule, active
  from cron.job
 where jobname = 'mall_sales_export_daily';

select (start_time at time zone 'America/Santo_Domingo') as corrida_local,
       status, return_message
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'mall_sales_export_daily')
 order by start_time desc
 limit 24;

-- 5) ¿La config del disparador sigue cargada? (sin ella el cron no hace nada)
select id, functions_base_url, left(service_role_key, 6) || '…' as key_prefijo, updated_at
  from private.mall_export_cron_config;

-- 6) Respuestas HTTP de pg_net de las últimas horas (si la Edge Function murió,
--    el error real está acá, no en la bitácora).
select (created at time zone 'America/Santo_Domingo') as respuesta_local,
       status_code, timed_out, error_msg, left(content, 300) as content
  from net._http_response
 where created > now() - interval '12 hours'
 order by created desc
 limit 20;

-- 7) ¿Hubo ventas el 30? (si dio 0 filas, el archivo iría vacío igual)
select * from public.fn_mall_sales_by_hour(
  '6e18428f-fdd6-4c58-af0e-dae2403fbf1d'::uuid, date '2026-08-30');
