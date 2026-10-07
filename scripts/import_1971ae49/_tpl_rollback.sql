-- ============================================================================
-- CAFETERIA MARICELA — ROLLBACK DE LA CARGA DEL CATÁLOGO
-- Business 1971ae49-935c-464a-9bfc-131d76a63be3
--
-- Borra los 111 productos de la carga (los identifica por SKU = código del
-- PDF) y las categorías de la carga que queden vacías. Deja en pie el menú y
-- las áreas de comanda: la próxima carga los reusa.
--
-- ABORTA sin tocar nada si alguno ya se vendió (order_items.product_id es
-- ON DELETE RESTRICT): un producto vendido se DESACTIVA en la app, no se borra.
--
-- OJO: si el catálogo ya tenía alguno de estos productos antes de la carga
-- (sección 6 del diagnóstico), este rollback también lo borra.
-- Este archivo lo arma build_import_1971ae49.py. No lo edites a mano.
-- ============================================================================

begin;

do $$
declare
  v_business uuid := '1971ae49-935c-464a-9bfc-131d76a63be3';
  v_codes    text[] := array[
--@@CODIGOS@@
  ];
  v_cats     text[] := array[
--@@NOMBRES_CATEGORIAS@@
  ];
  v_n        int;
  v_list     text;
begin
  select count(*), string_agg(mi.name, ', ' order by mi.name)
    into v_n, v_list
  from public.menu_items mi
  where mi.business_id = v_business
    and btrim(mi.sku) = any (v_codes)
    and exists (select 1 from public.order_items oi where oi.product_id = mi.id);

  if v_n > 0 then
    raise exception
      'No se borra nada: % productos de la carga ya tienen ventas (%). Desactívalos en la app.',
      v_n, v_list;
  end if;

  delete from public.menu_items mi
  where mi.business_id = v_business
    and btrim(mi.sku) = any (v_codes);
  get diagnostics v_n = row_count;

  delete from public.categories c
  where c.business_id = v_business
    and c.name = any (v_cats)
    and not exists (select 1 from public.menu_items mi where mi.category_id = c.id);

  raise notice 'Rollback: % productos borrados.', v_n;
end $$;

commit;

select
  (select count(*) from public.menu_items
   where business_id = '1971ae49-935c-464a-9bfc-131d76a63be3'::uuid) as productos_que_quedan,
  (select count(*) from public.categories
   where business_id = '1971ae49-935c-464a-9bfc-131d76a63be3'::uuid) as categorias_que_quedan;
