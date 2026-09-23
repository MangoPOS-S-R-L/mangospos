-- ============================================================================
-- MENÚ DE CÓCTELES — ROLLBACK de IMPORT_COMPLETO.sql
-- Business e7a63240-6492-4ed5-8057-319ab91a748c
-- ============================================================================
--
-- Borra los 21 productos del menú (con sus impuestos, área y enlace al menú)
-- y la categoría TRAGOS si queda vacía. NO borra COCTELES: la creó el dueño
-- antes de la carga. Tampoco el área BAR ni el menú.
--
-- ⚠ ABORTA SI YA SE VENDIÓ ALGUNO. order_items.product_id es ON DELETE
--   RESTRICT: un producto con ventas no se puede borrar sin romper el
--   histórico. En ese caso desactívalo (is_active = false) en la app.
-- ⚠ Empareja por nombre: si uno de estos productos YA existía antes de la
--   carga y nunca se vendió, también se borra.
-- ============================================================================

begin;

create function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

create temp table _cf_nombres (name text not null) on commit drop;
insert into _cf_nombres (name) values
  ('Mojito de Coco'), ('Mojito de Limón'), ('Mojito de Fresa'),
  ('Piña Colada con Alcohol'), ('Margarita'), ('Martini'),
  ('Long Island Iced Tea'), ('Cuba Libre'), ('Gin Tonic'), ('Sangría'),
  ('Sex on the Beach'), ('Tequila Sunrise'), ('Coco Paradise'),
  ('Velvet Sunset'), ('Tropical Azotea'), ('Brisa Tropical'),
  ('Deseo Prohibido'), ('Passion Mamey'),
  ('Trago de Chivas'), ('Trago de Tequila'), ('Trago de la Casa');

do $$
declare
  v_business uuid := 'e7a63240-6492-4ed5-8057-319ab91a748c';
  v_n        int;
  v_list     text;
begin
  create temp table _cf_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _cf_nombres s on pg_temp.norm(mi.name) = pg_temp.norm(s.name)
  where mi.business_id = v_business;

  -- 1) Nada vendido.
  select count(*), string_agg(i.name, ', ')
    into v_n, v_list
  from _cf_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);

  if v_n > 0 then
    raise exception
      'ABORTADO: % productos ya tienen ventas (%). Borrarlos rompería el '
      'histórico. Desactívalos en vez de borrarlos.', v_n, v_list;
  end if;

  -- 2) Productos, con sus vínculos.
  delete from public.menu_item_links       x using _cf_ids i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _cf_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _cf_ids i where x.item_id      = i.id;
  delete from public.menu_items           mi using _cf_ids i where mi.id          = i.id;

  -- 3) TRAGOS, que la creó la carga, solo si quedó vacía. COCTELES no se toca.
  delete from public.categories c
  where c.business_id = v_business
    and pg_temp.norm(c.name) = 'tragos'
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);

  raise notice 'Rollback: % productos borrados.', (select count(*) from _cf_ids);
end $$;

commit;

-- Verificación: debe dar 0 en las dos columnas (TRAGOS puede quedar si
-- alguien le agregó otro producto a mano).
select
  (select count(*) from public.menu_items mi
   where mi.business_id = 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid
     and pg_temp.norm(mi.name) in (
       'mojito de coco', 'mojito de limon', 'mojito de fresa',
       'pina colada con alcohol', 'margarita', 'martini', 'long island iced tea',
       'cuba libre', 'gin tonic', 'sangria', 'sex on the beach', 'tequila sunrise',
       'coco paradise', 'velvet sunset', 'tropical azotea', 'brisa tropical',
       'deseo prohibido', 'passion mamey', 'trago de chivas', 'trago de tequila',
       'trago de la casa')) as productos_del_menu,
  (select count(*) from public.categories c
   where c.business_id = 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid
     and pg_temp.norm(c.name) = 'tragos') as categoria_tragos;
