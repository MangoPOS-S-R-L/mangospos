-- ============================================================================
-- ESTANCIA NUEVA SPORT · TIENDA — ROLLBACK de IMPORT_TIENDA.sql
-- Business __BID__
--
-- ⚠ ARCHIVO GENERADO por build_import_tienda.py desde _tpl_rollback_tienda.sql.
-- ============================================================================
--
-- Borra los __N_TOTAL__ artículos de la lista (por sku = código), sus insumos y las
-- categorías de la carga que queden vacías. NO borra el menú ni la bodega, NO
-- regresa inventory_mode, y NO toca lo que la tienda ya tenía antes.
--
-- ⚠ ABORTA si algún artículo ya se vendió, o si algún insumo ya tiene
--   movimientos, está en un conteo o en una receta, o lo usa otro producto.
-- ============================================================================

begin;

create temp table _tie_codigos (codigo text primary key) on commit drop;

insert into _tie_codigos (codigo)
select unnest(string_to_array(
  '__CODES__', ','));

do $$
declare
  v_business uuid := '__BID__';
  v_n        int;
  v_list     text;
  v_items    int;
  v_insumos  int;
begin
  create temp table _tie_ids on commit drop as
  select mi.id, mi.name
  from public.menu_items mi
  join _tie_codigos c on c.codigo = mi.sku
  where mi.business_id = v_business;

  create temp table _tie_insumos on commit drop as
  select ii.id, ii.name
  from public.inventory_items ii
  join _tie_codigos c on c.codigo = ii.sku
  where ii.business_id = v_business;

  select count(*), string_agg(i.name, ', ')
    into v_n, v_list
  from _tie_ids i
  where exists (select 1 from public.order_items oi where oi.product_id = i.id);
  if v_n > 0 then
    raise exception
      'ABORTADO: % artículos ya tienen ventas (%). Desactívalos en vez de borrarlos.',
      v_n, v_list;
  end if;

  select count(distinct s.id), string_agg(distinct s.name, ', ')
    into v_n, v_list
  from _tie_insumos s
  join public.inventory_movements m on m.item_id = s.id;
  if v_n > 0 then
    raise exception
      'ABORTADO: % insumos ya tienen movimientos de inventario (%).', v_n, v_list;
  end if;

  select count(distinct s.id), string_agg(distinct s.name, ', ')
    into v_n, v_list
  from _tie_insumos s
  where exists (select 1 from public.physical_count_lines l where l.item_id = s.id)
     or exists (select 1 from public.recipe_ingredients ri where ri.inventory_item_id = s.id);
  if v_n > 0 then
    raise exception
      'ABORTADO: % insumos ya están en un conteo o en una receta (%).', v_n, v_list;
  end if;

  select string_agg(distinct s.name, ', ')
    into v_list
  from _tie_insumos s
  join public.menu_items mi on mi.inventory_item_id = s.id
  where mi.id not in (select id from _tie_ids);
  if v_list is not null then
    raise exception
      'ABORTADO: otros productos usan los insumos %. Quítaselos primero.', v_list;
  end if;

  delete from public.menu_item_links       x using _tie_ids i where x.item_id      = i.id;
  delete from public.menu_item_print_areas x using _tie_ids i where x.menu_item_id = i.id;
  delete from public.menu_item_taxes       x using _tie_ids i where x.item_id      = i.id;
  delete from public.menu_items           mi using _tie_ids i where mi.id          = i.id;
  get diagnostics v_items = row_count;

  delete from public.inventory_stock     st using _tie_insumos s where st.item_id = s.id;
  delete from public.inventory_items     ii using _tie_insumos s where ii.id      = s.id;
  get diagnostics v_insumos = row_count;

  delete from public.categories c
  where c.business_id = v_business
    and lower(btrim(c.name)) in (__CAT_NAMES_LOWER__)
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);

  raise notice 'Rollback: % artículos y % insumos borrados.', v_items, v_insumos;
end $$;

commit;

select
  (select count(*) from public.menu_items
     where business_id = '__BID__'::uuid) as productos_que_quedan,
  (select count(*) from public.inventory_items
     where business_id = '__BID__'::uuid) as insumos_que_quedan;
