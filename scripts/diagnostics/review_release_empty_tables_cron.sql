-- =============================================================================
-- ¿Está corriendo el barrido automático de mesas/ventas vacías? (SOLO LECTURA)
-- =============================================================================
-- El job 'release_empty_tables' (20260608_0003) corre cada 15 min
-- `select public.fn_release_empty_tables(20)`: anula las ventas rápidas sin
-- productos de más de 20 min y libera su carril. Si los carriles se llenan de
-- ventas vacías, este job no está corriendo o está fallando.
--
-- Una sola tabla. Si sale la fila «NO EXISTE», el job no está agendado.
-- Si da «relation cron.job does not exist», pg_cron no está instalado.
-- Hora en República Dominicana.
-- =============================================================================
select j.jobid,
       j.jobname,
       j.schedule,
       j.command,
       j.active as activo,
       j.database as base,
       j.username as usuario,
       to_char(r.ultima_corrida at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as ultima_corrida,
       r.ultimo_estado,
       left(r.ultimo_mensaje, 300) as ultimo_mensaje,
       r.ok_24h,
       r.fallas_24h,
       left(r.ultimo_error, 300) as ultimo_error
  from cron.job j
  left join lateral (
    select (select d.start_time from cron.job_run_details d
             where d.jobid = j.jobid order by d.start_time desc limit 1) as ultima_corrida,
           (select d.status from cron.job_run_details d
             where d.jobid = j.jobid order by d.start_time desc limit 1) as ultimo_estado,
           (select d.return_message from cron.job_run_details d
             where d.jobid = j.jobid order by d.start_time desc limit 1) as ultimo_mensaje,
           (select count(*) from cron.job_run_details d
             where d.jobid = j.jobid and d.start_time > now() - interval '24 hours'
               and d.status = 'succeeded') as ok_24h,
           (select count(*) from cron.job_run_details d
             where d.jobid = j.jobid and d.start_time > now() - interval '24 hours'
               and d.status = 'failed') as fallas_24h,
           (select d.return_message from cron.job_run_details d
             where d.jobid = j.jobid and d.status = 'failed'
             order by d.start_time desc limit 1) as ultimo_error
  ) r on true
 where j.jobname = 'release_empty_tables'
    or j.command ilike '%release_empty_table%'
union all
select null, 'NO EXISTE el job release_empty_tables', null, null, null, null, null,
       null, null, null, null, null, null
 where not exists (
   select 1 from cron.job j
    where j.jobname = 'release_empty_tables'
       or j.command ilike '%release_empty_table%'
 );
