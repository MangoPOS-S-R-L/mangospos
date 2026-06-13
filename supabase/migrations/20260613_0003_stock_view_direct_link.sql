-- =============================================================================
-- 20260613_0003 — v_menu_items_stock: incluir productos con link DIRECTO
-- =============================================================================
--
-- Companion de 20260613_0001/0002. La vista de stock solo resolvía recetas
-- 1:1. Ahora también muestra el stock de productos TERMINADOS enlazados
-- directo (menu_items.inventory_item_id, per_unit_qty = 1). Así la pantalla
-- de Productos muestra "N disponibles" para cervezas/licores.
--
-- Un producto aparece por receta 1:1 O por link directo (el link directo
-- excluye los que tienen receta) → sin filas duplicadas.
-- REQUIERE 20260613_0001 (columna inventory_item_id).
-- =============================================================================

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

comment on view public.v_menu_items_stock is
  'Stock disponible por menu_item tracked: recetas 1:1 + productos terminados '
  'con link directo (menu_items.inventory_item_id). Recetas multi-ingrediente '
  'no aparecen aquí — esos se gestionan vía Insumos.';

commit;
