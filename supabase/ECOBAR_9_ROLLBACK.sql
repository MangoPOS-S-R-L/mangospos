-- =============================================================================
-- ECO BAR & LOUNGE — deshacer la carga del menú nuevo.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- Devuelve el menú EXACTAMENTE como estaba antes de ECOBAR_1_CARGAR_MENU.sql,
-- usando las tablas zzz_ecobar_bk_* que ese script dejó.
--
-- SOLO sirve si el menú nuevo todavía NO se ha vendido. Si ya hay ventas
-- sobre los productos nuevos, el borrado del paso 1 falla (FK RESTRICT) o
-- desconecta esas ventas: en ese caso NO corras esto, avísame.
--
-- Pega TODO de una vez en el SQL Editor de Supabase.
-- =============================================================================

do $$
begin
  if to_regclass('public.zzz_ecobar_bk_menu_items') is null then
    raise exception 'No hay respaldo. Este rollback no aplica.';
  end if;
end $$;


-- 1. Fuera el menú nuevo (es todo lo activo en este momento).
delete from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and is_active
   and id not in (select id from public.zzz_ecobar_bk_menu_items);

delete from public.categories
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and id not in (select id from public.zzz_ecobar_bk_categories);


-- 2. Reponer las categorías borradas y restaurar su estado.
insert into public.categories
select * from public.zzz_ecobar_bk_categories
on conflict (id) do nothing;

update public.categories c
   set name = b.name, position = b.position, is_active = b.is_active
  from public.zzz_ecobar_bk_categories b
 where b.id = c.id;


-- 3. Reponer los productos borrados y restaurar su estado.
insert into public.menu_items
select * from public.zzz_ecobar_bk_menu_items
on conflict (id) do nothing;

update public.menu_items mi
   set is_active   = b.is_active,
       category_id = b.category_id,
       price       = b.price,
       updated_at  = now()
  from public.zzz_ecobar_bk_menu_items b
 where b.id = mi.id;


-- 4. Reponer vínculos de impuestos, áreas y recetas.
insert into public.menu_item_taxes
select * from public.zzz_ecobar_bk_menu_item_taxes
on conflict do nothing;

insert into public.menu_item_print_areas
select * from public.zzz_ecobar_bk_menu_item_print_areas
on conflict do nothing;

insert into public.recipes
select * from public.zzz_ecobar_bk_recipes
on conflict (id) do nothing;

insert into public.recipe_ingredients
select * from public.zzz_ecobar_bk_recipe_ingredients
on conflict (id) do nothing;


-- 5. Comprobar que quedó como antes.
select (select count(*) from public.menu_items
         where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1')      as productos_ahora,
       (select count(*) from public.zzz_ecobar_bk_menu_items)             as productos_en_respaldo,
       (select count(*) from public.menu_items
         where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
           and is_active)                                                 as activos_ahora,
       (select count(*) from public.zzz_ecobar_bk_menu_items
         where is_active)                                                 as activos_en_respaldo;
