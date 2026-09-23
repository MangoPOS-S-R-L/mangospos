-- ============================================================================
-- MENÚ DE CÓCTELES — DIAGNÓSTICO PREVIO
-- Business e7a63240-6492-4ed5-8057-319ab91a748c
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Es UNA sola consulta a propósito: el SQL Editor de Supabase solo muestra el
-- resultado de la última. Sale una tabla (seccion, detalle):
--    1) el negocio
--    2) ajustes: propina por orden, cocina, impresión, moneda
--    3) impuestos (¿hay Ley 10%?) con sus canales
--    4) áreas de comanda y cuántas impresoras tiene cada una
--    5) menús (sin menu_item_links el producto no sale en la caja)
--    6) tamaño del catálogo actual
--    7) qué juego de impuestos usa hoy el catálogo activo
--    8) categorías actuales
--    9) productos que YA existen con un nombre del menú nuevo
--   10) productos con nombre PARECIDO (posibles duplicados: "Mojito" a secas)
--   11) columnas NOT NULL sin default que la carga no llena
-- ============================================================================

with
biz as (
  select 'e7a63240-6492-4ed5-8057-319ab91a748c'::uuid as id
),
nuestros(name) as (
  values
    ('Mojito de Coco'), ('Mojito de Limón'), ('Mojito de Fresa'),
    ('Piña Colada con Alcohol'), ('Margarita'), ('Martini'),
    ('Long Island Iced Tea'), ('Cuba Libre'), ('Gin Tonic'), ('Sangría'),
    ('Sex on the Beach'), ('Tequila Sunrise'), ('Coco Paradise'),
    ('Velvet Sunset'), ('Tropical Azotea'), ('Brisa Tropical'),
    ('Deseo Prohibido'), ('Passion Mamey'),
    ('Trago de Chivas'), ('Trago de Tequila'), ('Trago de la Casa')
),
nk as (
  select translate(lower(regexp_replace(btrim(name), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun') as k
  from nuestros
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
juegos as (
  select coalesce((select string_agg(format('%s %s%%', t.name, t.rate), ' + '
                                     order by t.rate desc, t.name)
                   from public.menu_item_taxes x
                   join public.taxes t on t.id = x.tax_id
                   where x.item_id = p.id), 'SIN IMPUESTO') as juego
  from prods p
  where p.is_active
),
llenadas(tabla, columna) as (
  values
    ('categories', 'id'), ('categories', 'business_id'), ('categories', 'name'),
    ('categories', 'position'), ('categories', 'is_active'),
    ('menu_items', 'id'), ('menu_items', 'business_id'), ('menu_items', 'category_id'),
    ('menu_items', 'name'), ('menu_items', 'price'), ('menu_items', 'tax_mode'),
    ('menu_items', 'is_active'), ('menu_items', 'is_beverage'),
    ('menu_items', 'position'), ('menu_items', 'print_area_code'),
    ('menu_item_taxes', 'item_id'), ('menu_item_taxes', 'tax_id'),
    ('menu_item_print_areas', 'menu_item_id'), ('menu_item_print_areas', 'print_area_id'),
    ('menu_item_links', 'menu_id'), ('menu_item_links', 'item_id'),
    ('menu_item_links', 'position'),
    ('menus', 'id'), ('menus', 'business_id'), ('menus', 'name'), ('menus', 'is_active'),
    ('print_areas', 'id'), ('print_areas', 'business_id'), ('print_areas', 'name'),
    ('print_areas', 'code'), ('print_areas', 'is_active')
),
faltan as (
  select c.table_name, c.column_name, c.data_type
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name in ('categories', 'menu_items', 'menu_item_taxes',
                         'menu_item_print_areas', 'menu_item_links', 'menus',
                         'print_areas')
    and c.is_nullable = 'NO'
    and c.column_default is null
    and not exists (select 1 from llenadas l
                    where l.tabla = c.table_name and l.columna = c.column_name)
),
r(orden, sub, seccion, detalle) as (
  -- 1) Negocio
  select 1, 0, '1 Negocio',
         format('%s / %s · tipo %s · país %s · estado %s · creado %s',
                b.business_name, coalesce(b.branch_name, '—'),
                coalesce(b.business_type, '—'), coalesce(b.country, '—'),
                coalesce(b.status, '—'), b.created_at::date)
  from public.businesses b, biz
  where b.id = biz.id
  union all
  select 1, 0, '1 Negocio', '✗ NO EXISTE'
  where not exists (select 1 from public.businesses b, biz where b.id = biz.id)

  -- 2) Ajustes (to_jsonb: no revienta si alguna columna no existe)
  union all
  select 2, 0, '2 Ajustes',
         format('service_fee_enabled=%s · kitchen_enabled=%s · printerless_kitchen=%s · '
                'auto_print_order=%s · moneda=%s · inventory_mode=%s',
                coalesce(s.j->>'service_fee_enabled', '—'),
                coalesce(s.j->>'kitchen_enabled', '—'),
                coalesce(s.j->>'printerless_kitchen', '—'),
                coalesce(s.j->>'auto_print_order', '—'),
                coalesce(s.j->>'currency_code', '—'),
                coalesce(s.j->>'inventory_mode', '—'))
  from (select to_jsonb(bs) as j
        from public.business_settings bs, biz
        where bs.business_id = biz.id) s
  union all
  select 2, 0, '2 Ajustes', '✗ sin fila en business_settings'
  where not exists (select 1 from public.business_settings bs, biz
                    where bs.business_id = biz.id)

  -- 3) Impuestos
  union all
  select 3, 0, '3 Impuesto',
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
  select 3, 0, '3 Impuesto', '✗ el negocio no tiene ningún impuesto'
  where not exists (select 1 from tx)

  -- 4) Áreas de comanda
  union all
  select 4, 0, '4 Área de comanda',
         format('%s (code %s) · activa=%s · impresoras=%s · productos=%s',
                a.name, a.code, a.is_active,
                (select count(*) from public.print_area_printers p where p.area_id = a.id),
                (select count(*) from public.menu_item_print_areas x
                 where x.print_area_id = a.id))
  from public.print_areas a, biz
  where a.business_id = biz.id
  union all
  select 4, 0, '4 Área de comanda', 'ninguna'
  where not exists (select 1 from public.print_areas a, biz where a.business_id = biz.id)

  -- 5) Menús
  union all
  select 5, 0, '5 Menú',
         format('%s · activo=%s · productos enlazados=%s · creado %s',
                m.name, m.is_active,
                (select count(*) from public.menu_item_links l where l.menu_id = m.id),
                m.created_at::date)
  from public.menus m, biz
  where m.business_id = biz.id
  union all
  select 5, 0, '5 Menú', 'ninguno (la carga crea "Menú Principal")'
  where not exists (select 1 from public.menus m, biz where m.business_id = biz.id)

  -- 6) Tamaño del catálogo
  union all
  select 6, 0, '6 Catálogo',
         format('categorías=%s · productos=%s (activos %s) · con ventas=%s',
                (select count(*) from public.categories c, biz where c.business_id = biz.id),
                (select count(*) from prods),
                (select count(*) from prods where is_active),
                (select count(*) from prods where vendido))

  -- 7) Juego de impuestos del catálogo activo
  union all
  select 7, 0, '7 Impuestos del catálogo activo',
         format('%s → %s productos', juego, count(*))
  from juegos
  group by juego

  -- 8) Categorías
  union all
  select 8, c.position, '8 Categoría',
         format('%s · posición %s · activa=%s · productos activos=%s',
                c.name, c.position, c.is_active,
                (select count(*) from prods p where p.category_id = c.id and p.is_active))
  from public.categories c, biz
  where c.business_id = biz.id

  -- 9) Productos que ya existen con un nombre del menú nuevo
  union all
  select 9, 0, '9 Ya existe (mismo nombre)',
         format('%s · $%s · %s · activo=%s · categoría %s · área %s · ventas=%s',
                p.name, p.price, p.tax_mode, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'),
                coalesce(p.print_area_code, '—'),
                case when p.vendido then 'sí' else 'no' end)
  from prods p
  where p.k in (select k from nk)

  -- 10) Nombres parecidos (no iguales): posibles duplicados
  union all
  select 10, 0, '10 Nombre parecido',
         format('%s · $%s · activo=%s · categoría %s · ventas=%s',
                p.name, p.price, p.is_active,
                coalesce((select c.name from public.categories c
                          where c.id = p.category_id), '—'),
                case when p.vendido then 'sí' else 'no' end)
  from prods p
  where p.k not in (select k from nk)
    and p.k ~ '(mojito|colada|margarita|martini|long island|cuba|gin |gin$|sangria|sex on|sunrise|bahama|paradise|lagoon|velvet|azotea|brisa|deseo|pass?ion|mamey|chivas|tequila|trago)'

  -- 11) Columnas NOT NULL sin default que la carga no llena
  union all
  select 11, 0, '11 Columnas',
         format('⚠ %s.%s (%s) es NOT NULL sin default y la carga no la llena',
                f.table_name, f.column_name, f.data_type)
  from faltan f
  union all
  select 11, 0, '11 Columnas', 'ok: la carga llena todas las NOT NULL sin default'
  where not exists (select 1 from faltan)
)
select seccion, detalle
from r
order by orden, sub, detalle;
