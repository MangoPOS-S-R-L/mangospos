-- =============================================================================
-- Inventario: vista que expone el stock por producto del menú.
--
-- PROBLEMA:
--   La UI de Productos no muestra el stock de un menu_item porque el dato
--   no vive ahí: vive en `inventory_stock` (por insumo + bodega), y el puente
--   es `recipes` → `recipe_ingredients` → `inventory_items`. Para evitar que
--   cada llamada del front haga 4 joins, exponemos una vista helper.
--
-- SEMÁNTICA:
--   - Solo trae menu_items con `is_inventory_tracked = true`.
--   - Solo trae recetas 1:1 (un solo ingrediente con quantity = 1). Esto cubre
--     el caso Loyverse-style donde cada producto consume 1 unidad de su
--     insumo correspondiente.
--   - Para recetas multi-ingrediente (modo `advanced`), no exponemos un
--     "stock del producto" porque depende de varios insumos; el admin
--     ve cada insumo en la pantalla de Insumos.
--   - El stock se suma a través de todas las bodegas activas del negocio.
--
-- USO TÍPICO:
--   select * from public.menu_items mi
--   left join public.v_menu_items_stock s on s.menu_item_id = mi.id
--
-- IDEMPOTENTE: CREATE OR REPLACE.
-- =============================================================================

begin;

create or replace view public.v_menu_items_stock
with (security_invoker = on) as
with recipe_ingredient_counts as (
  -- Cuántos ingredientes válidos tiene cada receta.
  select r.menu_item_id, count(*) as ingredient_count
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where ri.inventory_item_id is not null
    and coalesce(ri.quantity, 0) > 0
  group by r.menu_item_id
),
one_ingredient_recipes as (
  -- Receta con exactamente UN ingrediente. No agregamos sobre uuid; nos
  -- limitamos a las recetas que pasan el filtro de count = 1 y leemos el
  -- ingrediente directo.
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
  -- Stock total = suma de quantity en todas las bodegas, dividido por la
  -- qty-por-unidad de la receta. floor() porque vender medio producto no
  -- aplica para el caso simple.
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

comment on view public.v_menu_items_stock is
  'Stock disponible por menu_item tracked (recetas 1:1). Usar para mostrar '
  '"N unidades disponibles" en la pantalla de Productos. Recetas multi-'
  'ingrediente no aparecen aquí — esos productos se gestionan vía Insumos.';

commit;
