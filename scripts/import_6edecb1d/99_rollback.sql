-- ============================================================================
-- TÍA SARA — ROLLBACK de IMPORT_COMPLETO.sql
-- Business 6edecb1d-e940-45ff-83b5-044ca08319fb
-- ============================================================================
--
-- Borra los 24 productos del menú, sus 5 grupos de modificadores y las
-- categorías que queden vacías. NO borra el área de comanda ni el menú (si el
-- import los creó, quedan vacíos y el próximo import los reusa).
--
-- ⚠ ABORTA SI YA SE VENDIÓ. order_items.product_id es ON DELETE RESTRICT: un
--   producto con ventas no se puede borrar sin romper el histórico. En ese
--   caso desactívalo (is_active = false) en vez de borrarlo.
-- ⚠ ABORTA si los grupos de modificadores los usa también otro producto que
--   no es de este menú.
-- ============================================================================

begin;

do $$
declare
  v_business uuid := '6edecb1d-e940-45ff-83b5-044ca08319fb';
  v_n        int;
  v_list     text;
begin
  create temp table _ts_nombres (name text not null) on commit drop;
  insert into _ts_nombres (name) values
    ('Tía Sara 1'), ('Tía Sara 2'), ('Tía Sara Simple'), ('Tía Sara Feliz'),
    ('Tía Sara Súper Familiar'),
    ('Pechu Tía 6 Piezas'), ('Pechu Tía 8 Piezas'),
    ('Pica Pollo 2 Piezas'), ('Pica Pollo 3 Piezas'),
    ('Pica Pollo 4 Piezas'), ('Pica Pollo 5 Piezas'),
    ('Alitas 5 Piezas'), ('Alitas 6 Piezas'), ('Alitas 8 Piezas'),
    ('Alitas con Salsa Barbacoa'), ('Alitas Honey Mustard'),
    ('Tía Americana Buffalo'), ('Tía Pops'),
    ('Papas Fritas'), ('Tostones'), ('Palitos de Yuca'),
    ('Salsa La Sobrina'), ('Salsa Especial Tía Sara'), ('Salsa Wasakaka');

  create temp table _ts_grupos_rb (name text not null) on commit drop;
  insert into _ts_grupos_rb (name) values
    ('Muslo'), ('Acompañamiento 1'), ('Acompañamiento 2'),
    ('Acompañamiento 3'), ('Acompañamiento 4');

  create temp table _ts_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _ts_nombres s on lower(btrim(mi.name)) = lower(s.name)
  where mi.business_id = v_business;

  -- 1) Nada vendido.
  select count(*), string_agg(i.name, ', ')
    into v_n, v_list
  from _ts_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);

  if v_n > 0 then
    raise exception
      'ABORTADO: % productos ya tienen ventas (%). Borrarlos rompería el '
      'histórico. Desactívalos en vez de borrarlos.', v_n, v_list;
  end if;

  -- 2) Los grupos no los usa nadie fuera de este menú.
  select string_agg(distinct g.name, ', ')
    into v_list
  from public.modifier_groups g
  join _ts_grupos_rb r on lower(r.name) = lower(btrim(g.name))
  join public.menu_item_groups y on y.group_id = g.id
  where g.business_id = v_business
    and y.menu_item_id not in (select id from _ts_ids);

  if v_list is not null then
    raise exception
      'ABORTADO: los grupos % también los usan otros productos. '
      'Quítaselos a esos productos primero.', v_list;
  end if;

  -- 3) Modificadores. Se borra explícito por si algún entorno no tuviera el
  --    cascade.
  delete from public.menu_item_groups y
  using public.modifier_groups g
  join _ts_grupos_rb r on lower(r.name) = lower(btrim(g.name))
  where y.group_id = g.id and g.business_id = v_business;

  delete from public.modifiers m
  using public.modifier_groups g
  join _ts_grupos_rb r on lower(r.name) = lower(btrim(g.name))
  where m.group_id = g.id and g.business_id = v_business;

  delete from public.modifier_groups g
  using _ts_grupos_rb r
  where g.business_id = v_business and lower(r.name) = lower(btrim(g.name));

  -- 4) Productos, con sus vínculos.
  delete from public.menu_item_links      x using _ts_ids i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _ts_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes      x using _ts_ids i where x.item_id      = i.id;
  delete from public.menu_items          mi using _ts_ids i where mi.id          = i.id;

  -- 5) Categorías del menú, solo si quedaron vacías.
  delete from public.categories c
  where c.business_id = v_business
    and lower(btrim(c.name)) in (
      'combos tía sara', 'pechu tía', 'pica pollo', 'alitas de pollo',
      'extra tía sara', 'tía pops', 'agranda tu orden', 'salsas')
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);
end $$;

commit;

-- Verificación: los tres deben dar 0 (si el negocio no tenía nada antes).
select
  (select count(*) from public.menu_items
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid) as productos,
  (select count(*) from public.categories
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid) as categorias,
  (select count(*) from public.modifier_groups
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid) as grupos;
