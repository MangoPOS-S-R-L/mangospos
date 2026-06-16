-- =============================================================================
-- 20260616_0003 — KDS: "Completados Hoy" basado en ready_at (no en el tablero)
-- =============================================================================
--
-- El stat/diálogo "Completados Hoy" del KDS se calculaba a partir de los ítems
-- VIVOS del tablero en estado 'ready'. Con el modo "esperar al cocinero", al
-- despachar una comanda se le pone orders.kitchen_done_at y SALE del tablero,
-- así que dejaba de contarse. (En modo "sale al pagar" también es frágil: al
-- pagar, los ítems pasan a 'paid' y salen.)
--
-- Solución: una vista de solo lectura con lo que la cocina TERMINÓ HOY, basada
-- en order_items.ready_at —que NO se pierde al pagar ni al despachar— con los
-- mismos joins de table_name/waiter que kds_active_items para reusar
-- KitchenItem.fromMap. "Hoy" = día local de RD (America/Santo_Domingo).
--
-- Aditiva y de solo lectura: no toca pagos, ni el tablero, ni datos.
-- =============================================================================

begin;

create or replace view public.kds_completed_today with (security_invoker = on) as
select
  oi.id,
  oi.order_id,
  left(oi.order_id::text, 8) as order_number,
  oi.product_name,
  coalesce(oi.quantity::numeric, oi.qty, 1::numeric) as quantity,
  oi.notes,
  oi.status,
  oi.created_at,
  oi.started_at,
  oi.ready_at,
  case
    when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
    when ts.origin = 'manual'::public.order_origin then 'Venta manual'
    when ts.origin = 'quick'::public.order_origin  then 'Venta rapida'
    else 'Venta'
  end as table_name,
  p.full_name as waiter_name,
  o.business_id,
  oi.print_area_code as area_code,
  oi.is_takeout,
  pa.name as area_name
from public.order_items oi
join public.orders o          on o.id = oi.order_id
join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt on dt.id = ts.table_id
left join public.profiles p       on p.id = ts.waiter_user_id
left join public.print_areas pa
       on pa.code = oi.print_area_code
      and pa.business_id = o.business_id
where oi.ready_at is not null
  and (oi.ready_at at time zone 'America/Santo_Domingo')::date
      = (now() at time zone 'America/Santo_Domingo')::date
  and oi.status <> 'void'::public.item_status;

grant select on public.kds_completed_today to authenticated, service_role;

commit;
