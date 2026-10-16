-- =============================================================================
-- La Penda: carriles de venta rápida llenos otra vez (SOLO LECTURA) — 2026-10-16
-- =============================================================================
-- Cada venta rápida ocupa un carril ('quick', 'quick#2'… hasta 50). Con 50
-- abiertas no se puede abrir otra («no hay carril libre»).
--
-- Hasta el 16-oct la T02 (20261010_0030) impedía al barrido liberar ventas
-- vacías en todos los negocios; ya se revirtió. Esta consulta dice si lo que
-- llena los carriles HOY son ventas vacías (las libera el barrido a los 20 min)
-- o ventas con productos, que el barrido nunca toca.
--
-- Una sola tabla:
--   1 RESUMEN  por negocio: carriles abiertos de 50 y cuántos de cada clase
--   2 CARRIL   cada venta abierta, su clase, productos y monto
--   3 BARRIDO  estado del cron release_empty_tables
--   4 EQUIPO   equipos activos (3 días) con su versión de la app
-- Clases:
--   vacía                sin productos ni cobros (la libera el barrido)
--   por confirmar        solo productos sin enviar: carrito abandonado
--   enviada sin cobrar   productos ya en cocina y sin cobro: COBRAR o anular
--   con cobros           cobro o productos pagados pero la venta sigue abierta
--   en revisión          cuenta en revisión (llegó tarde de otro equipo)
-- Hora en República Dominicana.
-- =============================================================================
with biz as (
  select b.id,
         b.business_name || coalesce(' · ' || nullif(btrim(b.branch_name), ''), '') as negocio
    from public.businesses b
   where b.business_name ilike '%penda%'
      or b.branch_name ilike '%penda%'
),
ventas as (
  select biz.id as business_id,
         biz.negocio,
         dt.code as carril,
         o.id as order_id,
         o.created_at,
         (extract(epoch from now() - o.created_at) / 60)::int as minutos,
         to_jsonb(o) ->> 'review_reason' as revision,
         it.vivos, it.por_confirmar, it.enviados, it.pagados, it.monto, it.productos,
         exists (select 1 from public.payments p
                  where p.order_id = o.id
                    and p.status in ('pending', 'completed')) as con_cobros
    from biz
    join public.zones z on z.business_id = biz.id
    join public.dining_tables dt on dt.zone_id = z.id
    join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
    join public.orders o on o.session_id = ts.id
    cross join lateral (
      select count(*) filter (where oi.status::text <> 'void') as vivos,
             count(*) filter (where oi.status::text = 'draft') as por_confirmar,
             count(*) filter (where oi.status::text not in ('void', 'draft', 'paid')) as enviados,
             count(*) filter (where oi.status::text = 'paid') as pagados,
             coalesce(sum(oi.total) filter (where oi.status::text <> 'void'), 0) as monto,
             string_agg(oi.product_name, ', ' order by oi.created_at)
               filter (where oi.status::text <> 'void') as productos
        from public.order_items oi
       where oi.order_id = o.id
    ) it
   where z.name in ('Ventas rapidas', 'Ventas manuales')
     and dt.code ~ '^(quick|manual)(#[0-9]+)?$'
     and o.closed_at is null
     and o.status_ext::text not in ('paid', 'void')
),
clasif as (
  select v.*,
         case
           when v.revision is not null then 'en revisión'
           when v.con_cobros or v.pagados > 0 then 'con cobros'
           when v.enviados > 0 then 'enviada sin cobrar'
           when v.vivos > 0 then 'por confirmar'
           else 'vacía'
         end as clase
    from ventas v
)
select n, seccion, negocio, carril, desde, minutos, clase, productos, monto, detalle
  from (
    -- 1. Resumen por negocio
    select 1 as n, 'RESUMEN' as seccion, b.negocio, null::text as carril, null::text as desde,
           null::int as minutos,
           count(c.order_id) || ' de 50 carriles'
             || case when count(c.order_id) >= 50 then ' — LLENO' else '' end as clase,
           'vacías: ' || count(*) filter (where c.clase = 'vacía')
             || ' (más de 35 min: ' || count(*) filter (where c.clase = 'vacía' and c.minutos > 35) || ')'
             || ' · por confirmar: ' || count(*) filter (where c.clase = 'por confirmar')
             || ' · enviadas sin cobrar: ' || count(*) filter (where c.clase = 'enviada sin cobrar')
             || ' · con cobros: ' || count(*) filter (where c.clase = 'con cobros')
             || ' · en revisión: ' || count(*) filter (where c.clase = 'en revisión') as productos,
           coalesce(sum(c.monto), 0) as monto,
           jsonb_build_object(
             'mas_vieja', to_char(min(c.created_at) at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
             'mas_reciente', to_char(max(c.created_at) at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
             'business_id', b.id) as detalle
      from biz b
      left join clasif c on c.business_id = b.id
     group by b.id, b.negocio

    union all

    -- 2. Cada venta abierta en un carril
    select 2, 'CARRIL', c.negocio, c.carril,
           to_char(c.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           c.minutos,
           case when c.clase = 'vacía' and c.minutos > 35
                then 'vacía — el barrido debió liberarla' else c.clase end,
           c.productos, c.monto,
           jsonb_build_object('cuenta', left(c.order_id::text, 8),
                              'por_confirmar', c.por_confirmar,
                              'enviados', c.enviados,
                              'pagados', c.pagados,
                              'con_cobros', c.con_cobros,
                              'revision', c.revision)
      from clasif c

    union all

    -- 3. Cron del barrido
    select 3, 'BARRIDO', null, j.jobname,
           to_char(r.ultima at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           (extract(epoch from now() - r.ultima) / 60)::int,
           case
             when not j.active then 'DESACTIVADO'
             when r.ultimo_estado <> 'succeeded' then 'última corrida FALLÓ'
             when r.ultima < now() - interval '30 minutes' then 'NO corre hace más de 30 min'
             else 'corre bien'
           end,
           left(r.ultimo_mensaje, 200), null,
           jsonb_build_object('command', j.command, 'ok_24h', r.ok_24h, 'fallas_24h', r.fallas_24h)
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
                   and d.status = 'failed') as fallas_24h
      ) r
     where j.jobname = 'release_empty_tables'
        or j.command ilike '%release_empty_table%'

    union all

    -- 4. Equipos activos con su versión
    select 4, 'EQUIPO', b.negocio,
           coalesce(d.device_name, d.hostname, d.label, left(d.device_id, 12)),
           to_char(d.last_seen_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           (extract(epoch from now() - d.last_seen_at) / 60)::int,
           coalesce(d.app_version, '¿?') || ' · ' || coalesce(d.platform, '¿?'),
           coalesce(d.employee_name, d.user_name, d.user_email), null, null
      from public.device_sessions d
      join biz b on b.id = d.business_id
     where d.last_seen_at > now() - interval '3 days'
       and d.revoked_at is null
  ) q
 order by n, negocio nulls first, minutos desc nulls last, carril;
