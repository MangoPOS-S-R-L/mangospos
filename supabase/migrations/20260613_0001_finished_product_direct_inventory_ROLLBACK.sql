-- =============================================================================
-- ROLLBACK de 20260613_0001 — Inventario directo de productos terminados
-- =============================================================================
-- Restaura consume_inventory_from_order a la versión VIVA previa (con combos,
-- SIN la ruta directa de terminados) y quita la columna inventory_item_id.
-- No borra movimientos ya registrados.
-- =============================================================================

begin;

create or replace function public.consume_inventory_from_order(_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_main_warehouse_id uuid;
  v_business_id uuid;
  v_mode text;
  v_inventory_item_id uuid;
  v_expected numeric;
  v_net_consumed numeric;
  v_delta numeric;
  v_note text;
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

  if coalesce(v_mode, 'none') = 'none' then
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

  for v_inventory_item_id in
    select inventory_item_id from (
      select distinct i.inventory_item_id
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      join public.recipes r on r.menu_item_id = oi.product_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and oi.product_id is not null
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and coalesce(mi.item_type, '') <> 'combo'
      union
      select distinct i.inventory_item_id
      from public.order_items oi
      join public.menu_items combo_mi
        on combo_mi.id = oi.product_id and combo_mi.item_type = 'combo'
      join public.order_item_modifiers oim
        on oim.item_id = oi.id and oim.menu_item_id is not null
      join public.menu_items comp_mi on comp_mi.id = oim.menu_item_id
      join public.recipes r on r.menu_item_id = oim.menu_item_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(comp_mi.is_inventory_tracked, false) = true
      union
      select distinct im.item_id
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
    ) u
    where u.inventory_item_id is not null
  loop
    select coalesce(sum(q), 0)
      into v_expected
    from (
      select i.quantity * coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      join public.recipes r on r.menu_item_id = oi.product_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and i.inventory_item_id = v_inventory_item_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and coalesce(mi.item_type, '') <> 'combo'
      union all
      select i.quantity
             * coalesce(oim.qty, 1)
             * coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items combo_mi
        on combo_mi.id = oi.product_id and combo_mi.item_type = 'combo'
      join public.order_item_modifiers oim
        on oim.item_id = oi.id and oim.menu_item_id is not null
      join public.menu_items comp_mi on comp_mi.id = oim.menu_item_id
      join public.recipes r on r.menu_item_id = oim.menu_item_id
      join public.recipe_ingredients i on i.recipe_id = r.id
      where oi.order_id = _order_id
        and i.inventory_item_id = v_inventory_item_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(comp_mi.is_inventory_tracked, false) = true
    ) e;

    select coalesce(-sum(im.quantity), 0)
      into v_net_consumed
    from public.inventory_movements im
    where im.reference_id = _order_id
      and im.reference_type = 'order'
      and im.movement_type = 'sale'
      and im.item_id = v_inventory_item_id;

    v_delta := v_expected - v_net_consumed;

    if v_delta = 0 then
      continue;
    end if;

    v_note := case when v_delta > 0 then 'Auto-consumo por venta'
                   else 'Devolución por cancelación/edición' end;

    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      reference_id, reference_type, notes
    )
    values (
      v_business_id, v_main_warehouse_id, v_inventory_item_id, 'sale',
      -v_delta, _order_id, 'order', v_note
    );
  end loop;
end;
$function$;

-- La columna se deja por defecto (drop opcional). Descomenta para quitarla:
-- alter table public.menu_items drop column if exists inventory_item_id;

commit;
