-- =============================================================================
-- 20260605_0007 — v_zone_table_status: total + datos de sesión en la vista
-- =============================================================================
--
-- OBJETIVO (velocidad de la pantalla de mesas/salón)
-- ──────────────────────────────────────────────────
-- Antes, para mostrar el total de cada mesa, el cliente (zones_repository) traía
-- orders → order_items → modifiers → tax_lines → taxes y recalculaba con
-- summarizeOrderPricing: ~5+ viajes en serie POR ZONA. Más consultas extra para
-- customer_name / waiter_user_id.
--
-- FIX
-- ───
-- La vista calcula el TOTAL en el servidor: suma `order_items.total` de los ítems
-- NO pagados (excluye paid/void) de las órdenes abiertas de la sesión. Eso da el
-- "pendiente por cobrar" (respeta split bill, igual que hacía el repo) usando el
-- per-item total ya calculado por el trigger fn_compute_item_totals (que ya
-- maneja inclusive, descuentos y las líneas de oferta). Además expone
-- customer_name / waiter_user_id / people_count para que el repo no tenga que
-- ir a buscarlos a `table_sessions`.
--
-- Con esto el repo deja de traer orders/items/mods/tax_lines/taxes → la carga
-- baja de ~10 viajes por zona a ~2-3.
--
-- NOTA: el total puede diferir en centavos del de la pantalla del pedido en
-- casos borde de takeout (filtrado de tax_lines por apply_on_takeout), poco
-- relevante para mesas dine-in. Para el detalle exacto sigue la pantalla del
-- pedido.
-- =============================================================================

begin;

drop view if exists public.v_zone_table_status;

create view public.v_zone_table_status as
select
  t.id              as table_id,
  z.id              as zone_id,
  z.name            as zone_name,
  z.business_id,
  t.code,
  t.label,
  t.shape,
  t.capacity,
  t.state,
  s.id              as session_id,
  s.opened_by,
  s.opened_at,
  s.waiter_user_id,
  s.customer_name,
  s.people_count,
  -- Nombre del mozo resuelto en el servidor (primer token, igual que
  -- preferredDisplayName). Prioridad: empleado que abrió (multimesero) >
  -- waiter_user_id (empleado/perfil) > opened_by (empleado/perfil).
  coalesce(
    (select nullif(split_part(btrim(e.first_name), ' ', 1), '')
       from public.employees e where e.id = s.opened_by_employee_id),
    (select nullif(split_part(btrim(e.first_name), ' ', 1), '')
       from public.employees e
       where e.user_id = s.waiter_user_id and e.business_id = z.business_id
       limit 1),
    (select nullif(split_part(btrim(p.full_name), ' ', 1), '')
       from public.profiles p where p.id = s.waiter_user_id),
    (select nullif(split_part(btrim(e.first_name), ' ', 1), '')
       from public.employees e
       where e.user_id = s.opened_by and e.business_id = z.business_id
       limit 1),
    (select nullif(split_part(btrim(p.full_name), ' ', 1), '')
       from public.profiles p where p.id = s.opened_by)
  ) as waiter_name,
  -- ¿La sesión es del usuario actual? (dueño = waiter_user_id, si no opened_by)
  (auth.uid() is not null
    and auth.uid() = coalesce(s.waiter_user_id, s.opened_by)) as is_own,
  case when s.opened_at is not null and s.closed_at is null
       then extract(epoch from (now() - s.opened_at))::int / 60
       else null end as minutes_open,
  coalesce((
    select count(*) from public.orders o where o.session_id = s.id
  ), 0) as orders_count,
  -- Total pendiente por cobrar: suma de order_items.total de ítems NO pagados
  -- en las órdenes abiertas de la sesión (per-item total ya calculado por el
  -- trigger; respeta inclusive, descuentos y ofertas). Excluye paid/void.
  coalesce((
    select sum(oi.total)
    from public.order_items oi
    join public.orders o2 on o2.id = oi.order_id
    where o2.session_id = s.id
      and o2.closed_at is null
      and o2.status_ext not in ('paid'::public.order_status, 'void'::public.order_status)
      and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
  ), 0) as total,
  case
    when s.precheck_printed_at is not null and s.closed_at is null then 'paying'
    else null
  end               as status
from public.dining_tables t
join public.zones z on z.id = t.zone_id
left join lateral (
  select * from public.table_sessions s2
  where s2.table_id = t.id and s2.closed_at is null
  order by s2.opened_at desc
  limit 1
) s on true;

grant select on public.v_zone_table_status to authenticated;

notify pgrst, 'reload schema';

commit;
