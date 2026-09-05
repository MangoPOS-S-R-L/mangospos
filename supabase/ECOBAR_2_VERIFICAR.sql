-- =============================================================================
-- ECO BAR & LOUNGE — comprobación después de cargar el menú.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
-- Todo lee. Lo que salga en rojo hay que arreglarlo ANTES de vender.
-- =============================================================================

-- 1. El menú nuevo, categoría por categoría. Deben ser 33 categorías / 284 productos.
select c.position as orden, c.name as categoria, count(mi.id) as productos,
       min(mi.price) as precio_min, max(mi.price) as precio_max
  from public.categories c
  left join public.menu_items mi on mi.category_id = c.id and mi.is_active
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and c.is_active
 group by c.position, c.name
 order by c.position;


-- 2. LO QUE NO PUEDE FALLAR. Las tres columnas de la derecha deben dar 0.
select count(*)                                                        as productos_activos,
       count(*) filter (where print_area_code is null)                 as SIN_AREA,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t where t.item_id = menu_items.id))
                                                                       as SIN_IMPUESTO,
       count(*) filter (where tax_mode <> 'exclusive')                  as TAX_MODE_MALO
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;


-- 3. Qué impuesto quedó vinculado y a cuántos productos.
select t.name, t.rate, count(*) as productos
  from public.menu_item_taxes mit
  join public.taxes t on t.id = mit.tax_id
  join public.menu_items mi on mi.id = mit.item_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
 group by t.name, t.rate;


-- 4. Ruteo de comandas: cuántos productos a cada área.
select coalesce(pa.name, '(sin área)') as area, pa.code, count(*) as productos
  from public.menu_items mi
  left join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
  left join public.print_areas pa on pa.id = mipa.print_area_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
 group by pa.name, pa.code
 order by count(*) desc;


-- 5. Menú viejo: lo que quedó desactivado (no se borra, sostiene el histórico).
select count(*) as productos_viejos_desactivados
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and not is_active;


-- 6. Precio con ITBIS incluido, para cotejar contra el PDF a ojo.
select c.name as categoria, mi.name as producto, mi.price as sin_itbis,
       round(mi.price * (1 + coalesce((
         select sum(t.rate) from public.menu_item_taxes mit
           join public.taxes t on t.id = mit.tax_id and t.is_active
          where mit.item_id = mi.id), 0) / 100), 2) as con_impuestos
  from public.menu_items mi
  join public.categories c on c.id = mi.category_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
 order by c.position, mi.position;


-- 7. Cuando ya esté todo verificado, bota los respaldos:
-- drop table if exists public.zzz_ecobar_bk_menu_items;
-- drop table if exists public.zzz_ecobar_bk_categories;
-- drop table if exists public.zzz_ecobar_bk_menu_item_taxes;
-- drop table if exists public.zzz_ecobar_bk_menu_item_print_areas;
-- drop table if exists public.zzz_ecobar_bk_recipes;
-- drop table if exists public.zzz_ecobar_bk_recipe_ingredients;
