-- ============================================================================
-- MENÚ DE COMIDA — DIAGNÓSTICO PREVIO
-- Business e7a63240-6492-4ed5-8057-319ab91a748c (AZOTEA 046 BAR & GRILL)
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Es UNA sola consulta: el SQL Editor de Supabase solo muestra la última.
--    1) ajustes: propina por orden, cocina, impresión
--    2) impuestos (ITBIS + LEY) con sus canales
--    3) áreas de comanda y cuántas impresoras tiene cada una  ← lo importante
--    4) menús
--    5) catálogo actual y categorías
--    6) productos que YA existen con un nombre de la lista
--    7) nombres parecidos (posibles duplicados)
-- ============================================================================

with
biz as (
  select 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid as id
),
lista(categoria, name, price, posicion) as (
  values
--@@PRODUCTOS@@
),
nk as (
  select translate(lower(regexp_replace(btrim(name), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k
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
tx as (
  select t.*, to_jsonb(t) as j
  from public.taxes t, biz
  where t.business_id = biz.id
),
r(orden, sub, seccion, detalle) as (
  select 1, 0, '1 Ajustes',
         format('service_fee_enabled=%s · kitchen_enabled=%s · printerless_kitchen=%s · '
                'auto_print_order=%s',
                coalesce(s.j->>'service_fee_enabled', '—'),
                coalesce(s.j->>'kitchen_enabled', '—'),
                coalesce(s.j->>'printerless_kitchen', '—'),
                coalesce(s.j->>'auto_print_order', '—'))
  from (select to_jsonb(bs) as j
        from public.business_settings bs, biz
        where bs.business_id = biz.id) s

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
  select 5, 0, '5 Catálogo',
         format('categorías=%s · productos=%s (activos %s) · con ventas=%s',
                (select count(*) from public.categories c, biz where c.business_id = biz.id),
                (select count(*) from prods),
                (select count(*) from prods where is_active),
                (select count(*) from prods where vendido))
  union all
  select 5, c.position, '5 Categoría',
         format('%s · posición %s · activa=%s · productos activos=%s',
                c.name, c.position, c.is_active,
                (select count(*) from prods p where p.category_id = c.id and p.is_active))
  from public.categories c, biz
  where c.business_id = biz.id

  union all
  select 6, 0, '6 Ya existe (mismo nombre)',
         format('%s · $%s · bebida=%s · activo=%s · categoría %s · área %s · ventas=%s',
                p.name, p.price, p.is_beverage, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'),
                coalesce(p.print_area_code, '—'),
                case when p.vendido then 'sí' else 'no' end)
  from prods p
  where p.k in (select k from nk)
  union all
  select 6, 0, '6 Ya existe (mismo nombre)', 'ninguno'
  where not exists (select 1 from prods p where p.k in (select k from nk))

  union all
  select 7, 0, '7 Nombre parecido',
         format('%s · $%s · activo=%s · categoría %s',
                p.name, p.price, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'))
  from prods p
  where p.k not in (select k from nk)
    and p.k ~ '(fuego|brisa|camaron|croqueta|nacho|mozzarella|pescado|pasta|pechuga|cerdo|mofongo|filete|churrasco|solomillo|costilla|picana|t-bone|chuleta|pollo|alita|brocheta|salmon|mero|chivo|ensalada|cesar|rosette|parisienne|sopa|pure|toston|papa|arroz|vegetal|batata)'
)
select seccion, detalle
from r
order by orden, sub, detalle;
