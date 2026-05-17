-- Rollback de `20260516_0013_consume_basic_mode_enable.sql`.
-- Revierte al gate estricto: solo `advanced` descuenta automáticamente.
-- Esto desactiva el comportamiento Loyverse-style; el admin en modo basic
-- volvería a registrar entradas/salidas a mano.

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
  v_mode text;
  v_ingredient record;
  v_consumed numeric;
  v_delta numeric;
begin
  select ts.business_id
    into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = _order_id
  limit 1;

  if v_business_id is null then
    return;
  end if;

  select coalesce(inventory_mode, 'none')
    into v_mode
  from public.business_settings
  where business_id = v_business_id;

  if coalesce(v_mode, 'none') <> 'advanced' then
    return;
  end if;

  select w.id
    into v_main_warehouse_id
  from public.warehouses w
  where w.business_id = v_business_id
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_main_warehouse_id is null then
    return;
  end if;

  for v_ingredient in
    select
      i.inventory_item_id,
      sum(i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0)) as expected_qty
    from public.order_items oi
    join public.menu_items mi on mi.id = oi.product_id
    join public.recipes r on r.menu_item_id = oi.product_id
    join public.recipe_ingredients i on i.recipe_id = r.id
    where oi.order_id = _order_id
      and oi.product_id is not null
      and oi.status <> 'void'
      and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
      and coalesce(mi.is_inventory_tracked, false) = true
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

commit;
