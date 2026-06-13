-- =============================================================================
-- ROLLBACK de 20260613_0003 — v_menu_items_stock solo recetas 1:1 (versión previa)
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
)
select
  mi.id                                                  as menu_item_id,
  oir.inventory_item_id,
  ii.unit,
  floor(coalesce(sum(ist.quantity), 0) / nullif(oir.per_unit_qty, 0))::numeric
                                                         as available_units,
  coalesce(sum(ist.quantity), 0)                         as raw_ingredient_stock,
  oir.per_unit_qty                                       as ingredient_per_unit
from public.menu_items mi
join one_ingredient_recipes oir on oir.menu_item_id = mi.id
join public.inventory_items ii  on ii.id = oir.inventory_item_id
left join public.inventory_stock ist on ist.item_id = oir.inventory_item_id
where coalesce(mi.is_inventory_tracked, false) = true
group by mi.id, oir.inventory_item_id, ii.unit, oir.per_unit_qty;

grant select on public.v_menu_items_stock to authenticated;

commit;
