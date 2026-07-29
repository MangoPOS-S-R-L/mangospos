-- =============================================================================
-- 20260729_0001 — KDS "Completados Hoy": incluir órdenes cobradas sin marcar
-- =============================================================================
--
-- Problema: la vista `kds_completed_today` exige `oi.ready_at` de hoy. Cuando
-- una orden se COBRA antes de que la cocina la marque (modo "sale al pagar":
-- los ítems pasan a 'paid' con ready_at NULL y la comanda desaparece del
-- tablero), esa orden nunca aparece en el historial "Completados hoy" —
-- por eso "no aparecen todas las órdenes completadas".
--
-- Solución: además de los ítems con ready_at de hoy, incluir los ítems
-- 'paid'/'served' SIN ready_at cuya orden se cerró hoy. Para esos, la hora
-- mostrada (`ready_at`) cae al cierre de la orden (`orders.closed_at`).
-- Se exige `kitchen_sent_at IS NOT NULL` para no arrastrar ventas que nunca
-- pasaron por cocina (retail / negocios sin KDS).
--
-- Mismas columnas, orden y tipos que la vista actual (CREATE OR REPLACE
-- compatible); solo cambian la expresión de ready_at y el WHERE.
--
-- IDEMPOTENTE: CREATE OR REPLACE VIEW.
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
  coalesce(oi.ready_at, o.closed_at) as ready_at,
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
where oi.status <> 'void'::public.item_status
  and (
    -- Camino normal: la cocina marcó el ítem hoy.
    (oi.ready_at is not null
     and (oi.ready_at at time zone 'America/Santo_Domingo')::date
         = (now() at time zone 'America/Santo_Domingo')::date)
    -- Orden cobrada/cerrada hoy sin que la cocina marcara: el ítem fue
    -- enviado a cocina (kitchen_sent_at) y terminó 'paid'/'served'.
    or (oi.ready_at is null
        and oi.kitchen_sent_at is not null
        and oi.status in ('paid'::public.item_status,
                          'served'::public.item_status)
        and o.closed_at is not null
        and (o.closed_at at time zone 'America/Santo_Domingo')::date
            = (now() at time zone 'America/Santo_Domingo')::date)
  );

grant select on public.kds_completed_today to authenticated, service_role;

commit;
