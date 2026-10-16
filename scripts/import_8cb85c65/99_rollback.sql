-- ============================================================================
-- EL RINCÓN DE ADDA — ROLLBACK DE LA CARGA DEL MENÚ
-- Business 8cb85c65-ae49-4384-a678-0d8a201a955e
--
-- Borra los productos de la carta (los identifica por nombre, sin mayúsculas
-- ni tildes), los grupos de modificadores de la carga que queden sin
-- productos y las categorías de la carga que queden vacías. Deja en pie el
-- menú, las áreas de comanda y los impuestos: la próxima carga los reusa.
--
-- ABORTA sin tocar nada si alguno ya se vendió (order_items.product_id es
-- ON DELETE RESTRICT): un producto vendido se DESACTIVA en la app, no se borra.
--
-- No toca AGUA DASANI ni Limonada Natural (antes JUGO DE LIMON): ya existían
-- antes de la carga. Tampoco les devuelve el nombre, la categoría ni los
-- impuestos que tenían.
-- OJO: si el catálogo ya tenía algún otro de estos productos o grupos antes
-- de la carga (sección 6 del diagnóstico), este rollback también los borra.
-- Este archivo lo arma build_import_8cb85c65.py. No lo edites a mano.
-- ============================================================================

begin;

create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

do $$
declare
  v_business uuid := '8cb85c65-ae49-4384-a678-0d8a201a955e';
  v_nombres  text[] := array[
    'Carpaccio de Lomito',
    'Aros de Calamar Rebozados',
    'Bruquetas de Camarón',
    'Bruquetas Caprese',
    'Croquetas de Pollo',
    'Focaccia',
    'Ensalada Verde',
    'Ensalada Caprese',
    'Ensalada César',
    'Ensalada César con Pollo',
    'Ensalada César con Camarones',
    'Ensalada de Aguacate',
    'Pasta Alfredo',
    'Pasta Carbonara',
    'Pasta Marinara',
    'Pasta Caprese',
    'Pasta a la Crema',
    'Pasta Cuatro Quesos',
    'Pizza Romana',
    'Pizza Prosciutto e Funghi',
    'Pizza Prosciutto',
    'Pizza Caprese',
    'Pizza de Vegetales',
    'Pizza Pepperoni',
    'Pizza Cuatro Quesos',
    'Pizza Marinera',
    'Pizza Chicken Crispy',
    'Pizza El Rincón de Adda',
    'Pizza de Atún y Cebolla',
    'Churrasco Prime Importado',
    'Flap Meat Prime Angus',
    'Picaña Prime Importada',
    'Ribeye Prime Importado',
    'T-Bone Angus Choice Importado',
    'Tomahawk Angus Choice Importado (2.5 lb)',
    'Pollo a la Plancha',
    'Pechuga de Pollo a la Crema',
    'Pollo a la Torre',
    'Lomo de Cerdo',
    'Chuleta de Cerdo',
    'Costillas de Cerdo',
    'Chillo Entero',
    'Filete de Mero Barsa',
    'Lomo de Atún Rojo',
    'Filete de Salmón',
    'Filete de Salmón en Salsa de Ajo',
    'Lambí',
    'Ceviche de Mero',
    'Masa de Cangrejo',
    'Camarones',
    'Pulpo',
    'Calamar a la Plancha',
    'Aros de Calamar Salteados',
    'Cola de Langosta',
    'Cazuela de Mariscos',
    'Sopa de Mariscos',
    'Salpicón de Mariscos',
    'Lambí y Pulpo',
    'Mejillones al Vapor',
    'Parrillada Mar y Tierra (2 personas)',
    'Parrillada Mixta (2 personas)',
    'Parrillada de Mariscos (2 personas)',
    'Paella (2 personas)',
    'Mofongo de Camarones',
    'Mofongo de Pollo',
    'Arroz Blanco',
    'Vegetales',
    'Papas',
    'Tostones',
    'Pan con Ajo',
    'Addana Apple',
    'Addita',
    'Papá Chelo',
    'La Ex',
    'La Rabiosa',
    'La Insoportable',
    'Piña Colada',
    'Watermelon Sunset',
    'Wild Forest',
    'Ruso Blanco',
    'Ruso Negro',
    'Vodka Sunrise',
    'Vodka Tonic',
    'Screwdriver',
    'Pink Tonic',
    'Gin Tonic',
    'Mojito de Pitahaya',
    'Mojito de Limón',
    'Mojito de Morir Soñando',
    'Mojito de Chinola',
    'Margarita de Limón',
    'Margarita de Fresa',
    'Margarita de Chinola',
    'Cuba Libre',
    'Cuba Libre Doble Reserva',
    'Smoothie de Fresa',
    'Limonada Coco',
    'Sangría',
    'Frozen',
    'Shot de Canelilla',
    'Shot de Barceló',
    'Shot de Baileys',
    'Shot de Tequila',
    'Trago Johnnie Walker Black Label',
    'Trago Old Parr',
    'Trago Jack Daniel''s',
    'Porto Tinto',
    'Casillero del Diablo Tinto Merlot',
    'Bogle Tinto',
    'Casillero del Diablo Cabernet Tinto',
    '19 Crimes',
    'Carlo Rossi',
    'Copa de Vino de la Casa',
    'Copa de Vino Porto',
    'Copa de Vino 19 Crimes',
    'Copa de Vino Casillero del Diablo',
    'Copa de Vino Bogle',
    'Cerveza Corona',
    'Cerveza Presidente',
    'Cerveza Smirnoff',
    'Cerveza Modelo',
    'Jugo de Sandía con Limón',
    'Jugo de Chinola',
    'Jugo de Piña',
    'Café Negro',
    'Enriquillo',
    'Agua Tónica',
    'Refresco Coca Cola Peq.',
    'Refresco Merengue Peq.',
    'Refresco Naranja Peq.',
    'Refresco Seven Up Peq.',
    'Refresco Sprite Peq.',
    'Refresco Coca Cola 2 Litros'
  ];
  v_grupos   text[] := array[
    'Tipo de pasta',
    'Proteína para la pasta',
    'Término de la carne',
    'Plancha o parrilla',
    'Frito o al vapor',
    'Preparación del marisco',
    'Salsa a elegir',
    'Vegetales',
    'Papas',
    'Con o sin alcohol'
  ];
  v_cats     text[] := array[
    'ENTRADAS',
    'ENSALADAS',
    'PASTAS',
    'PIZZAS',
    'CARNES',
    'PESCADOS Y MARISCOS',
    'ESPECIALIDADES',
    'GUARNICIONES',
    'TRAGOS PROPIOS',
    'TRAGOS TRADICIONALES',
    'SHOTS',
    'VINOS',
    'CERVEZAS',
    'BEBIDAS'
  ];
  v_n        int;
  v_g        int;
  v_list     text;
