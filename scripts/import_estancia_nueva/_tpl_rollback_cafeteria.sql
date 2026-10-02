-- ============================================================================
-- ESTANCIA NUEVA SPORT · CAFETERÍA — ROLLBACK de IMPORT_CAFETERIA.sql
-- Business __BID__
--
-- ⚠ ARCHIVO GENERADO por build_import_cafeteria.py desde _tpl_rollback_cafeteria.sql.
-- ============================================================================
--
-- Borra los __N_TOTAL__ productos de la lista (emparejados por sku = código), sus
-- insumos, los __N_INSUMOS__ insumos de cocina y las categorías que queden vacías.
-- NO borra el menú ni la bodega, y NO regresa inventory_mode a 'none'.
--
-- ⚠ ABORTA SI YA SE VENDIÓ. order_items.product_id es ON DELETE RESTRICT: un
--   producto con ventas no se borra sin romper el histórico. Desactívalo.
-- ⚠ ABORTA si algún insumo ya tiene movimientos (venta, compra, ajuste), está
--   en un conteo o en una receta, o lo usa un producto que no es de la lista.
-- ============================================================================

begin;

create temp table _pen_codigos (codigo text primary key) on commit drop;

insert into _pen_codigos (codigo)
select unnest(string_to_array(
  '__CODES__', ','));

create temp table _pen_ins_codigos (codigo text primary key) on commit drop;

insert into _pen_ins_codigos (codigo)
select unnest(string_to_array('__INS_CODES__', ','));

do $$
declare
  v_business uuid := '__BID__';
  v_n        int;
  v_list     text;
  v_items    int;
  v_insumos  int;
begin
  create temp table _pen_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _pen_codigos c on c.codigo = mi.sku
  where mi.business_id = v_business;

  create temp table _pen_insumos on commit drop as
  select ii.id, ii.name
  from public.inventory_items ii
  where ii.business_id = v_business
    and (ii.sku in (select codigo from _pen_codigos)
         or ii.sku in (select codigo from _pen_ins_codigos));

  -- 1) Nada vendido.
  select count(*), string_agg(i.name, ', ')
    into v_n, v_list
  from _pen_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);

  if v_n > 0 then
    raise exception
      'ABORTADO: % productos ya tienen ventas (%). Borrarlos rompería el '
      'histórico. Desactívalos en vez de borrarlos.', v_n, v_list;
  end if;

  -- 2) Los insumos no tienen historia: la carga no registra ningún movimiento.
  select count(distinct s.id), string_agg(distinct s.name, ', ')
    into v_n, v_list
  from _pen_insumos s
  join public.inventory_movements m on m.item_id = s.id;

  if v_n > 0 then
    raise exception
      'ABORTADO: % insumos ya tienen movimientos de inventario (%). Hay '
      'historia que se perdería.', v_n, v_list;
  end if;

  select count(distinct s.id), string_agg(distinct s.name, ', ')
    into v_n, v_list
  from _pen_insumos s
  where exists (select 1 from public.physical_count_lines l where l.item_id = s.id)
     or exists (select 1 from public.recipe_ingredients ri where ri.inventory_item_id = s.id);

  if v_n > 0 then
    raise exception
      'ABORTADO: % insumos ya están en un conteo o en una receta (%).', v_n, v_list;
  end if;

  -- 3) Ningún producto fuera de la lista usa esos insumos.
  select string_agg(distinct s.name, ', ')
    into v_list
  from _pen_insumos s
  join public.menu_items mi on mi.inventory_item_id = s.id
  where mi.id not in (select id from _pen_ids);

  if v_list is not null then
    raise exception
      'ABORTADO: otros productos usan los insumos %. Quítaselos primero.', v_list;
  end if;

  -- 4) Productos, con sus vínculos.
  delete from public.menu_item_links       x using _pen_ids i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _pen_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _pen_ids i where x.item_id      = i.id;
  delete from public.menu_items           mi using _pen_ids i where mi.id          = i.id;
  get diagnostics v_items = row_count;

  -- 5) Insumos (sin movimientos, así que tampoco tienen stock).
  delete from public.inventory_stock     st using _pen_insumos s where st.item_id = s.id;
  delete from public.inventory_items     ii using _pen_insumos s where ii.id      = s.id;
  get diagnostics v_insumos = row_count;

  -- 6) Categorías de la carga, solo si quedaron vacías.
  delete from public.categories c
  where c.business_id = v_business
    and lower(btrim(c.name)) in (__CAT_NAMES_LOWER__)
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);

  raise notice 'Rollback: % productos y % insumos borrados.', v_items, v_insumos;
end $$;

commit;

-- Verificación: los tres deben dar 0 (el negocio estaba vacío antes de la carga).
select
  (select count(*) from public.menu_items
     where business_id = '__BID__'::uuid) as productos,
  (select count(*) from public.inventory_items
     where business_id = '__BID__'::uuid) as insumos,
  (select count(*) from public.categories
     where business_id = '__BID__'::uuid) as categorias;
