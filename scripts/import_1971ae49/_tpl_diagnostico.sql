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
--@@LISTA@@
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
