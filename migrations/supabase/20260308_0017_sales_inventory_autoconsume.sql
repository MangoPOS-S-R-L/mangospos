-- 20260308_0017_sales_inventory_autoconsume.sql
-- Scope:
-- 1) Make sales inventory consumption incremental and idempotent per order.
-- 2) Consume stock on every kitchen confirmation, including re-sends with new items.
-- 3) Align the fallback trigger with the real order state transition.

begin;

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_main_warehouse_id uuid;
  v_business_id uuid;
  v_ingredient record;
  v_consumed numeric;
  v_delta numeric;
begin
  select
    ts.business_id,
    w.id
    into v_business_id,
         v_main_warehouse_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.warehouses w
    on w.business_id = ts.business_id
   and w.is_main = true
  where o.id = _order_id
  order by w.created_at nulls last, w.id
  limit 1;

  if v_main_warehouse_id is null then
    raise exception 'MAIN_WAREHOUSE_NOT_FOUND';
  end if;

  for v_ingredient in
    select
      i.inventory_item_id,
      sum(i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0)) as expected_qty
    from public.order_items oi
    join public.recipes r on r.menu_item_id = oi.product_id
    join public.recipe_ingredients i on i.recipe_id = r.id
    where oi.order_id = _order_id
      and oi.product_id is not null
      and oi.status <> 'void'
      and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
    group by i.inventory_item_id
  loop
    select coalesce(abs(sum(im.quantity)), 0)
      into v_consumed
    from public.inventory_movements im
    where im.reference_id = _order_id
      and im.reference_type = 'order'
      and im.movement_type = 'sale'
      and im.item_id = v_ingredient.inventory_item_id;

    v_delta := greatest(v_ingredient.expected_qty - v_consumed, 0);

    if v_delta > 0 then
      insert into public.inventory_movements (
        business_id,
        warehouse_id,
        item_id,
        movement_type,
        quantity,
        reference_id,
        reference_type,
        notes
      )
      values (
        v_business_id,
        v_main_warehouse_id,
        v_ingredient.inventory_item_id,
        'sale',
        -v_delta,
        _order_id,
        'order',
        'Auto-consumo por venta'
      );
    end if;
  end loop;
end;
$$;

create or replace function public.fn_confirm_order_to_kitchen(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.orders
  set status = 'sent',
      status_ext = 'sent_to_kitchen'
  where id = p_order_id;

  update public.order_items
  set status = 'pending'
  where order_id = p_order_id
    and status in ('draft', 'pending');

  perform public.consume_inventory_from_order(p_order_id);
end;
$$;

create or replace function public.trigger_inventory_on_order_sent()
returns trigger
language plpgsql
as $$
begin
  if new.status_ext = 'sent_to_kitchen'
     and old.status_ext is distinct from 'sent_to_kitchen' then
    perform public.consume_inventory_from_order(new.id);
  end if;
  return new;
end;
$$;

comment on function public.consume_inventory_from_order(uuid)
  is 'Audit alignment 2026-03-08: idempotent incremental stock consumption per order.';

commit;
