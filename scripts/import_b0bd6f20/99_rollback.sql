-- ============================================================================
-- ROLLBACK DE LA CARGA — business b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee
--
-- Deshace IMPORT_COMPLETO.sql:
--   * borra los productos NUEVOS de la lista (no los que ya estaban subidos);
--   * borra los grupos de modificadores de la carga (variantes y Extras) y
--     los quita de los productos ya subidos;
--   * a los ya subidos les devuelve el precio que tenían;
--   * vuelve a activar los que la carga desactivó (DELIVERY, extras);
--   * borra las categorías NUEVAS que queden vacías.
-- NO toca: la Ley copiada, las áreas Cocina/Bar, los impuestos y el área que
-- se les puso a los que ya estaban (antes no tenían impuesto y apuntaban a
-- 'kitchen_hot', un área que no existe: volver a eso es romperlos), ni los
-- montos rápidos del delivery.
--
-- ABORTA sin tocar nada si alguno de los productos nuevos o de las opciones
-- ya se vendió: en ese caso no se borra, se desactiva desde la app.
--
-- Este archivo lo arma build_import_b0bd6f20.py. No lo edites a mano.
-- ============================================================================

begin;

create or replace function pg_temp.k(t text) returns text
language sql immutable as $f$
  select btrim(regexp_replace(
           translate(lower(t), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'),
           '[^a-z0-9]+', ' ', 'g'))
$f$;

drop table if exists _b0_rb_productos;
create temp table _b0_rb_productos (name text not null);
insert into _b0_rb_productos (name) values
  ('MINI SOPES'),
  ('NACHOS 3 COMPADRES'),
  ('FAJITAS'),
  ('FLAUTAS DE PAPA Y CHORIZO'),
  ('GRINGA'),
  ('HUEVOS RANCHEROS'),
  ('HUEVOS RANCHEROS DIVORCIADOS'),
  ('SOPA DE TORTILLAS'),
  ('SOPES DE PAPA Y CHORIZO'),
  ('SOPES DE POLLO'),
  ('SOPES DE TINGA DE POLLO'),
  ('CHAMORRO DE CERDO'),
  ('TACOS A LA ZIMBRON'),
  ('TACOS DE COCHINITA PIBIL'),
  ('TACOS DE TINGA DE POLLO'),
  ('BROWNIE A LA MODA'),
  ('CHURROS'),
  ('PIE DE LIMÓN'),
  ('CANTARITO 400 CONEJOS'),
  ('CANTARITO GRAN CAVA EXTRA AÑEJO'),
  ('CANTARITO GRAND MAYAN EXTRA AÑEJO'),
  ('CANTARITO MEZCAL MITRE'),
  ('CANTARITO MONTELOBOS'),
  ('MARGARITA DE CHINOLA'),
  ('MARGARITA DE COCO'),
  ('MARGARITA DE FRESA'),
  ('MARGARITA DE LIMÓN'),
  ('MARGARITA DE TAMARINDO'),
  ('MARGARITA DE LIMÓN A LA ROCA'),
  ('CHELADA'),
  ('MICHELADA DE TAMARINDO'),
  ('MICHELADA DE MANGO'),
  ('MICHELADA TRADICIONAL'),
  ('MOJITO DE CHINOLA'),
  ('MOJITO DE COCO'),
  ('MOJITO DE FRESA'),
  ('MOJITO DE JAMAICA'),
  ('MOJITO DE LIMÓN'),
  ('APEROL SPRITZ'),
  ('AVERNA'),
  ('BAILEYS'),
  ('DIEGO RIVERA'),
  ('MEZCALITA'),
  ('PALOMA'),
  ('SANGRÍA DE JAMAICA'),
  ('TEQUILA SUNRISE'),
  ('DON JULIO AÑEJO (SHOT)'),
  ('DON JULIO REPOSADO (SHOT)'),
  ('FRANCISCO GONZALES EXTRA AÑEJO (SHOT)'),
  ('AMOR MÍO BLANCO (SHOT)'),
  ('CLASE AZUL REPOSADO (SHOT)'),
  ('GRAN CAVA DE ORO EXTRA VIEJO (SHOT)'),
  ('GRAND MAYAN EXTRA VIEJO (SHOT)'),
  ('1800 AÑEJO (SHOT)'),
  ('1800 REPOSADO (SHOT)'),
  ('1800 SILVER (SHOT)'),
  ('1800 ULTRA AÑEJO CRISTALINO (SHOT)'),
  ('AGAVITA REPOSADO (SHOT)'),
  ('AGAVITA SILVER (SHOT)'),
  ('GRAN MALO (SHOT)'),
  ('HERRADURA AÑEJO (SHOT)'),
  ('HERRADURA REPOSADO (SHOT)'),
  ('HERRADURA SILVER (SHOT)'),
  ('HERRADURA ULTRA AÑEJO (SHOT)'),
  ('JOSÉ CUERVO REPOSADO (SHOT)'),
  ('JOSÉ CUERVO SILVER (SHOT)'),
  ('CONTRALUZ MEZCAL'),
  ('MEZCAL 400 CONEJOS (SHOT)'),
  ('OJO DE TIGRE'),
  ('CHINOLA FROZEN'),
  ('FRESA FROZEN'),
  ('HORCHATA'),
  ('JUGO DE CEREZA'),
  ('JUGO DE CHINOLA'),
  ('JUGO DE FRUIT PUNCH'),
  ('JUGO DE LIMÓN'),
  ('LIMONADA DE COCO'),
  ('LIMONADA FROZEN'),
  ('TAMARINDO FROZEN'),
  ('TÉ DE JAMAICA'),
  ('CLAMATO'),
  ('CORONA'),
  ('HEINEKEN'),
  ('MODELO NEGRA'),
  ('MODELO RUBIA'),
  ('PRESIDENTE LIGHT'),
  ('PRESIDENTE NORMAL'),
  ('STELLA ARTOIS'),
  ('CARNES'),
  ('CAFÉ CON LECHE'),
  ('CORTADITO'),
  ('ESPRESSO'),
  ('FIESTÓN DE TACOS'),
  ('COMBO ROSARIO'),
  ('CACHETADAS'),
  ('CANTARITO 1800'),
  ('CANTARITO AGAVITA'),
  ('CANTARITO DON JULIO'),
  ('CANTARITO HERRADURA'),
  ('CANTARITO JOSÉ CUERVO'),
  ('MANGONADA'),
  ('PIÑA COLADA'),
  ('REFRESCO'),
  ('ARIZONA')
;

drop table if exists _b0_rb_grupos;
create temp table _b0_rb_grupos (name text not null);
insert into _b0_rb_grupos (name) values
  ('Tostadas · Tipo'),
  ('Enchilada · Tipo'),
  ('Cachetadas · Corte'),
  ('Cantarito 1800 · Tequila'),
  ('Cantarito Agavita · Tequila'),
  ('Cantarito Don Julio · Tequila'),
  ('Cantarito Herradura · Tequila'),
  ('Cantarito José Cuervo · Tequila'),
  ('Mangonada · Alcohol'),
  ('Piña Colada · Alcohol'),
  ('Jarritos · Sabor'),
  ('Refresco · Sabor'),
  ('Arizona · Sabor'),
  ('Refrescos Sabores · Sabor'),
  ('Soda Can · Sabor'),
  ('Extras')
;

drop table if exists _b0_rb_categorias;
create temp table _b0_rb_categorias (name text not null);
insert into _b0_rb_categorias (name) values
  ('SIN ALCOHOL'),
  ('CERVEZA'),
  ('CAFÉ'),
  ('CANTARITOS'),
  ('MARGARITAS'),
  ('MICHELADAS'),
  ('MOJITOS'),
  ('COCTELES'),
  ('MEZCAL'),
  ('DON JULIO RESERVA'),
  ('OTROS TEQUILAS EXCLUSIVOS'),
  ('OTROS TEQUILAS')
;

-- Lo que ya estaba en la caja antes de la carga (ver IMPORT_COMPLETO.sql).
drop table if exists _b0_rb_existentes;
create temp table _b0_rb_existentes (existente text not null, accion text not null,
                                     precio_antes numeric(12,2));
insert into _b0_rb_existentes (existente, accion, precio_antes) values
  ('BURRITO', 'ya_subido', 650.00),
  ('CHILAQUILES', 'ya_subido', 700.00),
  ('CHIMICHANGA', 'ya_subido', 700.00),
  ('CHORIQUESO', 'ya_subido', 600.00),
  ('FLAUTAS DE POLLO', 'ya_subido', 600.00),
  ('MINI FLAUTAS', 'ya_subido', 500.00),
  ('NACHOS CON GUACAMOLE', 'ya_subido', 250.00),
  ('QUESADILLA DE CHORIZO', 'ya_subido', 650.00),
  ('QUESADILLA DE POLLO', 'ya_subido', 600.00),
  ('TACOS', 'ya_subido', 650.00),
  ('TACOS AL PASTOR', 'ya_subido', 700.00),
  ('TACOS CHILORIO', 'ya_subido', 700.00),
  ('TACOS DE BIRRIA', 'ya_subido', 750.00),
  ('TACOS DE CARNITA MICHOACAN', 'ya_subido', 650.00),
  ('UNIDAD DE TACO', 'ya_subido', 250.00),
  ('TOSTADAS', 'ya_subido', 650.00),
  ('ENCHILADA', 'ya_subido', 800.00),
  ('AGUA', 'ya_subido', 50.00),
  ('JARRITOS', 'ya_subido', 175.00),
  ('JUGOS NATURALES', 'ya_subido', 0.00),
  ('REFRESCOS', 'ya_subido', 0.00),
  ('SODA CAN', 'ya_subido', 0.00),
  ('ENCHILADA SUIZA', 'mantener', null),
  ('DELIVERY 100', 'desactivar', null),
  ('DELIVERY 150', 'desactivar', null),
  ('DELIVERY 200', 'desactivar', null),
  ('DELIVERY 250', 'desactivar', null),
  ('DELIVERY 300', 'desactivar', null),
  ('DELIVERY 350', 'desactivar', null),
  ('DELIVERY 400', 'desactivar', null),
  ('DELIVERY 450', 'desactivar', null),
  ('EXTRA GUACAMOLE', 'desactivar', null),
  ('Extra Queso', 'desactivar', null),
  ('EXTRA DE CARNE', 'desactivar', null),
  ('Extra Nachos', 'desactivar', null),
  ('TACO DOBLE DECKERS', 'fuera_csv', null),
  ('TACOS FIESTAS', 'fuera_csv', null),
  ('GANSITO MARINELA GRANDE', 'fuera_csv', null),
  ('Carne Cocida Natural xlb', 'fuera_csv', null);

do $$
declare
  v_business uuid := 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee';
  v_n        int;
  v_list     text;
begin
  -- Productos nuevos de la carga: los de la lista que no estaban subidos.
  drop table if exists _b0_rb_ids;
  create temp table _b0_rb_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _b0_rb_productos p on pg_temp.k(p.name) = pg_temp.k(mi.name)
  where mi.business_id = v_business
    and not exists (select 1 from _b0_rb_existentes e
                    where pg_temp.k(e.existente) = pg_temp.k(mi.name));

  drop table if exists _b0_rb_gids;
  create temp table _b0_rb_gids on commit drop as
  select g.id, g.name
  from public.modifier_groups g
  join _b0_rb_grupos x on pg_temp.k(x.name) = pg_temp.k(g.name)
  where g.business_id = v_business;

  -- ¿Algo vendido?
  select string_agg(i.name, ', ') into v_list
  from _b0_rb_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);
  if v_list is not null then
    raise exception 'Estos productos ya se vendieron, no se borran (desactívalos en la app): %', v_list;
  end if;

  if exists (select 1 from pg_attribute
             where attrelid = 'public.order_item_modifiers'::regclass
               and attname = 'modifier_id' and not attisdropped) then
    execute $q$
      select string_agg(distinct g.name || ' · ' || m.name, ', ')
      from public.order_item_modifiers om
      join public.modifiers m on m.id = om.modifier_id
      join _b0_rb_gids g on g.id = m.group_id
    $q$ into v_list;
    if v_list is not null then
      raise exception 'Estas opciones ya se vendieron, no se borran: %', v_list;
    end if;
  end if;

  -- Productos nuevos.
  delete from public.menu_item_groups      x using _b0_rb_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _b0_rb_ids i where x.item_id = i.id;
  delete from public.menu_item_print_areas x using _b0_rb_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_links       x using _b0_rb_ids i where x.item_id = i.id;
  delete from public.menu_items           mi using _b0_rb_ids i where mi.id = i.id;
  get diagnostics v_n = row_count;

  -- Grupos de modificadores de la carga (también salen de los ya subidos).
  delete from public.menu_item_groups x using _b0_rb_gids g where x.group_id = g.id;
  delete from public.modifiers        m using _b0_rb_gids g where m.group_id = g.id;
  delete from public.modifier_groups  x using _b0_rb_gids g where x.id = g.id;

  -- Los ya subidos vuelven a su precio.
  update public.menu_items mi set price = e.precio_antes, updated_at = now()
  from _b0_rb_existentes e
  where e.accion = 'ya_subido' and e.precio_antes is not null
    and mi.business_id = v_business and pg_temp.k(mi.name) = pg_temp.k(e.existente)
    and mi.price is distinct from e.precio_antes;

  -- Los que la carga desactivó.
  update public.menu_items mi set is_active = true, updated_at = now()
  from _b0_rb_existentes e
  where e.accion = 'desactivar' and mi.business_id = v_business
    and pg_temp.k(mi.name) = pg_temp.k(e.existente) and not mi.is_active;

  -- Categorías nuevas de la carga que quedaron vacías.
  delete from public.categories c
  using _b0_rb_categorias x
  where c.business_id = v_business and pg_temp.k(c.name) = pg_temp.k(x.name)
    and not exists (select 1 from public.menu_items mi where mi.category_id = c.id);

  raise notice 'Rollback: % productos borrados, % grupos de modificadores borrados.',
    v_n, (select count(*) from _b0_rb_gids);
end $$;

commit;

select 'productos de la lista que quedan' as concepto,
       (select count(*) from public.menu_items mi
        join _b0_rb_productos p on pg_temp.k(p.name) = pg_temp.k(mi.name)
        where mi.business_id = 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee')::text as valor,
       'solo los ya subidos' as esperado
union all
select 'grupos de modificadores de la carga',
       (select count(*) from public.modifier_groups g
        join _b0_rb_grupos x on pg_temp.k(x.name) = pg_temp.k(g.name)
        where g.business_id = 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee')::text,
       '0';
