-- ============================================================================
-- DIAGNÓSTICO PREVIO A LA CARGA — business b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee
-- Fuente: "Catalogo de productos (Transformados)", 07/10/2026, 190 filas.
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Es UNA sola consulta: el SQL Editor de Supabase solo muestra la última.
--    1) el negocio y sus ajustes (Ley por orden, cocina, delivery)
--    2) impuestos: ITBIS 18% y Ley 10% con sus canales
--    3) áreas de comanda (producción) y sus impresoras
--    4) menús, categorías y grupos de modificadores que ya hay
--    5) CADA producto que ya subiste y con qué fila del CSV casa  ← lo importante
--    6) cuántos de la lista faltan
--
-- Este archivo lo arma build_import_b0bd6f20.py. No lo edites a mano.
-- ============================================================================

with
biz as (
  select 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee'::uuid as id
),
-- Nombres (ya normalizados) con los que una fila del CSV podría estar en la
-- caja, y a qué va en la carga.
lista(k, destino, producto) as (
  values
--@@LISTA@@
),
prods as (
  select mi.*,
         btrim(regexp_replace(
           translate(lower(mi.name), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'),
           '[^a-z0-9]+', ' ', 'g')) as k,
         (select count(*) from public.order_items oi where oi.product_id = mi.id) as ventas
  from public.menu_items mi, biz
  where mi.business_id = biz.id
),
casa as (
  select p.id,
         string_agg(distinct l.destino, ' | ') as destino,
         count(distinct l.producto) as n_productos
  from prods p
  join lista l on l.k = p.k
  group by p.id
),
tx as (
  select t.*, to_jsonb(t) as j
  from public.taxes t, biz
  where t.business_id = biz.id
),
r(orden, sub, seccion, detalle) as (
  select 1, 0, '1 Negocio',
         format('%s · tipo=%s · estado=%s · creado %s',
                coalesce(b.j->>'business_name', b.j->>'name', '—'),
                coalesce(b.j->>'business_type', '—'),
                coalesce(b.j->>'status', '—'),
                left(coalesce(b.j->>'created_at', '—'), 10))
  from (select to_jsonb(x) as j from public.businesses x, biz where x.id = biz.id) b
  union all
  select 1, 0, '1 Negocio', '✗ NO EXISTE'
  where not exists (select 1 from public.businesses x, biz where x.id = biz.id)

  union all
  select 1, 1, '1 Ajustes',
         format('service_fee_enabled=%s · kitchen_enabled=%s · printerless_kitchen=%s · '
                'auto_print_order=%s · inventory_mode=%s · moneda=%s · '
                'delivery_fee_required=%s · delivery_fee_presets=%s',
                coalesce(s.j->>'service_fee_enabled', '—'),
                coalesce(s.j->>'kitchen_enabled', '—'),
                coalesce(s.j->>'printerless_kitchen', '—'),
                coalesce(s.j->>'auto_print_order', '—'),
                coalesce(s.j->>'inventory_mode', '—'),
                coalesce(s.j->>'currency_code', '—'),
                coalesce(s.j->>'delivery_fee_required', '—'),
                coalesce(s.j->>'delivery_fee_presets', '—'))
  from (select to_jsonb(bs) as j
        from public.business_settings bs, biz
        where bs.business_id = biz.id) s
  union all
  select 1, 1, '1 Ajustes', '✗ sin fila en business_settings'
  where not exists (select 1 from public.business_settings bs, biz where bs.business_id = biz.id)

  union all
  select 2, 0, '2 Impuesto',
         format('%s %s%% · activo=%s · is_service_fee=%s · include_in_ecf=%s · '
                'zona=%s manual=%s rápida=%s llevar=%s delivery=%s · productos vinculados=%s',
                t.name, t.rate,
                coalesce(t.j->>'is_active', '—'), coalesce(t.j->>'is_service_fee', '—'),
                coalesce(t.j->>'include_in_ecf', '—'),
                coalesce(t.j->>'apply_on_zone', '—'), coalesce(t.j->>'apply_on_manual', '—'),
                coalesce(t.j->>'apply_on_quick', '—'), coalesce(t.j->>'apply_on_takeout', '—'),
                coalesce(t.j->>'apply_on_delivery', '—'),
                (select count(*) from public.menu_item_taxes x where x.tax_id = t.id))
  from tx t
  union all
  select 2, 0, '2 Impuesto', '✗ el negocio no tiene ningún impuesto'
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
  select 3, 0, '3 Área de comanda', 'ninguna (la carga crea Cocina y Bar)'
  where not exists (select 1 from public.print_areas a, biz where a.business_id = biz.id)

  union all
  select 4, 0, '4 Menú',
         format('%s · activo=%s · productos enlazados=%s',
                m.name, m.is_active,
                (select count(*) from public.menu_item_links l where l.menu_id = m.id))
  from public.menus m, biz
  where m.business_id = biz.id
  union all
  select 4, 0, '4 Menú', 'ninguno (la carga crea "Menú Principal")'
  where not exists (select 1 from public.menus m, biz where m.business_id = biz.id)

  union all
  select 4, 1, '4 Catálogo',
         format('categorías=%s · productos=%s (activos %s) · con ventas=%s · '
                'grupos de modificadores=%s · tax_mode: inclusive %s / exclusive %s',
                (select count(*) from public.categories c, biz where c.business_id = biz.id),
                (select count(*) from prods),
                (select count(*) from prods where is_active),
                (select count(*) from prods where ventas > 0),
                (select count(*) from public.modifier_groups g, biz where g.business_id = biz.id),
                (select count(*) from prods where tax_mode = 'inclusive'),
                (select count(*) from prods where tax_mode = 'exclusive'))

  union all
  select 4, 2, '4 Categoría',
         format('%s · posición %s · activa=%s · productos activos=%s',
                c.name, c.position, c.is_active,
                (select count(*) from prods p where p.category_id = c.id and p.is_active))
  from public.categories c, biz
  where c.business_id = biz.id

  union all
  select 4, 3, '4 Grupo de modificadores',
         format('%s · min=%s max=%s · %s · activo=%s · productos=%s · opciones: %s',
                g.name, g.min_select, g.max_select,
                coalesce(to_jsonb(g)->>'display_type', '—'), g.is_active,
                (select count(*) from public.menu_item_groups y where y.group_id = g.id),
                coalesce((select string_agg(m.name || ' $' || m.price_delta, ', ')
                          from public.modifiers m where m.group_id = g.id), '—'))
  from public.modifier_groups g, biz
  where g.business_id = biz.id

  union all
  select 5, 0, '5 Ya subido',
         format('%s · $%s %s · activo=%s · %s · impuestos %s · área %s · grupos %s · ventas %s  →  %s',
                p.name, p.price, p.tax_mode, p.is_active,
                coalesce((select c.name from public.categories c where c.id = p.category_id), 'sin categoría'),
                coalesce((select string_agg(t.name || ' ' || t.rate || '%', '+' order by t.rate desc)
                          from public.menu_item_taxes x join public.taxes t on t.id = x.tax_id
                          where x.item_id = p.id), 'NINGUNO'),
                coalesce((select string_agg(a.code, ',')
                          from public.menu_item_print_areas x
                          join public.print_areas a on a.id = x.print_area_id
                          where x.menu_item_id = p.id), 'N:M —')
                  || ' / legacy ' || coalesce(p.print_area_code, '—'),
                (select count(*) from public.menu_item_groups y where y.menu_item_id = p.id),
                p.ventas,
                case when c.id is null then 'NO está en el CSV'
                     when c.n_productos > 1 then '⚠ casa con VARIOS: ' || c.destino
                     else c.destino end)
  from prods p
  left join casa c on c.id = p.id

  union all
  select 6, 0, '6 Resumen',
         format('productos de la lista: %s · ya subidos: %s · faltan: %s · '
                'productos del catálogo que no están en el CSV: %s',
                (select count(distinct producto) from lista where producto is not null),
                (select count(distinct l.producto) from lista l
                 where l.producto is not null and l.k in (select k from prods)),
                (select count(distinct l.producto) from lista l
                 where l.producto is not null
                   and l.producto not in (select l2.producto from lista l2
                                          where l2.producto is not null
                                            and l2.k in (select k from prods))),
                (select count(*) from prods p where p.id not in (select id from casa)))
)
select seccion, detalle
from r
order by orden, sub, detalle;
