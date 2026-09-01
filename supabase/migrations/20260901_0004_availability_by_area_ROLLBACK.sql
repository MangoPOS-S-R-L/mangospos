-- ROLLBACK de 20260901_0004_availability_by_area.sql
--
-- Restaura la vista y el auto-86 a su versión previa: suman TODAS las
-- bodegas, sin mirar el área del producto.
--
-- DE DÓNDE SALE CADA UNA (importa: el repositorio tiene versiones
-- intermedias que NO son las que estaban vivas, y agarrar la equivocada
-- borra funcionalidad en silencio):
--   · la vista, de 20260613_0003_stock_view_direct_link. La de
--     20260516_0014 es anterior y le falta el ramo `item_links` del link
--     directo.
--   · el auto-86, de 20260517_0001_allow_negative_sale. La de
--     20260516_0015 es anterior y le falta todo el manejo de
--     `allow_negative_sale`.
--   Las dos cotejadas contra pg_get_viewdef / pg_get_functiondef el
--   2026-08-31.
--
-- OJO: si para cuando corras esto la bandera warehouse_sections_enabled
-- está PRENDIDA, el menú vuelve a mostrar disponible lo que hay en
-- cualquier bodega mientras la venta sigue descontando de la del área.
-- Apagá la bandera primero.

-- NO borra `shows_in_pos` ni su índice: la 20260901_0005 los usa. Si querés
-- sacar la columna, revertí la 0005.

begin;

create or replace view public.v_menu_items_stock
with (security_invoker = on) as
with recipe_ingredient_counts as (
  select r.menu_item_id, count(*) as ingredient_count
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0) > 0
  group by r.menu_item_id
),
one_ingredient_recipes as (
  select
    r.menu_item_id,
    ri.inventory_item_id,
    ri.quantity as per_unit_qty
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  join recipe_ingredient_counts c on c.menu_item_id = r.menu_item_id
  where c.ingredient_count = 1
    and ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0) > 0
),
item_links as (
  -- (a) Recetas 1:1 (comportamiento previo).
  select menu_item_id, inventory_item_id, per_unit_qty
  from one_ingredient_recipes
  union all
  -- (b) Producto TERMINADO con link directo (sin receta), 1 unidad por venta.
  select mi.id, mi.inventory_item_id, 1::numeric
  from public.menu_items mi
  where mi.inventory_item_id is not null
    and not exists (
      select 1 from public.recipes r where r.menu_item_id = mi.id
    )
)
select
  mi.id                                                  as menu_item_id,
  il.inventory_item_id,
  ii.unit,
  floor(coalesce(sum(ist.quantity), 0) / nullif(il.per_unit_qty, 0))::numeric
                                                         as available_units,
  coalesce(sum(ist.quantity), 0)                         as raw_ingredient_stock,
  il.per_unit_qty                                        as ingredient_per_unit
from public.menu_items mi
join item_links il on il.menu_item_id = mi.id
join public.inventory_items ii  on ii.id = il.inventory_item_id
left join public.inventory_stock ist on ist.item_id = il.inventory_item_id
where coalesce(mi.is_inventory_tracked, false) = true
group by mi.id, il.inventory_item_id, ii.unit, il.per_unit_qty;

grant select on public.v_menu_items_stock to authenticated;

create or replace function public.fn_recompute_menu_items_availability(
  p_inventory_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_menu_item record;
  v_available numeric;
begin
  if p_inventory_item_id is null then
    return;
  end if;

  for v_menu_item in
    select distinct
      mi.id,
      mi.is_active,
      mi.auto_disabled,
      mi.allow_negative_sale
    from public.menu_items mi
    join public.recipes r on r.menu_item_id = mi.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    where ri.inventory_item_id = p_inventory_item_id
      and coalesce(mi.is_inventory_tracked, false) = true
  loop
    -- Productos que permiten venta en negativo: nunca los auto-desactivamos.
    -- El badge "Agotado" en la UI alerta al cajero; el conteo sigue corriendo
    -- en inventory_stock (puede ir negativo) y se salda con la próxima compra.
    if v_menu_item.allow_negative_sale = true then
      -- Si veníamos de un auto-86 anterior (antes de que se activara el
      -- flag), reactivamos para que vuelva al menú.
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
      continue;
    end if;

    -- Comportamiento legacy: calcula availability respetando todos los
    -- ingredientes y desactiva si alguno se agotó.
    select min(
      floor(
        coalesce((
          select sum(ist.quantity)
          from public.inventory_stock ist
          where ist.item_id = ri2.inventory_item_id
        ), 0) / nullif(ri2.quantity, 0)
      )
    )::numeric
      into v_available
    from public.recipes r2
    join public.recipe_ingredients ri2 on ri2.recipe_id = r2.id
    where r2.menu_item_id = v_menu_item.id
      and ri2.inventory_item_id is not null
      and coalesce(ri2.quantity, 0) > 0;

    if v_available is null or v_available <= 0 then
      if v_menu_item.is_active = true then
        update public.menu_items
        set is_active = false, auto_disabled = true
        where id = v_menu_item.id;
      end if;
    else
      if v_menu_item.auto_disabled = true and v_menu_item.is_active = false then
        update public.menu_items
        set is_active = true, auto_disabled = false
        where id = v_menu_item.id;
      end if;
    end if;
  end loop;
end;
$$;

commit;
