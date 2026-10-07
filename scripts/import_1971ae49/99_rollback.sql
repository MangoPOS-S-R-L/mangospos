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
    '000105',
    '000037',
    '000098',
    '000008',
    '000063',
    '000020',
    '000109',
    '000021',
    '000022',
    '000107',
    '000095',
    '0000100',
    '000009',
    '000059',
    '000060',
    '000069',
    '000067',
    '000068',
    '000070',
    '000024',
    '000025',
    '000026',
    '000023',
    '000065',
    '000082',
    '000084',
    '000132',
    '000032',
    '000045',
    '000052',
    '000104',
    '000005',
    '000093',
    '000042',
    '000007',
    '000058',
    '000061',
    '000047',
    '000091',
    '000012',
    '000062',
    '000044',
    '000043',
    '000051',
    '000106',
    '000114',
    '000099',
    '000066',
    '000085',
    '000086',
    '000064',
    '000090',
    '000029',
    '000027',
    '000028',
    '000089',
    '000035',
    '000034',
    '000033',
    '000036',
    '000080',
    '000078',
    '000077',
    '000079',
    '000014',
    '000006',
    '000097',
    '000011',
    '000113',
    '000083',
    '0000010',
    '000016',
    '000017',
    '000019',
    '000018',
    '000076',
    '000040',
    '000039',
    '000038',
    '000041',
    '000030',
    '000081',
    '000002',
    '1',
    '000073',
    '000071',
    '000072',
    '000074',
    '000046',
    '000031',
    '000096',
    '000101',
    '000094',
    '000050',
    '000057',
    '000055',
    '000056',
    '000003',
    '000004',
    '000015',
    '000013',
    '000088',
    '000087',
    '000138',
    '000053',
    '000054',
    '000075',
    '000135',
    '000048',
    '000049',
    '000092'
  ];
  v_cats     text[] := array[
    'PICADERAS',
    'BANDEJAS',
    'HAMBURGUESAS',
    'SANDWICHES Y TOSTADAS',
    'MEXICANO',
    'MOFONGOS',
    'POLLO',
    'CARNES',
    'MARISCOS Y PESCADOS',
    'COMIDA CRIOLLA',
    'PASTAS',
    'SOPAS Y ENSALADAS',
    'POSTRES',
    'COCTELES',
    'CERVEZAS',
    'LICORES Y VINOS',
    'BEBIDAS'
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
