-- ============================================================================
-- 007 BAR & SNACK, SRL — ROLLBACK de IMPORT_COMPLETO.sql
-- Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- ⚠ ARCHIVO GENERADO por build_import_3c5c3b8e.py desde _tpl_rollback.sql.
-- ============================================================================
--
-- Borra los __N_TOTAL__ productos del listado (emparejados por sku = código), sus
-- insumos, su existencia inicial y las categorías que queden vacías.
-- NO borra el menú ni la bodega, y NO regresa inventory_mode a 'none'.
--
-- ⚠ ABORTA SI YA SE VENDIÓ. order_items.product_id es ON DELETE RESTRICT: un
--   producto con ventas no se borra sin romper el histórico. Desactívalo.
-- ⚠ ABORTA si algún insumo ya tiene movimientos que no son la existencia
--   inicial (venta, compra, ajuste, conteo) o si lo usa otro producto.
-- ============================================================================

begin;

create temp table _p007_codigos (codigo text primary key) on commit drop;

insert into _p007_codigos (codigo)
select unnest(string_to_array(
  '__CODES__', ','));

do $$
declare
  v_business uuid := '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c';
  v_n        int;
  v_list     text;
  v_items    int;
  v_insumos  int;
begin
  create temp table _p007_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _p007_codigos c on c.codigo = mi.sku
  where mi.business_id = v_business;

  create temp table _p007_insumos on commit drop as
  select ii.id, ii.name
  from public.inventory_items ii
  join _p007_codigos c on c.codigo = ii.sku
  where ii.business_id = v_business;

  -- 1) Nada vendido.
  select count(*), string_agg(i.name, ', ')
    into v_n, v_list
  from _p007_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);

  if v_n > 0 then
    raise exception
      'ABORTADO: % productos ya tienen ventas (%). Borrarlos rompería el '
      'histórico. Desactívalos en vez de borrarlos.', v_n, v_list;
  end if;

  -- 2) Los insumos solo tienen la existencia inicial.
  select count(distinct s.id), string_agg(distinct s.name, ', ')
    into v_n, v_list
  from _p007_insumos s
  join public.inventory_movements m on m.item_id = s.id
  where coalesce(m.reference_type, '') <> 'initial_stock';

  if v_n > 0 then
    raise exception
      'ABORTADO: % insumos ya tienen movimientos además de la existencia '
      'inicial (%). Hay historia de inventario que se perdería.', v_n, v_list;
  end if;

  -- 3) Ningún producto fuera del listado usa esos insumos.
  select string_agg(distinct s.name, ', ')
    into v_list
  from _p007_insumos s
  join public.menu_items mi on mi.inventory_item_id = s.id
  where mi.id not in (select id from _p007_ids);

  if v_list is not null then
    raise exception
      'ABORTADO: otros productos usan los insumos %. Quítaselos primero.', v_list;
  end if;

  -- 4) Productos, con sus vínculos.
  delete from public.menu_item_links       x using _p007_ids i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _p007_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _p007_ids i where x.item_id      = i.id;
  delete from public.menu_items           mi using _p007_ids i where mi.id          = i.id;
  get diagnostics v_items = row_count;

  -- 5) Insumos, su existencia y su movimiento inicial.
  delete from public.inventory_stock     st using _p007_insumos s where st.item_id = s.id;
  delete from public.inventory_movements  m using _p007_insumos s
   where m.item_id = s.id and m.reference_type = 'initial_stock';
  delete from public.inventory_items     ii using _p007_insumos s where ii.id      = s.id;
  get diagnostics v_insumos = row_count;

  -- 6) Categorías de la carga, solo si quedaron vacías.
  delete from public.categories c
  where c.business_id = v_business
    and lower(btrim(c.name)) in (__CAT_NAMES_LOWER__)
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);

  raise notice 'Rollback: % productos y % insumos borrados.', v_items, v_insumos;
end $$;

commit;

-- Verificación: los tres deben dar 0 (si el negocio no tenía nada antes).
select
  (select count(*) from public.menu_items
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as productos,
  (select count(*) from public.inventory_items
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as insumos,
  (select count(*) from public.categories
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as categorias;
