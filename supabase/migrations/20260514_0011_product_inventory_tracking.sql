-- =============================================================================
-- Productos: flag `is_inventory_tracked` por producto del menú.
--
-- PROBLEMA:
--   El control de inventario hoy es a nivel de business (business_settings.
--   inventory_mode = 'none'|'basic'|'advanced'). Cuando un negocio está en
--   'basic' o 'advanced', TODOS sus productos del menú con receta consumen
--   stock al venderse. No hay forma de tener productos mixtos: unos que
--   trackean inventario y otros que no.
--
-- ENTREGA:
--   1. Columna `menu_items.is_inventory_tracked BOOLEAN DEFAULT false`.
--      TODOS los productos existentes quedan en `false` (default). No hay
--      backfill — el admin debe marcar manualmente los que quiera trackear.
--   2. RPC `fn_menu_item_set_inventory_tracked(menu_item_id, tracked,
--      initial_stock_qty?)` que actualiza el flag y, si se activa con
--      stock inicial, registra un movimiento 'purchase' en la bodega
--      principal del business.
--   3. Modifica `consume_inventory_from_order` para que solo descuente
--      stock de productos con `is_inventory_tracked = true`.
--
-- IMPACTO EN PRODUCCIÓN:
--   ⚠️ Negocios que actualmente consumen stock vía recetas dejarán de
--   hacerlo después de esta migración. Sus productos quedan `false` y
--   el filtro nuevo en consume_inventory_from_order los excluye. Para
--   re-activar el consumo, el admin debe editar cada producto y
--   marcarlo como "Inventariable" desde el dialog de edición.
--
-- IDEMPOTENTE:
--   - ADD COLUMN IF NOT EXISTS.
--   - CREATE OR REPLACE FUNCTION.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columna nueva en menu_items.
-- ---------------------------------------------------------------------------

alter table public.menu_items
  add column if not exists is_inventory_tracked boolean not null default false;

comment on column public.menu_items.is_inventory_tracked is
  'Si true, este producto consume stock al venderse (vía consume_inventory_'
  'from_order) y el UI muestra controles de inventario. Default false: '
  'productos nuevos no participan a menos que el admin los marque.';

-- ---------------------------------------------------------------------------
-- 2. SIN BACKFILL — todos los productos existentes quedan en `false`.
--    El admin debe marcar manualmente los que quiera trackear desde el
--    editor de productos. Esto incluye productos que actualmente tienen
--    recetas activas: dejarán de consumir stock al venderse hasta que se
--    marquen como inventariables.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. Modificar consume_inventory_from_order: ahora filtra por flag.
--    Solo cambia el WHERE del JOIN para excluir productos no-trackeables.
--    Resto de la lógica idéntica.
-- ---------------------------------------------------------------------------

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
  select ts.business_id
    into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = _order_id
  limit 1;

  if v_business_id is null then
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

comment on function public.consume_inventory_from_order(uuid) is
  'Consume stock al venderse productos del menú con receta. Filtra por '
  'menu_items.is_inventory_tracked = true — productos sin este flag NO '
  'consumen stock aunque tengan receta vinculada. Idempotente vía '
  'reference_id.';

-- ---------------------------------------------------------------------------
-- 4. RPC helper: activar tracking + stock inicial.
--
--    Al marcar un producto como inventariable:
--    1. Asegura que exista inventory_item ligado (vía receta 1:1) — si no
--       hay receta o ingrediente, crea ambos.
--    2. Si `p_initial_stock > 0`, registra un movimiento `purchase` en la
--       bodega principal del business para inicializar el stock.
--
--    Idempotente: si el producto ya está tracked, solo registra el stock
--    inicial adicional (si se provee). No crea recipes duplicadas.
-- ---------------------------------------------------------------------------

create or replace function public.fn_menu_item_set_inventory_tracked(
  p_menu_item_id uuid,
  p_tracked boolean,
  p_initial_stock numeric default 0,
  p_warehouse_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  -- Si se desactiva el tracking, simplemente bajamos el flag.
  -- No borramos receta/inventory_item/movements para preservar histórico.
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

  -- Activar: marcamos el flag.
  update public.menu_items
     set is_inventory_tracked = true
   where id = p_menu_item_id;

  -- Buscar o crear el inventory_item linkado vía receta.
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
    -- No hay link: buscar inventory_item por SKU/nombre.
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

    -- Si no existe, crearlo.
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

    -- Asegurar la receta 1:1.
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

    -- Crear el ingrediente 1:1 si no existe.
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

  -- Stock inicial: si se proveyó, registrar movimiento purchase.
  if coalesce(p_initial_stock, 0) > 0 then
    v_warehouse_id := p_warehouse_id;
    if v_warehouse_id is null then
      -- Bodega principal del business (is_main=true). Si no hay main,
      -- toma la primera activa.
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
$$;

grant execute on function public.fn_menu_item_set_inventory_tracked(uuid, boolean, numeric, uuid)
  to authenticated;

comment on function public.fn_menu_item_set_inventory_tracked(uuid, boolean, numeric, uuid) is
  'Activa/desactiva tracking de inventario para un producto del menú. Si '
  'activa: asegura inventory_item + receta 1:1, y opcionalmente registra '
  'stock inicial como movimiento purchase en la bodega principal.';

commit;
