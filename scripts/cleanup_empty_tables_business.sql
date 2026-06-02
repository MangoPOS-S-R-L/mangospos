-- =============================================================================
-- Limpieza de mesas colgadas de un negocio
-- Business: 33207ebd-985d-455c-bdbb-1b38af8b36ea
-- =============================================================================
-- Una mesa queda "colgada" (ocupada/azul) cuando su orden sigue abierta
-- (orders.closed_at is null, status_ext not in paid/void) pero NO tiene items
-- pendientes de cobro. Hay dos variantes:
--
--   a) VACÍA      : la orden no tiene ningún item (mesa abierta y abandonada).
--   b) FANTASMA   : todos los items están 'paid' (y/o 'void') pero la orden y la
--                   sesión nunca se cerraron. Caso típico: split bill donde se
--                   pagó cada check por separado. Ej.: mesa C9.
--
-- "Pendiente de cobro" = item con status que NO es 'void' ni 'paid'.
--
-- USO RECOMENDADO:
--   1) Corre el PASO 0 (solo lectura) y revisa la clasificación.
--   2) Para arreglar SOLO C9, usa el PASO 1.
--   3) Para limpiar TODAS las colgadas del negocio de una, usa el PASO 2.
--
-- Guard de tiempo: 30 min de antigüedad, para no tocar una mesa en uso ahora.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- PASO 0  ·  DIAGNÓSTICO (solo lectura)  — conteos exactos, sin producto cruzado
-- ----------------------------------------------------------------------------
select
  dt.code as mesa,
  round(extract(epoch from (now() - ts.opened_at)) / 3600) as edad_horas,
  o.status_ext,
  (ts.precheck_printed_at is not null) as precuenta,
  (select count(*) from public.order_items oi where oi.order_id = o.id) as items,
  (select count(*) from public.order_items oi
     where oi.order_id = o.id and oi.status = 'paid') as pagados,
  (select count(*) from public.order_items oi
     where oi.order_id = o.id and oi.status not in ('paid', 'void')) as pendientes,
  coalesce((select sum(p.amount) from public.payments p
     where p.order_id = o.id and p.status = 'completed'), 0) as pagos,
  coalesce((select sum(oc.total) from public.order_checks oc
     where oc.order_id = o.id and oc.is_closed), 0) as total_checks_cerrados,
  case
    when (select count(*) from public.order_items oi
            where oi.order_id = o.id and oi.status not in ('paid', 'void')) > 0
      then 'PENDIENTE REAL (no tocar)'
    when not exists (select 1 from public.order_items oi
            where oi.order_id = o.id and oi.status = 'paid')
      then 'VACÍA (cerrar como void)'
    when coalesce((select sum(p.amount) from public.payments p
            where p.order_id = o.id and p.status = 'completed'), 0) > 0
         and coalesce((select sum(oc.total) from public.order_checks oc
            where oc.order_id = o.id and oc.is_closed), 0) > 0
         and coalesce((select sum(p.amount) from public.payments p
            where p.order_id = o.id and p.status = 'completed'), 0)
             >= coalesce((select sum(oc.total) from public.order_checks oc
            where oc.order_id = o.id and oc.is_closed), 0) - 1
      then 'FANTASMA pagado (cerrar como paid)'
    else 'REVISAR: paid sin pago que lo cubra (posible bug fantasma)'
  end as clasificacion
from public.table_sessions ts
join public.orders o
     on o.session_id = ts.id
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void')
left join public.dining_tables dt on dt.id = ts.table_id
where ts.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
  and ts.closed_at is null
order by clasificacion, edad_horas desc;


-- ----------------------------------------------------------------------------
-- PASO 1  ·  ARREGLAR SOLO C9 (recomendado para empezar)
-- ----------------------------------------------------------------------------
-- fn_close_order_and_table cierra la orden con el status dado y, si no quedan
-- otras órdenes abiertas en la sesión, cierra la sesión y libera la mesa.
-- C9 ya está toda pagada -> la cerramos como 'paid' (venta completada).
--
-- select public.fn_close_order_and_table(
--   'af942d37-1c6b-4fc8-8ddf-586ad02327a4'::uuid,  -- order_id de C9
--   'paid'::public.order_status
-- );


-- ----------------------------------------------------------------------------
-- PASO 2  ·  LIMPIAR TODAS LAS COLGADAS DEL NEGOCIO (transacción)
-- ----------------------------------------------------------------------------
-- Cierra toda orden abierta del negocio sin items pendientes de cobro,
-- respetando el status (paid si hubo pagos, void si estaba vacía), cierra la
-- sesión si no quedan órdenes abiertas y libera la mesa. NO toca ventas con
-- items pendientes. Revisa el PASO 0 antes de correr esto.
--
-- begin;
--
-- with candidates as (
--   select o.id,
--          exists (select 1 from public.order_items oi
--                    where oi.order_id = o.id and oi.status = 'paid') as has_paid
--   from public.orders o
--   join public.table_sessions ts on ts.id = o.session_id
--   where ts.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
--     and o.closed_at is null
--     and o.status_ext not in ('paid', 'void')
--     and o.created_at < now() - interval '30 minutes'
--     and not exists (
--       select 1 from public.order_items oi
--       where oi.order_id = o.id and oi.status not in ('void', 'paid')
--     )
-- ),
-- classified as (
--   select c.id, c.has_paid,
--     coalesce((select sum(p.amount) from public.payments p
--       where p.order_id = c.id and p.status = 'completed'), 0) as paid_amount,
--     coalesce((select sum(oc.total) from public.order_checks oc
--       where oc.order_id = c.id and oc.is_closed), 0) as closed_checks_total
--   from candidates c
-- ),
-- to_close as (
--   select id,
--     case
--       when not has_paid then 'void'::public.order_status
--       when paid_amount > 0 and closed_checks_total > 0
--            and paid_amount >= closed_checks_total - 1
--         then 'paid'::public.order_status
--       else null  -- paid sin cobertura: NO tocar (posible bug fantasma).
--     end as final_status
--   from classified
-- )
-- update public.orders o
-- set status_ext = t.final_status, closed_at = now()
-- from to_close t
-- where o.id = t.id and t.final_status is not null;
--
-- with sessions_to_close as (
--   select ts.id, ts.table_id
--   from public.table_sessions ts
--   where ts.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
--     and ts.closed_at is null
--     and ts.opened_at < now() - interval '30 minutes'
--     and not exists (
--       select 1 from public.orders o
--       where o.session_id = ts.id
--         and o.closed_at is null
--         and o.status_ext not in ('paid', 'void')
--     )
-- ),
-- closed as (
--   update public.table_sessions ts
--   set closed_at = now()
--   from sessions_to_close s
--   where ts.id = s.id
--   returning ts.table_id
-- )
-- update public.dining_tables dt
-- set state = 'available'
-- where dt.id in (select table_id from closed where table_id is not null)
--   and dt.state <> 'available';
--
-- commit;
-- -- rollback;  -- usa esto en vez de commit si algo no cuadra.