begin
  select count(*), string_agg(mi.name, ', ' order by mi.name)
    into v_n, v_list
  from public.menu_items mi
  where mi.business_id = v_business
    and pg_temp.norm(mi.name) in (select pg_temp.norm(x) from unnest(v_nombres) x)
    and exists (select 1 from public.order_items oi where oi.product_id = mi.id);

  if v_n > 0 then
    raise exception
      'No se borra nada: % productos de la carga ya tienen ventas (%). Desactívalos en la app.',
      v_n, v_list;
  end if;

  delete from public.menu_item_groups y
  using public.menu_items mi
  where y.menu_item_id = mi.id
    and mi.business_id = v_business
    and pg_temp.norm(mi.name) in (select pg_temp.norm(x) from unnest(v_nombres) x);

  delete from public.menu_items mi
  where mi.business_id = v_business
    and pg_temp.norm(mi.name) in (select pg_temp.norm(x) from unnest(v_nombres) x);
  get diagnostics v_n = row_count;

  delete from public.modifiers m
  using public.modifier_groups g
  where m.group_id = g.id
    and g.business_id = v_business
    and pg_temp.norm(g.name) in (select pg_temp.norm(x) from unnest(v_grupos) x)
    and not exists (select 1 from public.menu_item_groups y where y.group_id = g.id);

  delete from public.modifier_groups g
  where g.business_id = v_business
    and pg_temp.norm(g.name) in (select pg_temp.norm(x) from unnest(v_grupos) x)
    and not exists (select 1 from public.menu_item_groups y where y.group_id = g.id)
    and not exists (select 1 from public.modifiers m where m.group_id = g.id);
  get diagnostics v_g = row_count;

  delete from public.categories c
  where c.business_id = v_business
    and pg_temp.norm(c.name) in (select pg_temp.norm(x) from unnest(v_cats) x)
    and not exists (select 1 from public.menu_items mi where mi.category_id = c.id);

  raise notice 'Rollback: % productos y % grupos de modificadores borrados.', v_n, v_g;
end $$;

commit;

select
  (select count(*) from public.menu_items
   where business_id = '8cb85c65-ae49-4384-a678-0d8a201a955e'::uuid) as productos_que_quedan,
  (select count(*) from public.modifier_groups
   where business_id = '8cb85c65-ae49-4384-a678-0d8a201a955e'::uuid) as grupos_que_quedan,
  (select count(*) from public.categories
   where business_id = '8cb85c65-ae49-4384-a678-0d8a201a955e'::uuid) as categorias_que_quedan;
