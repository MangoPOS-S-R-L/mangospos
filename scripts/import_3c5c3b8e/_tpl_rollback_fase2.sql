-- ============================================================================
-- 007 BAR & SNACK, SRL — ROLLBACK de IMPORT_FASE2.sql
-- Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- ⚠ ARCHIVO GENERADO por build_fase2_3c5c3b8e.py desde _tpl_rollback_fase2.sql.
-- ============================================================================
--
-- Borra los __N_TOTAL__ productos de la fase 2 (emparejados por sku = código), sus
-- insumos, su existencia inicial y las categorías NUEVAS de esta fase si quedan
-- vacías (__CAT_NUEVAS__).
-- NO toca los productos de la fase 1 y NO les regresa la posición anterior (es
-- solo el orden dentro de la categoría).
--
-- ⚠ ABORTA SI YA SE VENDIÓ. order_items.product_id es ON DELETE RESTRICT: un
--   producto con ventas no se borra sin romper el histórico. Desactívalo.
-- ⚠ ABORTA si algún insumo ya tiene movimientos que no son la existencia
--   inicial (venta, compra, ajuste, conteo) o si lo usa otro producto.
-- ============================================================================

begin;

create temp table _p007f2_codigos (codigo text primary key) on commit drop;

insert into _p007f2_codigos (codigo)
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
  create temp table _p007f2_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _p007f2_codigos c on c.codigo = mi.sku
  where mi.business_id = v_business;

  create temp table _p007f2_insumos on commit drop as
  select ii.id, ii.name
  from public.inventory_items ii
  join _p007f2_codigos c on c.codigo = ii.sku
  where ii.business_id = v_business;

  -- 1) Nada vendido.
  select count(*), string_agg(i.name, ', ')
    into v_n, v_list
  from _p007f2_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);

  if v_n > 0 then
    raise exception
      'ABORTADO: % productos ya tienen ventas (%). Borrarlos rompería el '
      'histórico. Desactívalos en vez de borrarlos.', v_n, v_list;
  end if;

  -- 2) Los insumos solo tienen la existencia inicial.
  select count(distinct s.id), string_agg(distinct s.name, ', ')
    into v_n, v_list
  from _p007f2_insumos s
  join public.inventory_movements m on m.item_id = s.id
  where coalesce(m.reference_type, '') <> 'initial_stock';

  if v_n > 0 then
    raise exception
      'ABORTADO: % insumos ya tienen movimientos además de la existencia '
      'inicial (%). Hay historia de inventario que se perdería.', v_n, v_list;
  end if;

  -- 3) Ningún producto fuera de la fase 2 usa esos insumos.
  select string_agg(distinct s.name, ', ')
    into v_list
  from _p007f2_insumos s
  join public.menu_items mi on mi.inventory_item_id = s.id
  where mi.id not in (select id from _p007f2_ids);

  if v_list is not null then
    raise exception
      'ABORTADO: otros productos usan los insumos %. Quítaselos primero.', v_list;
  end if;

  -- 4) Productos, con sus vínculos.
  delete from public.menu_item_links       x using _p007f2_ids i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _p007f2_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _p007f2_ids i where x.item_id      = i.id;
  delete from public.menu_items           mi using _p007f2_ids i where mi.id          = i.id;
  get diagnostics v_items = row_count;

  -- 5) Insumos, su existencia y su movimiento inicial.
  delete from public.inventory_stock     st using _p007f2_insumos s where st.item_id = s.id;
  delete from public.inventory_movements  m using _p007f2_insumos s
   where m.item_id = s.id and m.reference_type = 'initial_stock';
  delete from public.inventory_items     ii using _p007f2_insumos s where ii.id      = s.id;
  get diagnostics v_insumos = row_count;

  -- 6) Solo las categorías NUEVAS de esta fase, y solo si quedaron vacías.
  delete from public.categories c
  where c.business_id = v_business
    and lower(btrim(c.name)) in (__CAT_NUEVAS_LOWER__)
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);

  raise notice 'Rollback fase 2: % productos y % insumos borrados.', v_items, v_insumos;
end $$;

commit;

-- Verificación: productos de la fase 2 que quedan (0) y catálogo total.
select
  (select count(*) from public.menu_items mi
     where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
       and mi.sku = any (string_to_array('__CODES__', ','))) as productos_fase2,
  (select count(*) from public.menu_items
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as productos_total,
  (select count(*) from public.inventory_items
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as insumos_total;
