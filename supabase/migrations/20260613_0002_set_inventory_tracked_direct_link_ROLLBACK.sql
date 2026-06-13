-- =============================================================================
-- ROLLBACK de 20260613_0002 — restaura fn_menu_item_set_inventory_tracked
-- a la versión VIVA previa (crea self-recipe 1:1).
-- =============================================================================

begin;

create or replace function public.fn_menu_item_set_inventory_tracked(
  p_menu_item_id uuid,
  p_tracked boolean,
  p_initial_stock numeric default 0,
  p_warehouse_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_business_id uuid;
  v_role text;
  v_item_name text;
  v_item_sku text;
  v_item_cost numeric;
  v_unit text;
  v_inventory_item_id uuid;
  v_recipe_id uuid;
  v_warehouse_id uuid;
  v_movement_inserted boolean := false;
begin
  if p_menu_item_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select mi.business_id, mi.name, mi.sku, coalesce(mi.cost, 0)
    into v_business_id, v_item_name, v_item_sku, v_item_cost
  from public.menu_items mi
  where mi.id = p_menu_item_id;

  if v_business_id is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if not p_tracked then
    update public.menu_items
       set is_inventory_tracked = false
     where id = p_menu_item_id;

    return jsonb_build_object(
      'menu_item_id', p_menu_item_id,
      'is_inventory_tracked', false,
      'inventory_item_id', null,
      'initial_stock_recorded', 0
    );
  end if;

  update public.menu_items
     set is_inventory_tracked = true
   where id = p_menu_item_id;

  select ri.inventory_item_id, r.id
    into v_inventory_item_id, v_recipe_id
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where r.menu_item_id = p_menu_item_id
    and ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0) > 0
  order by ri.id
  limit 1;

  if v_inventory_item_id is null then
    select id, coalesce(unit, 'unidad')
      into v_inventory_item_id, v_unit
    from public.inventory_items
    where business_id = v_business_id
      and coalesce(is_active, true)
      and (
        (v_item_sku is not null and nullif(btrim(sku), '') = btrim(v_item_sku))
        or lower(btrim(name)) = lower(btrim(v_item_name))
      )
    order by created_at asc
    limit 1;

    if v_inventory_item_id is null then
      insert into public.inventory_items (
        business_id, sku, name, unit, cost, is_active
      )
      values (
        v_business_id,
        nullif(btrim(coalesce(v_item_sku, '')), ''),
        v_item_name,
        'unidad',
        v_item_cost,
        true
      )
      returning id, unit into v_inventory_item_id, v_unit;
    end if;

    if v_recipe_id is null then
      select id into v_recipe_id
      from public.recipes
      where menu_item_id = p_menu_item_id
      limit 1;
    end if;

    if v_recipe_id is null then
      insert into public.recipes (menu_item_id, yield_quantity)
      values (p_menu_item_id, 1)
      returning id into v_recipe_id;
    end if;

    if not exists (
      select 1 from public.recipe_ingredients
      where recipe_id = v_recipe_id and inventory_item_id = v_inventory_item_id
    ) then
      insert into public.recipe_ingredients (
        recipe_id, inventory_item_id, quantity, unit
      )
      values (v_recipe_id, v_inventory_item_id, 1, coalesce(v_unit, 'unidad'));
    end if;
  end if;

  if coalesce(p_initial_stock, 0) > 0 then
    v_warehouse_id := p_warehouse_id;
    if v_warehouse_id is null then
      select id into v_warehouse_id
      from public.warehouses
      where business_id = v_business_id
        and coalesce(is_active, true)
        and name is distinct from '__IN_TRANSIT__'
      order by is_main desc nulls last, created_at asc nulls first
      limit 1;
    end if;

    if v_warehouse_id is not null then
      perform public.fn_inventory_record_movement(
        p_business_id    => v_business_id,
        p_warehouse_id   => v_warehouse_id,
        p_item_id        => v_inventory_item_id,
        p_movement_type  => 'purchase'::public.movement_type,
        p_quantity       => p_initial_stock,
        p_cost_per_unit  => v_item_cost,
        p_reference_id   => p_menu_item_id,
        p_reference_type => 'initial_stock',
        p_notes          => concat(
          'Stock inicial al activar tracking del producto "', v_item_name, '"'
        )
      );
      v_movement_inserted := true;
    end if;
  end if;

  return jsonb_build_object(
    'menu_item_id',           p_menu_item_id,
    'is_inventory_tracked',   true,
    'inventory_item_id',      v_inventory_item_id,
    'warehouse_id',           v_warehouse_id,
    'initial_stock_recorded', case when v_movement_inserted then p_initial_stock else 0 end
  );
end;
$function$;

commit;
