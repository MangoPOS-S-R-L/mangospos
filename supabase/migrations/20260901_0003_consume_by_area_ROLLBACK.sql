-- ROLLBACK de 20260901_0003_consume_by_area.sql
--
-- Restaura `consume_inventory_from_order` a la versión de
-- 20260613_0001_finished_product_direct_inventory.sql: una sola bodega (la
-- principal) y reconciliación por insumo.
--
-- OJO: el cuerpo de abajo se copió TAL CUAL del repositorio. Si la base
-- viva tenía cambios que el repo no tiene, este rollback los borra. Antes
-- de correrlo, guardar la definición actual:
--
--   select pg_get_functiondef(
--     'public.consume_inventory_from_order(uuid)'::regprocedure);
--
-- Se puede correr con 20260901_0002 aplicada: al volver a esta versión,
-- nadie llama a fn_resolve_consumption_warehouse y queda inerte.

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

  -- Universo de ingredientes a reconciliar.
  for v_inventory_item_id in
    select inventory_item_id from (
      -- (1) Productos normales con receta (NO combos).
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
      -- (1b) Productos TERMINADOS con link directo (SIN receta).
      select distinct mi.inventory_item_id
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      where oi.order_id = _order_id
        and oi.product_id is not null
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and mi.inventory_item_id is not null
        and coalesce(mi.item_type, '') <> 'combo'
        and not exists (
          select 1 from public.recipes r where r.menu_item_id = mi.id
        )
      union
      -- (2) Componentes de combo (vía order_item_modifiers.menu_item_id).
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
      -- (3) Ingredientes con movimientos previos para esta orden.
      select distinct im.item_id
      from public.inventory_movements im
      where im.reference_id = _order_id
        and im.reference_type = 'order'
        and im.movement_type = 'sale'
    ) u
    where u.inventory_item_id is not null
  loop
    -- Expected: ruta normal + ruta terminado-directo + ruta combos.
    select coalesce(sum(q), 0)
      into v_expected
    from (
      -- (1) Productos normales con receta (NO combos).
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
      -- (1b) Producto TERMINADO directo: qty del item linkeado (× 1).
      select coalesce(oi.qty, oi.quantity::numeric, 0) as q
      from public.order_items oi
      join public.menu_items mi on mi.id = oi.product_id
      where oi.order_id = _order_id
        and mi.inventory_item_id = v_inventory_item_id
        and oi.status <> 'void'
        and coalesce(oi.qty, oi.quantity::numeric, 0) > 0
        and coalesce(mi.is_inventory_tracked, false) = true
        and coalesce(mi.item_type, '') <> 'combo'
        and not exists (
          select 1 from public.recipes r where r.menu_item_id = mi.id
        )
      union all
      -- (2) Componentes de combo: receta del componente × qty modifier × qty combo.
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
      v_inventory_item_id,
      'sale',
      -v_delta,
      _order_id,
      'order',
      v_note
    );
  end loop;
end;
$function$;

comment on function public.consume_inventory_from_order(uuid) is
  'Reconcilia el consumo de inventario de una orden contra la bodega '
  'principal. Versión previa a F1 Almacenes por sección.';

commit;
