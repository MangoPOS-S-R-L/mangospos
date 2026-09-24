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
  ('ENTRADAS', 'Fuego Callejero',                     285.00,  1),
  -- "Brisa tropical" choca con el cóctel Brisa Tropical ($375) de COCTELES.
  ('ENTRADAS', 'Brisa Tropical (Entrada)',            295.00,  2),
  ('ENTRADAS', 'Cóctel de Camarones',                 390.00,  3),
  ('ENTRADAS', 'Croquetas de Plátano Maduro',         390.00,  4),
  ('ENTRADAS', 'Nachos',                              425.00,  5),
  ('ENTRADAS', 'Deditos de Mozzarella',               295.00,  6),
  ('ENTRADAS', 'Bastoncito de Pescado',               350.00,  7),
  ('ENTRADAS', 'Croquetas de Pollo',                  275.00,  8),

  ('ESPECIALES DE LA CASA Y PASTAS', 'Pasta Tropical',                     595.00,  1),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Pasta al Fuego Azotea',              450.00,  2),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Pechuga a la Casa',                  725.00,  3),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Camarones al Fuego Tropical Azotea', 750.00,  4),
  ('ESPECIALES DE LA CASA Y PASTAS', 'Filete de Cerdo Mignon',             795.00,  5),

  ('CARNES', 'Filete de Res a la Plancha',            1150.00, 1),
  ('CARNES', 'Filete Mar y Tierra',                   1250.00, 2),
  ('CARNES', 'Filete Miñón',                          1150.00, 3),
  ('CARNES', 'Churrasco Angus',                       1650.00, 4),
  ('CARNES', 'Solomillo de Res',                      1050.00, 5),
  ('CARNES', 'Costilla de Res',                        650.00, 6),
  ('CARNES', 'Picaña',                                1250.00, 7),
  ('CARNES', 'T-Bone al Grill',                       2895.00, 8),
  ('CARNES', 'Filete de Chuleta',                      550.00, 9),

  ('POLLO', 'Pechuga a la Crema',                      580.00,  1),
  ('POLLO', 'Pechuga de Pollo',                        450.00,  2),
  ('POLLO', 'Pechuga Cordon Bleu',                     590.00,  3),
  ('POLLO', 'Pechuga Salteada',                        425.00,  4),
  ('POLLO', 'Brocheta de Pollo',                       395.00,  5),
  ('POLLO', 'Pechuga de Pollo al Vino Blanco',         595.00,  6),
  ('POLLO', 'Pechuga al Hongo',                        650.00,  7),
  ('POLLO', 'Alitas',                                  375.00,  8),
  ('POLLO', 'Alitas Búfalo',                           325.00,  9),
  ('POLLO', 'Alita Asiática',                          295.00, 10),

  ('MOFONGOS', 'Mofongo de Camarones',                 550.00,  1),
  ('MOFONGOS', 'Mofongo de Pollo',                     495.00,  2),
  ('MOFONGOS', 'Mofongo Mixto',                        650.00,  3),
  ('MOFONGOS', 'Mofongo de Chicharrón',                595.00,  4),

  ('MARISCOS, PESCADOS Y CHIVO', 'Camarones al Grill',                 695.00, 1),
  ('MARISCOS, PESCADOS Y CHIVO', 'Salmón al Grill',                    950.00, 2),
  ('MARISCOS, PESCADOS Y CHIVO', 'Filete de Mero en Salsa de Chinola', 590.00, 3),
  ('MARISCOS, PESCADOS Y CHIVO', 'Chivo Guisado',                      950.00, 4),
  ('MARISCOS, PESCADOS Y CHIVO', 'Chivo al Vino',                      950.00, 5),
  ('MARISCOS, PESCADOS Y CHIVO', 'Chivo al Horno',                     950.00, 6),

  ('ENSALADAS', 'Ensalada César',                      480.00,  1),
  ('ENSALADAS', 'César Mar y Tierra',                  690.00,  2),
  ('ENSALADAS', 'Rosette a la Casa',                   595.00,  3),
  ('ENSALADAS', 'Indonsa con Parisienne de Camarones', 695.00,  4),

  ('SOPAS', 'Sopa de Pollo',                           350.00,  1),
  ('SOPAS', 'Sopa de Camarones',                       650.00,  2),
  ('SOPAS', 'Sopa de Mero',                            495.00,  3),

  ('GUARNICIONES', 'Puré de Papa',                     125.00,  1),
  ('GUARNICIONES', 'Tostones',                         125.00,  2),
  ('GUARNICIONES', 'Papa Salteada',                    125.00,  3),
  ('GUARNICIONES', 'Arroz Blanco',                     100.00,  4),
  ('GUARNICIONES', 'Vegetales Salteados',               95.00,  5),
  ('GUARNICIONES', 'Vegetales Hervidos',                95.00,  6),
  ('GUARNICIONES', 'Batata Frita',                      95.00,  7)
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
