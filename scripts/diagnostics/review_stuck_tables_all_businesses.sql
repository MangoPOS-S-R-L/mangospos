-- =============================================================================
-- Mesas trabadas en TODOS los negocios (SOLO LECTURA) — 2026-10-16
-- =============================================================================
-- Pedido del dueño: «no es el único negocio, también me pasó en Food Shop de
-- El Encuentro». Generaliza el diagnóstico de El Nido.
--
-- CONTEXTO. Hasta el 16-oct estuvo viva la T02 (20261010_0030) y ni la salida
-- ni el barrido liberaban mesas vacías en ningún negocio. Ya se revirtió: el
-- barrido libera solo las cuentas VACÍAS. Lo que nunca libera son las mesas con
-- cuentas en revisión (productos que llegaron tarde de un equipo con app vieja
-- o sin red): se ven ocupadas en RD$0 y la app vieja no las muestra.
--
-- QUÉ ENTRA. Mesas con sesión abierta cuya cuenta principal no tiene nada
-- enviado a cocina ni cobrado, y que tienen una cuenta en revisión o llevan
-- más de 45 min abiertas.
--
-- «accion» = lo que haría una limpieza con los candados de El Nido:
--   se anularía  revisión con productos TODOS por confirmar, sin cobros y sin
--                nada de las últimas 2 h; o cuenta vacía con más de 30 min
--   decidir      venta con solo productos por confirmar de hace más de 2 h
--   NO se toca   cobros, productos en cocina o actividad reciente
-- «retecleado»: de los productos de una cuenta en revisión, cuántos aparecen
-- cobrados en otra cuenta de la misma mesa ±3 h (duplicados).
--
-- Una sola tabla. Una fila por cuenta viva y una fila MESA por mesa.
-- Hora en República Dominicana.
-- =============================================================================
with ses as (
  select ts.id as session_id,
         ts.table_id,
         ts.opened_at,
         dt.code as mesa,
         b.business_name || coalesce(' · ' || nullif(btrim(b.branch_name), ''), '') as negocio
    from public.table_sessions ts
    join public.dining_tables dt on dt.id = ts.table_id
    join public.zones z on z.id = dt.zone_id
    join public.businesses b on b.id = coalesce(ts.business_id, z.business_id)
   where ts.closed_at is null
     -- La cuenta principal no tiene nada en cocina ni cobrado.
     and not exists (
       select 1
         from public.orders o
         join public.order_items oi on oi.order_id = o.id
        where o.session_id = ts.id
          and o.closed_at is null
          and o.status_ext::text not in ('paid', 'void')
          and to_jsonb(o) ->> 'review_reason' is null
          and oi.status::text not in ('void', 'paid', 'draft'))
     and (
       exists (select 1 from public.orders o
                where o.session_id = ts.id
                  and o.closed_at is null
                  and o.status_ext::text not in ('paid', 'void')
                  and to_jsonb(o) ->> 'review_reason' is not null)
       or ts.opened_at < now() - interval '45 minutes')
),
cuentas as (
  select s.*,
         ord.id as order_id,
         ord.created_at,
         to_jsonb(ord) ->> 'review_reason' as revision,
         it.vivos, it.enviados, it.pagados, it.recientes, it.monto, it.productos,
         exists (select 1 from public.payments p
                  where p.order_id = ord.id
                    and p.status in ('pending', 'completed')) as con_cobros,
         (select count(*)
            from public.order_items ri
           where ri.order_id = ord.id
             and ri.status::text <> 'void'
             and exists (
               select 1
                 from public.table_sessions ts2
                 join public.orders o2 on o2.session_id = ts2.id and o2.id <> ord.id
                 join public.order_items oi2 on oi2.order_id = o2.id
                where ts2.table_id = s.table_id
                  and oi2.product_name = ri.product_name
                  and oi2.status::text <> 'void'
                  and (o2.status_ext::text = 'paid' or oi2.status::text = 'paid')
                  and oi2.created_at between ri.created_at - interval '3 hours'
                                         and ri.created_at + interval '3 hours')) as retecleados
    from ses s
    join public.orders ord
      on ord.session_id = s.session_id
     and ord.closed_at is null
     and ord.status_ext::text not in ('paid', 'void')
    cross join lateral (
      select count(*) filter (where oi.status::text <> 'void') as vivos,
             count(*) filter (where oi.status::text not in ('void', 'draft', 'paid')) as enviados,
             count(*) filter (where oi.status::text = 'paid') as pagados,
             count(*) filter (where oi.status::text <> 'void'
                                and oi.created_at > now() - interval '2 hours') as recientes,
             coalesce(sum(oi.total) filter (where oi.status::text <> 'void'), 0) as monto,
             string_agg(oi.product_name, ', ' order by oi.created_at)
               filter (where oi.status::text <> 'void') as productos
        from public.order_items oi
       where oi.order_id = ord.id
    ) it
),
clasif as (
  select c.*,
         case
           when c.revision is not null then 'revisión (' || c.revision || ')'
           when c.vivos = 0 then 'vacía'
           else 'por confirmar'
         end as tipo,
         case
           when c.con_cobros or c.pagados > 0 then 'NO se toca: tiene cobros'
           when c.enviados > 0 then 'NO se toca: productos enviados a cocina'
           when c.recientes > 0 then 'NO se toca: productos de las últimas 2 h'
           when c.vivos = 0 and c.created_at > now() - interval '30 minutes'
             then 'NO se toca: abierta hace menos de 30 min'
           when c.revision is null and c.vivos > 0
             then 'decidir: venta abandonada'
           else 'se anularía'
         end as accion
    from cuentas c
)
select negocio, mesa, abierta_desde, cuenta, tipo, productos, monto, retecleado, accion
  from (
    select 1 as orden, negocio, mesa,
           to_char(opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI') as abierta_desde,
           left(order_id::text, 8) as cuenta, tipo, productos, monto,
           case when revision is not null and vivos > 0
                then retecleados || ' de ' || vivos end as retecleado,
           accion
      from clasif

    union all

    select 2, s.negocio, s.mesa,
           to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
           null, 'MESA', null, null, null,
           case
             when not exists (select 1 from clasif c where c.session_id = s.session_id)
               then 'sin cuentas vivas: la cierra el barrido'
             when bool_and(c.accion = 'se anularía') then 'quedaría LIBRE'
             when bool_and(c.accion in ('se anularía', 'decidir: venta abandonada'))
               then 'quedaría LIBRE si se anula la venta abandonada'
             else 'seguiría abierta'
           end
      from ses s
      left join clasif c on c.session_id = s.session_id
     group by s.session_id, s.negocio, s.mesa, s.opened_at
  ) q
 order by negocio, mesa, orden, cuenta;
