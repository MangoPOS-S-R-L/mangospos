-- =============================================================================
-- El Nido: mesas vacías que siguen abiertas (SOLO LECTURA) — 2026-10-16
-- =============================================================================
-- Una mesa abierta sin productos debe liberarse por dos vías:
--   1. al SALIR de la mesa (fn_release_empty_table, al instante);
--   2. el BARRIDO fn_release_empty_tables: el cron cada 15 min y cada carga del
--      salón; mesas de salón con más de 30 min (20261010_0021).
-- El salón pinta «ocupada» toda mesa con sesión abierta y una cuenta, aunque
-- esté vacía: si las dos vías fallan, la mesa queda naranja con RD$0.
--
-- Una sola tabla (el SQL Editor solo muestra el último resultado):
--   1 NEGOCIO     negocios que coinciden con «nido» (confirmar que es el correcto)
--   2 MESA        cada mesa con sesión abierta y por qué sigue abierta
--   3 BARRIDO     estado del job de pg_cron y su último error
--   4 SALIDAS 7d  mesas vacías liberadas la última semana, por tiempo que tardaron
--   5 EQUIPO      equipos activos del negocio con su versión de la app
-- Hora en República Dominicana.
-- =============================================================================
with biz as (
  select b.id,
         b.business_name || coalesce(' · ' || nullif(btrim(b.branch_name), ''), '') as name
    from public.businesses b
   where b.business_name ilike '%nido%'
      or b.branch_name ilike '%nido%'
),
ses as (
  select ts.id,
         ts.opened_at,
         ts.origin::text as origen,
         ts.precheck_printed_at,
         ts.customer_name,
         dt.code as mesa,
         z.name as zona,
         biz.name as negocio,
         (extract(epoch from now() - ts.opened_at) / 60)::int as minutos,
         case when ts.origin::text = 'dine_in' then 30 else 20 end as umbral
    from public.table_sessions ts
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
    join biz on biz.id = coalesce(ts.business_id, z.business_id)
   where ts.closed_at is null
),
ord as (
  select o.session_id,
         o.id,
         o.status_ext::text as estado,
         (o.closed_at is null and o.status_ext::text not in ('paid', 'void')) as viva,
         o.created_at,
         to_jsonb(o) ->> 'review_reason' as revision,
         it.vivos,
         it.por_confirmar,
         it.pagados,
         it.anulados,
         it.total_vivo,
         coalesce((select sum(p.amount) from public.payments p
                    where p.order_id = o.id and p.status = 'completed'), 0) as cobrado,
         coalesce((select sum(oc.total) from public.order_checks oc
                    where oc.order_id = o.id and oc.is_closed), 0) as checks_cerrados
    from public.orders o
    cross join lateral (
      select count(*) filter (where oi.status::text not in ('void', 'paid')) as vivos,
             count(*) filter (where oi.status::text = 'draft') as por_confirmar,
             count(*) filter (where oi.status::text = 'paid') as pagados,
             count(*) filter (where oi.status::text = 'void') as anulados,
             coalesce(sum(oi.total) filter (where oi.status::text not in ('void', 'paid')), 0) as total_vivo
        from public.order_items oi
       where oi.order_id = o.id
    ) it
   where o.session_id in (select id from ses)
),
mesa as (
  select s.*, a.*
    from ses s
    cross join lateral (
      select count(*) as cuentas,
             count(*) filter (where o.viva) as cuentas_vivas,
             count(*) filter (where o.viva and o.revision is not null) as en_revision,
             coalesce(sum(o.vivos) filter (where o.viva), 0) as vivos,
             coalesce(sum(o.por_confirmar) filter (where o.viva), 0) as por_confirmar,
             coalesce(sum(o.total_vivo) filter (where o.viva), 0) as total_vivo,
             coalesce(bool_or(o.viva and o.vivos = 0 and o.pagados > 0
                              and not (o.cobrado > 0 and o.checks_cerrados > 0
                                       and o.cobrado >= o.checks_cerrados - 1)), false)
               as pagado_sin_cobertura,
             jsonb_agg(jsonb_build_object(
               'cuenta', left(o.id::text, 8),
               'estado', o.estado,
               'viva', o.viva,
               'creada', to_char(o.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
               'productos_vivos', o.vivos,
               'por_confirmar', o.por_confirmar,
               'pagados', o.pagados,
               'anulados', o.anulados,
               'total_vivo', o.total_vivo,
               'cobrado', o.cobrado,
               'revision', o.revision
             ) order by o.created_at) as detalle_cuentas
        from ord o
       where o.session_id = s.id
    ) a
),
salidas as (
  select coalesce(ts.business_id, z.business_id) as business_id,
         extract(epoch from ts.closed_at - ts.opened_at) / 60 as min_abierta
    from public.table_sessions ts
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
   where coalesce(ts.business_id, z.business_id) in (select id from biz)
     and ts.origin::text = 'dine_in'
     and ts.closed_at > now() - interval '7 days'
     and exists (select 1 from public.orders o where o.session_id = ts.id)
     and not exists (select 1 from public.orders o
                      where o.session_id = ts.id and o.status_ext::text <> 'void')
     and not exists (select 1 from public.order_items oi
                       join public.orders o on o.id = oi.order_id
                      where o.session_id = ts.id and oi.status::text <> 'void')
)
select n, seccion, negocio, mesa, cuando, minutos, veredicto, detalle
  from (
    -- 1. Negocios
    select 1 as n, 'NEGOCIO' as seccion, b.name as negocio, null::text as mesa,
           null::text as cuando, null::int as minutos,
           'Coincide con «nido»: confirmar que es El Nido' as veredicto,
           jsonb_build_object('business_id', b.id) as detalle
      from biz b

    union all

    -- 2. Mesas con sesión abierta
    select 2, 'MESA', m.negocio, coalesce(m.zona || ' · ', '') || m.mesa,
           to_char(m.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           m.minutos,
           case
             when m.en_revision > 0
               then 'Cuenta en revisión: no se libera sola; resolverla (Unir/Anular)'
             when m.vivos > 0 and m.vivos = m.por_confirmar
               then 'NO está vacía: tiene ' || m.vivos || ' producto(s) POR CONFIRMAR (sin enviar a cocina)'
             when m.vivos > 0 and m.total_vivo = 0
               then 'NO está vacía: tiene ' || m.vivos || ' producto(s) en RD$0'
             when m.vivos > 0
               then 'Tiene productos (RD$' || m.total_vivo || '): está en uso'
             when m.pagado_sin_cobertura
               then 'Productos marcados pagados SIN cobro que los cubra: el barrido no la toca (revisar)'
             when m.cuentas = 0
               then 'Sesión sin cuentas: el salón ya la pinta libre; la cierra el barrido'
             when m.minutos < m.umbral + 15
               then 'Vacía y reciente: aún en plazo (salida o barrido a los ' || m.umbral || ' min)'
             when m.cuentas_vivas = 0
               then 'VACÍA, sin cuentas vivas, hace ' || m.minutos || ' min: el barrido debió cerrarla y NO lo hizo'
             else 'VACÍA hace ' || m.minutos || ' min: el barrido debió liberarla y NO lo hizo'
           end,
           jsonb_build_object(
             'session_id', m.id,
             'origen', m.origen,
             'precuenta', m.precheck_printed_at is not null,
             'cliente', m.customer_name,
             'cuentas', m.cuentas,
             'cuentas_vivas', m.cuentas_vivas,
             'detalle_cuentas', m.detalle_cuentas
           )
      from mesa m

    union all

    -- 3. Job de pg_cron del barrido
    select 3, 'BARRIDO', null, j.jobname,
           to_char(r.ultima at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           (extract(epoch from now() - r.ultima) / 60)::int,
           case
             when not j.active then 'Job DESACTIVADO'
             when r.ultima is null then 'Job sin ninguna corrida registrada'
             when r.ultimo_estado <> 'succeeded' then 'Última corrida FALLÓ: ' || left(coalesce(r.ultimo_mensaje, ''), 200)
             when r.ultima < now() - interval '30 minutes' then 'Job NO corre hace más de 30 min'
             else 'Corre bien (' || r.ok_24h || ' ok / ' || r.fallas_24h || ' fallas en 24 h)'
           end,
           jsonb_build_object(
             'jobid', j.jobid, 'schedule', j.schedule, 'command', j.command,
             'activo', j.active, 'ultimo_estado', r.ultimo_estado,
             'ultimo_mensaje', left(r.ultimo_mensaje, 300),
             'ok_24h', r.ok_24h, 'fallas_24h', r.fallas_24h,
             'ultimo_error', left(r.ultimo_error, 300),
             'ultimo_error_cuando',
               to_char(r.ultimo_error_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'))
      from cron.job j
      cross join lateral (
        select (select d.start_time from cron.job_run_details d
                 where d.jobid = j.jobid order by d.start_time desc limit 1) as ultima,
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
                 order by d.start_time desc limit 1) as ultimo_error,
               (select d.start_time from cron.job_run_details d
                 where d.jobid = j.jobid and d.status = 'failed'
                 order by d.start_time desc limit 1) as ultimo_error_at
      ) r
     where j.jobname = 'release_empty_tables'
        or j.command ilike '%release_empty_table%'

    union all

    select 3, 'BARRIDO', null, null, null, null,
           'NO EXISTE el job release_empty_tables: nada barre las mesas vacías',
           null
     where not exists (select 1 from cron.job j
                        where j.jobname = 'release_empty_tables'
                           or j.command ilike '%release_empty_table%')

    union all

    -- 4. Mesas vacías liberadas en 7 días, según cuánto tardaron
    select 4, 'SALIDAS 7d', b.name, x.tramo, null, x.cuantas::int,
           x.lectura, null
      from biz b
      cross join lateral (
        select t.tramo, t.lectura,
               (select count(*) from salidas s
                 where s.business_id = b.id
                   and s.min_abierta >= t.desde and s.min_abierta < t.hasta) as cuantas
          from (values
            ('a) cierre con hora vieja', -100000::numeric, 0::numeric,
             'cerrada con hora local: equipo con app MUY vieja'),
            ('b) < 2 min', 0, 2, 'se liberó al salir de la mesa'),
            ('c) 2–29 min', 2, 30, 'se liberó al salir, tras un rato dentro'),
            ('d) 30–59 min', 30, 60, 'la liberó el barrido'),
            ('e) 60 min o más', 60, 100000000, 'tardó: ni la salida ni el barrido a tiempo')
          ) as t(tramo, desde, hasta, lectura)
      ) x

    union all

    -- 5. Equipos activos (3 días) con su versión
    select 5, 'EQUIPO', b.name,
           coalesce(d.device_name, d.hostname, d.label, left(d.device_id, 12)),
           to_char(d.last_seen_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           (extract(epoch from now() - d.last_seen_at) / 60)::int,
           coalesce(d.app_version, '¿?') || ' · ' || coalesce(d.platform, '¿?'),
           jsonb_build_object('usuario', coalesce(d.employee_name, d.user_name, d.user_email),
                              'conectado_desde',
                              to_char(d.signed_in_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
                              'cerro_sesion', d.signed_out_at is not null)
      from public.device_sessions d
      join biz b on b.id = d.business_id
     where d.last_seen_at > now() - interval '3 days'
       and d.revoked_at is null
  ) q
 order by n, negocio nulls first, case when n = 4 then mesa end nulls first,
          minutos desc nulls last, mesa;
