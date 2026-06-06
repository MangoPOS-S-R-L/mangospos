-- =============================================================================
-- 20260605_0008 — fn_get_order_bundle: embeber modifiers + tax_lines por item
-- =============================================================================
--
-- OBJETIVO (velocidad de "abrir mesa / cargar pedido")
-- ────────────────────────────────────────────────────
-- Hasta ahora getOrderBundle (sales_repository.dart) hacía:
--   1) fn_get_order_bundle  → order + items + checks
--   2) order_item_modifiers  (en lotes de 100)   ← viaje extra en serie
--   3) order_item_tax_lines  (en lotes de 100)   ← viaje extra en serie
-- = ~3 round-trips por cada recarga del pedido (tras agregar/quitar ítem,
--   refrescar, dividir cuenta, etc.).
--
-- fn_open_table_and_load YA embebía modifiers/tax_lines en cada item, por eso
-- "tocar la mesa" abría en 1 viaje. Esta migración hace que fn_get_order_bundle
-- haga lo MISMO, para que TODAS las recargas del pedido sean 1 solo viaje.
--
-- FORMATO
-- ───────
-- Cada item del array `items` gana dos claves:
--   'modifiers' : [ {id,item_id,name,qty,price,menu_item_id,...}, ... ]
--   'tax_lines' : [ {id,order_item_id,tax_id,tax_name,tax_rate,amount,created_at,...}, ... ]
-- El cliente (getOrderBundle) las parsea si vienen; si no (DB sin esta
-- migración), cae al camino de los lotes — 100% retrocompatible.
--
-- Conserva TODO lo de 20260530_0014 (join de employees por item) intacto.
-- =============================================================================

begin;

create or replace function public.fn_get_order_bundle(
  p_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  with target_order as (
    select o.*
    from public.orders o
    where o.id = p_order_id
    limit 1
  ),
  order_customer as (
    select ts.customer_id, ts.customer_name
    from target_order o
    join public.table_sessions ts on ts.id = o.session_id
  )
  select jsonb_build_object(
    'order',
      (select to_jsonb(o) from target_order o),
    'checks',
      coalesce(
        (
          select jsonb_agg(to_jsonb(oc) order by oc.position)
          from public.order_checks oc
          where oc.order_id = p_order_id
        ),
        '[]'::jsonb
      ),
    'items',
      coalesce(
        (
          select jsonb_agg(
            to_jsonb(oi) || jsonb_build_object(
              'employees', (
                select jsonb_build_object(
                  'first_name', e.first_name,
                  'last_name', e.last_name
                )
                from public.employees e
                where e.id = oi.created_by_employee_id
              ),
              'modifiers', coalesce(
                (
                  select jsonb_agg(to_jsonb(m) order by m.id)
                  from public.order_item_modifiers m
                  where m.item_id = oi.id
                ),
                '[]'::jsonb
              ),
              'tax_lines', coalesce(
                (
                  select jsonb_agg(to_jsonb(tl) order by tl.created_at)
                  from public.order_item_tax_lines tl
                  where tl.order_item_id = oi.id
                ),
                '[]'::jsonb
              )
            )
            order by oi.created_at, oi.id
          )
          from public.order_items oi
          join target_order o on o.id = oi.order_id
          where oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
            and (o.closed_at is null or o.status_ext not in ('void', 'paid'))
        ),
        '[]'::jsonb
      ),
    'customer_id',
      (select customer_id from order_customer limit 1),
    'customer_name',
      (select customer_name from order_customer limit 1)
  )
  into v_payload;

  if v_payload is null or (v_payload -> 'order') is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  return v_payload;
end;
$$;

grant execute on function public.fn_get_order_bundle(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
