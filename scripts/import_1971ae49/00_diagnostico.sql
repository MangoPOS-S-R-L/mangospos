-- ============================================================================
-- CAFETERIA MARICELA — DIAGNÓSTICO PREVIO A LA CARGA
-- Business 1971ae49-935c-464a-9bfc-131d76a63be3
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Es UNA sola consulta: el SQL Editor de Supabase solo muestra la última.
--    1) el negocio y sus ajustes (Ley por orden, cocina, inventario)
--    2) impuestos (ITBIS 18%, ¿Ley?) con sus canales
--    3) áreas de comanda y cuántas impresoras tiene cada una  ← lo importante
--    4) menús
--    5) catálogo actual y categorías
--    6) productos que YA existen con un nombre o código de la lista
--    7) el resto del catálogo actual (hasta 80)
--
-- Este archivo lo arma build_import_1971ae49.py. No lo edites a mano.
-- ============================================================================

with
biz as (
  select '1971ae49-935c-464a-9bfc-131d76a63be3'::uuid as id
),
lista(code, name, nombre_pdf) as (
  values
    ('000105', 'AGUA CARBONATADA', 'AGUA CARBONATADA'),
    ('000037', 'ALITAS DE POLLO', 'ALITAS DE POLLO'),
    ('000098', 'APEROL SPRITZ CLASICO', 'APEROL SPRITZ CLASICO'),
    ('000008', 'AROS DE CEBOLLA', 'AROS DE CEBOLLA'),
    ('000063', 'BACON CHEESE BURGER', 'BACON CHESSE BURGER'),
    ('000020', 'BANDEJA DE 4 PERSONAS MIXTAS', 'BANDEJA DE 4 PERSONAS MIXTAS'),
    ('000109', 'BANDEJA PARA 2 PERSONAS', 'BANDEJA PARA 2 PERSONAS'),
    ('000021', 'BANDEJA PARA 6 PERSONAS MIXTAS', 'BANDEJA PARA 6 PERSONAS MIXTAS'),
    ('000022', 'BANDEJA PARA 8 PERSONAS MIXTAS', 'BANDEJA PARA 8 PERSONAS MIXTAS'),
    ('000107', 'BLOODY MARY', 'BLODY MARRY'),
    ('000095', 'BLUE LAGOON TROPICAL', 'BLUE LAGON TROPICAL'),
    ('0000100', 'BOTELLA DE AGUA', 'BOTELLA DE AGUA'),
    ('000009', 'BROCHETAS MIXTAS', 'BROCHETAS MIXTAS'),
    ('000059', 'BURGER CLASICA ANGUS', 'BURGER CLASICA ANGUS'),
    ('000060', 'BURGER CLASICA POLLO', 'BURGER CLASICA POLLO'),
    ('000069', 'BURRITO DE PIERNA', 'BURRITO DE PIERNA'),
    ('000067', 'BURRITO DE POLLO', 'BURRITO DE POLLO'),
    ('000068', 'BURRITO DE RES', 'BURRITO DE RES'),
    ('000070', 'BURRITO MIXTO', 'BURRITO MIXTO'),
    ('000024', 'CAMARONES A LA CREMA', 'CAMARONES A LA CREMA'),
    ('000025', 'CAMARONES A LA CRIOLLA', 'CAMARONES A LA CRIOLLA'),
    ('000026', 'CAMARONES A LA DIABLA', 'CAMARONES A LA DIABLA'),
    ('000023', 'CAMARONES AL AJILLO', 'CAMARONES AL AJILLO'),
    ('000065', 'CARNE SALADA', 'CARNE SALADA'),
    ('000082', 'CASAMIGOS SANDIA SMASH', 'CASA AMIGOS SANDIA SMASH'),
    ('000084', 'CASAMIGOS PINEAPPLE FIZZ', 'CASAAMIGOS PINEAPPLE FIZZ'),
    ('000132', 'CERDO ASADO + CASABE', 'CERDO ASADO + CASABE'),
    ('000032', 'CHIVO GUISADO', 'CHIVO GUISADO'),
    ('000045', 'CHURRASCO ANGUS', 'CHURRASCO ANGUS'),
    ('000052', 'CLUB SANDWICH', 'CLUB SANDWICH'),
    ('000104', 'COPA DE VINO PRIMALROOTS', 'COPA DE VINO PRIMALROOTS'),
    ('000005', 'CORONA', 'CORONA'),
    ('000093', 'COSMOPOLITAN', 'COSMOPOLITAN'),
    ('000042', 'COSTILLA BBQ', 'COSTILLA BBQ'),
    ('000007', 'CROQUETAS DE POLLO', 'CROQUETAS DE POLLO'),
    ('000058', 'CUBANO', 'CUBANO'),
    ('000061', 'DOMINICANA BURGER', 'DOMINICANA BURGER'),
    ('000047', 'DULCE DE PIÑA CON LECHE', 'DULCE DE PIÑA CON LECHE'),
    ('000091', 'EL DIABLO', 'EL DIABLO'),
    ('000012', 'ENSALADA CESAR', 'ENSALADA CESAR'),
    ('000062', 'EXTRANJERA BURGER', 'EXTRANJERA BURGER'),
    ('000044', 'FILETE DE CERDO', 'FILETE DE CERDO'),
    ('000043', 'FILETE DE RES', 'FILETE DE RES'),
    ('000051', 'HOTDOG', 'HOTDOG'),
    ('000106', 'JACK DANIEL HONEY', 'JACK DANIEL HONEY'),
    ('000114', 'JACK DANIEL OLD NO.7', 'JACK DANIEL OLD NO.7'),
    ('000099', 'JUGOS NATURALES', 'JUGOS NATURALES'),
    ('000066', 'LONGANIZA', 'LONGANIZA'),
    ('000085', 'MARGARITA DE CHINOLA', 'MARGARITA DE CHINOLA'),
    ('000086', 'MARGARITA TRADICIONAL', 'MARGARITA TRADICIONAL'),
    ('000064', 'MARICELAS BURGER', 'MARICELAS BURGER'),
    ('000090', 'MARICELAS MARGARITA', 'MARICELAS MARGARITA'),
    ('000029', 'MERO A LA CRIOLLA', 'MERO A LA CRIOLLA'),
    ('000027', 'MERO A LA PLANCHA', 'MERO A LA PLANCHA'),
    ('000028', 'MERO FRITO', 'MERO FRITO'),
    ('000089', 'MEXICAN MULE', 'MEXICAN MULE'),
    ('000035', 'MOFONGO DE CAMARONES', 'MOFONGO DE CAMARONES'),
    ('000034', 'MOFONGO DE CHICHARRON REBOZADO', 'MOFONGO DE CHICHARRON REBOZADO'),
    ('000033', 'MOFONGO DE POLLO', 'MOFONGO DE POLLO'),
    ('000036', 'MOFONGO MIXTO', 'MOFONGO MIXTO'),
    ('000080', 'MOJITO DE CHINOLA', 'MOJITO DE CHINOLA'),
    ('000078', 'MOJITO DE COCO', 'MOJITO DE COCO'),
    ('000077', 'MOJITO DE FRESA', 'MOJITO DE FRESA'),
    ('000079', 'MOJITO DE LIMON', 'MOJITO DE LIMON'),
    ('000014', 'MONDONGO', 'MONDONGO'),
    ('000006', 'MOZZARELLA STICKS', 'MOZZARELLA STICKS'),
    ('000097', 'MOSCOW MULE', 'MUSCOW MULE'),
    ('000011', 'NACHOS', 'NACHOS'),
    ('000113', 'OLD PARR', 'OLD PARR'),
    ('000083', 'PALOMA CASAMIGOS', 'PALOMA CASAAMIGOS'),
    ('0000010', 'PAPAS SAZONADAS', 'PAPAS SAZONADAS'),
    ('000016', 'PASTA ALFREDO', 'PASTA ALFREDO'),
    ('000017', 'PASTA CARBONARA', 'PASTA CARBONARA'),
    ('000019', 'PASTA CON CAMARONES', 'PASTA CON CAMARONES'),
    ('000018', 'PASTA CUATRO QUESOS', 'PASTA CUATRO QUESO'),
    ('000076', 'PATACON', 'PATACON'),
    ('000040', 'PECHUGA A LA TROPICAL', 'PECHUGA A LA TROPICAL'),
    ('000039', 'PECHUGA A LA CREMA', 'PECHUGA A LA CREMA'),
    ('000038', 'PECHUGA A LA PLANCHA', 'PECHUGA A LA PLANCHA'),
    ('000041', 'PECHUGA CORDON BLEU', 'PECHUGA CORDON BLEU'),
    ('000030', 'PESCADO FRITO', 'PESCADO FRITO'),
    ('000081', 'PIÑA COLADA', 'PIÑA COLADA'),
    ('000002', 'PRESIDENTE LIGHT', 'PRESIDENTE LIGHT'),
    ('1', 'PRESIDENTE NORMAL', 'PRESIDENTE NORMAL'),
    ('000073', 'QUESADILLA DE PIERNA', 'QUESADILLA DE PIERNA'),
    ('000071', 'QUESADILLA DE POLLO', 'QUESADILLA DE POLLO'),
    ('000072', 'QUESADILLA DE RES', 'QUESADILLA DE RES'),
    ('000074', 'QUESADILLA MIXTA', 'QUESADILLA MIXTA'),
    ('000046', 'QUESILLO', 'QUESILLO'),
    ('000031', 'RABO ENCENDIDO', 'RABO ENCENDIDO'),
    ('000096', 'RASPBERRY RUM FIZZ', 'RASPBERRY RUM FIZZ'),
    ('000101', 'REFRESCO', 'REFRESCO'),
    ('000094', 'RUM PUNCH', 'RUN PUNCH'),
    ('000050', 'SALCHIPAPA', 'SALCHIPAPA'),
    ('000057', 'SANDWICH DE PIERNA', 'SANDWICH DE PIERNA'),
    ('000055', 'SANDWICH DE POLLO', 'SANDWICH DE POLLO'),
    ('000056', 'SANDWICH JAMON Y QUESO', 'SANDWICH JAMON Y QUESO'),
    ('000003', 'SANTO LIBRE', 'SANTO LIBRE'),
    ('000004', 'SMIRNOFF', 'SMIRNOFF'),
    ('000015', 'SOPA DE CAMARONES', 'SOPA DE CAMARONES'),
    ('000013', 'SOPA DE POLLO', 'SOPA DE POLLO'),
    ('000088', 'TEQUILA SOUR', 'TEQUILA SOUR'),
    ('000087', 'TEQUILA SUNRISE', 'TEQUILA SUNRISE'),
    ('000138', 'TITO''S VODKA', 'TITO''S VODKA'),
    ('000053', 'TOSTADAS DE JAMON Y QUESO', 'TOSTADAS DE JAMON Y QUESO'),
    ('000054', 'TOSTADAS DE POLLO', 'TOSTADAS DE POLLO'),
    ('000075', 'TRIO DE TACOS', 'TRIO DE TACOS'),
    ('000135', 'VINO FRONTERA', 'VINO FRONTERA'),
    ('000048', 'YAROA DE PAPA', 'YAROA DE PAPA'),
    ('000049', 'YAROA DE PLATANO MADURO', 'YAROA DE PLATANO MADURO'),
    ('000092', 'ZOMBIE', 'ZOMBIE')
),
nk as (
  select code,
         translate(lower(regexp_replace(btrim(name), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k1,
         translate(lower(regexp_replace(btrim(nombre_pdf), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k2
  from lista
),
prods as (
  select mi.*,
         translate(lower(regexp_replace(btrim(mi.name), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k,
         exists (select 1 from public.order_items oi
                 where oi.product_id = mi.id) as vendido
  from public.menu_items mi, biz
  where mi.business_id = biz.id
),
choca as (
  select p.id
  from prods p
  where p.k in (select k1 from nk) or p.k in (select k2 from nk)
     or btrim(coalesce(p.sku, '')) in (select code from nk)
     or btrim(coalesce(p.barcode, '')) in (select code from nk)
),
tx as (
  select t.*, to_jsonb(t) as j
  from public.taxes t, biz
  where t.business_id = biz.id
),
r(orden, sub, seccion, detalle) as (
  select 1, 0, '1 Negocio',
         format('%s · tipo=%s',
                coalesce(b.j->>'business_name', b.j->>'name', '—'),
                coalesce(b.j->>'business_type', '—'))
  from (select to_jsonb(x) as j from public.businesses x, biz where x.id = biz.id) b
  union all
  select 1, 0, '1 Negocio', 'NO EXISTE'
  where not exists (select 1 from public.businesses x, biz where x.id = biz.id)

  union all
  select 1, 1, '1 Ajustes',
         format('service_fee_enabled=%s · kitchen_enabled=%s · printerless_kitchen=%s · '
                'auto_print_order=%s · inventory_mode=%s · moneda=%s · bodegas=%s',
                coalesce(s.j->>'service_fee_enabled', '—'),
                coalesce(s.j->>'kitchen_enabled', '—'),
                coalesce(s.j->>'printerless_kitchen', '—'),
                coalesce(s.j->>'auto_print_order', '—'),
                coalesce(s.j->>'inventory_mode', '—'),
                coalesce(s.j->>'currency_code', '—'),
                (select count(*) from public.warehouses w, biz where w.business_id = biz.id))
  from (select to_jsonb(bs) as j
        from public.business_settings bs, biz
        where bs.business_id = biz.id) s
  union all
  select 1, 1, '1 Ajustes', 'sin fila en business_settings'
  where not exists (select 1 from public.business_settings bs, biz where bs.business_id = biz.id)

  union all
  select 2, 0, '2 Impuesto',
         format('%s %s%% · activo=%s · is_service_fee=%s · '
                'zona=%s rápida=%s llevar=%s delivery=%s · productos vinculados=%s',
                t.name, t.rate,
                coalesce(t.j->>'is_active', '—'), coalesce(t.j->>'is_service_fee', '—'),
                coalesce(t.j->>'apply_on_zone', '—'), coalesce(t.j->>'apply_on_quick', '—'),
                coalesce(t.j->>'apply_on_takeout', '—'),
                coalesce(t.j->>'apply_on_delivery', '—'),
                (select count(*) from public.menu_item_taxes x where x.tax_id = t.id))
  from tx t
  union all
  select 2, 0, '2 Impuesto', 'ninguno'
  where not exists (select 1 from tx)

  union all
  select 3, 0, '3 Área de comanda',
         format('%s (code %s) · activa=%s · impresoras=%s · productos=%s',
                a.name, a.code, a.is_active,
                (select count(*) from public.print_area_printers p where p.area_id = a.id),
                (select count(*) from public.menu_item_print_areas x
                 where x.print_area_id = a.id))
  from public.print_areas a, biz
  where a.business_id = biz.id
  union all
  select 3, 0, '3 Área de comanda', 'ninguna'
  where not exists (select 1 from public.print_areas a, biz where a.business_id = biz.id)

  union all
  select 4, 0, '4 Menú',
         format('%s · activo=%s · productos enlazados=%s',
                m.name, m.is_active,
                (select count(*) from public.menu_item_links l where l.menu_id = m.id))
  from public.menus m, biz
  where m.business_id = biz.id
  union all
  select 4, 0, '4 Menú', 'ninguno'
  where not exists (select 1 from public.menus m, biz where m.business_id = biz.id)

  union all
  select 5, 0, '5 Catálogo',
         format('categorías=%s · productos=%s (activos %s) · con ventas=%s · '
                'modificadores=%s · tax_mode: inclusive %s / exclusive %s',
                (select count(*) from public.categories c, biz where c.business_id = biz.id),
                (select count(*) from prods),
                (select count(*) from prods where is_active),
                (select count(*) from prods where vendido),
                (select count(*) from public.modifier_groups g, biz where g.business_id = biz.id),
                (select count(*) from prods where tax_mode = 'inclusive'),
                (select count(*) from prods where tax_mode = 'exclusive'))
  union all
  select 5, 1, '5 Categoría',
         format('%s · posición %s · activa=%s · productos activos=%s',
                c.name, c.position, c.is_active,
                (select count(*) from prods p where p.category_id = c.id and p.is_active))
  from public.categories c, biz
  where c.business_id = biz.id

  union all
  select 6, 0, '6 Ya existe (nombre o código)',
         format('%s · sku %s · $%s %s · activo=%s · categoría %s · área %s · ventas=%s',
                p.name, coalesce(p.sku, '—'), p.price, p.tax_mode, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'),
                coalesce(p.print_area_code, '—'),
                case when p.vendido then 'sí' else 'no' end)
  from prods p
  where p.id in (select id from choca)
  union all
  select 6, 0, '6 Ya existe (nombre o código)', 'ninguno'
  where not exists (select 1 from choca)

  union all
  select 7, 0, '7 Otro producto del catálogo',
         format('%s · sku %s · $%s %s · activo=%s · categoría %s · área %s · ventas=%s',
                p.name, coalesce(p.sku, '—'), p.price, p.tax_mode, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'),
                coalesce(p.print_area_code, '—'),
                case when p.vendido then 'sí' else 'no' end)
  from (select * from prods
        where id not in (select id from choca)
        order by name
        limit 80) p
)
select seccion, detalle
from r
order by orden, sub, detalle;
