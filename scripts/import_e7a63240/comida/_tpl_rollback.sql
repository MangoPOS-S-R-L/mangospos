-- ============================================================================
-- MENÚ DE COMIDA — ROLLBACK de IMPORT_COMIDA.sql
-- Business e7a63240-6492-4ed5-8057-319ab91a748c (AZOTEA 046 BAR & GRILL)
-- ============================================================================
--
-- Borra los productos de la lista (con sus impuestos, área y enlace al menú)
-- y las 9 categorías de comida si quedan vacías. NO toca los cócteles, las
-- aguas, el área de cocina ni el menú.
--
-- ⚠ ABORTA SI YA SE VENDIÓ ALGUNO: borrarlo rompería el histórico. En ese
--   caso desactívalo (is_active = false) en la app.
-- ⚠ Solo borra productos que están en una categoría de comida y NO son
--   bebida: nunca el cóctel Brisa Tropical.
-- ============================================================================

begin;

create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

drop table if exists _cm_lista;
create temp table _cm_lista (
  categoria text not null,
  name      text not null,
  price     numeric(12,2) not null,
  posicion  int not null
) on commit drop;

insert into _cm_lista (categoria, name, price, posicion) values
--@@PRODUCTOS@@
;

do $$
declare
  v_business uuid := 'e7a63240-6492-4ed5-8057-319ab91a748c';
  v_n        int;
  v_list     text;
begin
  create temp table _cm_rb_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _cm_lista s on pg_temp.norm(mi.name) = pg_temp.norm(s.name)
  join public.categories c on c.id = mi.category_id
  where mi.business_id = v_business
    and not mi.is_beverage
    and pg_temp.norm(c.name) in (select distinct pg_temp.norm(categoria) from _cm_lista);

  select count(*), string_agg(i.name, ', ')
    into v_n, v_list
  from _cm_rb_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);

  if v_n > 0 then
    raise exception
      'ABORTADO: % productos ya tienen ventas (%). Borrarlos rompería el '
      'histórico. Desactívalos en vez de borrarlos.', v_n, v_list;
  end if;

  delete from public.menu_item_links       x using _cm_rb_ids i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _cm_rb_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _cm_rb_ids i where x.item_id      = i.id;
  delete from public.menu_items           mi using _cm_rb_ids i where mi.id          = i.id;

  delete from public.categories c
  where c.business_id = v_business
    and pg_temp.norm(c.name) in (select distinct pg_temp.norm(categoria) from _cm_lista)
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);

  raise notice 'Rollback: % productos borrados.', (select count(*) from _cm_rb_ids);
end $$;

commit;

-- Verificación: productos de comida y categorías de comida que quedan (0 y 0),
-- y el cóctel Brisa Tropical intacto (1).
select
  (select count(*) from public.menu_items mi
   join public.categories c on c.id = mi.category_id
   where mi.business_id = 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid
     and pg_temp.norm(c.name) in ('entradas', 'especiales de la casa y pastas', 'carnes',
       'pollo', 'mofongos', 'mariscos, pescados y chivo', 'ensaladas', 'sopas',
       'guarniciones')) as productos_comida,
  (select count(*) from public.categories c
   where c.business_id = 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid
     and pg_temp.norm(c.name) in ('entradas', 'especiales de la casa y pastas', 'carnes',
       'pollo', 'mofongos', 'mariscos, pescados y chivo', 'ensaladas', 'sopas',
       'guarniciones')) as categorias_comida,
  (select count(*) from public.menu_items mi
   where mi.business_id = 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid
     and pg_temp.norm(mi.name) = 'brisa tropical') as coctel_brisa_tropical;
