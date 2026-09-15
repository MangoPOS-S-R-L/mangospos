-- ============================================================================
-- DIAGNÓSTICO PREVIO A LA CARGA DE PRODUCTOS.  Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Confirma las cosas de las que depende la carga del catálogo (007 BAR & SNACK):
--   1) el negocio existe y cuál es (business_type: ¿tienda?)
--   2) qué impuestos tiene (ITBIS 18%, ¿Ley 10%?), activos y con sus canales
--   3) qué áreas de comanda hay, su `code` y si tienen impresora
--   4) si ya hay catálogo (para no duplicar)
--   5) menús activos (sin menu_item_links el producto NO sale en la caja)
--   6) ajustes: kitchen_enabled (decide si hace falta área), service_fee_enabled,
--      inventory_mode, moneda
--   7) columnas vivas de las tablas que toca la carga (menu_items.barcode no
--      está en las migraciones del repo)
--   8) bodegas: la existencia inicial entra en la principal
--   9) códigos ya usados en productos e insumos
-- ============================================================================

-- 1) El negocio
select id, business_name, branch_name, business_type, country,
       status, created_at
from public.businesses
where id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid;

-- 2) Impuestos. OJO con is_service_fee: debe ser FALSE.
select id, name, rate, is_active, is_service_fee, include_in_ecf,
       apply_on_zone, apply_on_manual, apply_on_quick,
       apply_on_takeout, apply_on_delivery
from public.taxes
where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
order by name;

-- 3) Áreas de comanda, con cuántas impresoras tiene cada una.
select a.id, a.name, a.code, a.is_active,
       count(pap.printer_id) as impresoras
from public.print_areas a
left join public.print_area_printers pap on pap.area_id = a.id
where a.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
group by a.id, a.name, a.code, a.is_active
order by a.name;

-- 4) ¿Ya hay catálogo?
select
  (select count(*) from public.categories
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as categorias,
  (select count(*) from public.menu_items
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as productos,
  (select count(*) from public.menu_items
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
       and is_active) as productos_activos,
  (select count(*) from public.modifier_groups
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as grupos_modificadores,
  (select count(*) from public.menus
     where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as menus;

-- 4b) Si hay productos, cuáles (para decidir si chocan con el menú nuevo).
select c.name as categoria, mi.name, mi.price, mi.tax_mode, mi.is_active,
       mi.print_area_code,
       exists (select 1 from public.order_items oi
               where oi.product_id = mi.id) as tiene_ventas
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
order by c.name, mi.name;

-- 4c) Categorías que ya existan (el import matchea por nombre exacto).
select name, position, is_active
from public.categories
where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
order by position, name;

-- 4d) Grupos de modificadores que ya existan.
select g.name, g.min_select, g.max_select, g.is_active,
       count(m.id) as opciones
from public.modifier_groups g
left join public.modifiers m on m.group_id = g.id
where g.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
group by g.id, g.name, g.min_select, g.max_select, g.is_active
order by g.name;

-- 5) Menús. La caja filtra por menú vía menu_item_links.
select m.id, m.name, m.is_active, m.created_at,
       (select count(*) from public.menu_item_links l
         where l.menu_id = m.id) as productos_enlazados
from public.menus m
where m.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
order by m.created_at;

-- 6) Ajustes del negocio. Va con select * porque esta tabla difiere entre
--    entornos. Me interesan kitchen_enabled, service_fee_enabled,
--    inventory_mode, warehouse_sections_enabled y currency_code.
select * from public.business_settings
where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid;

-- 7) Columnas VIVAS de las tablas que toca el import. La BD de prod diverge
--    de las migraciones del repo: aquí veo qué columnas son NOT NULL sin
--    default, para que el INSERT no reviente a mitad.
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in ('categories', 'menu_items', 'menu_item_taxes',
                     'menu_item_print_areas', 'menu_item_links', 'menus',
                     'print_areas', 'modifier_groups', 'modifiers',
                     'menu_item_groups', 'inventory_items',
                     'inventory_movements', 'inventory_stock', 'warehouses')
order by table_name, ordinal_position;

-- 8) Bodegas, en el MISMO orden en que consume_inventory_from_order escoge de
--    dónde descontar la venta. La PRIMERA fila es donde entra la existencia
--    inicial: tiene que estar activa y no ser __IN_TRANSIT__.
select id, name, is_main, is_active, created_at
from public.warehouses
where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
order by is_main desc, created_at asc nulls first, id asc;

-- 9) Códigos ya usados en el negocio. La carga empareja por código de barras,
--    así que aquí veo si ya hay productos o insumos con barcode/sku.
--    Va con to_jsonb para que no reviente si alguna columna no existe.
select
  (select count(*) from public.menu_items mi
    where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
      and nullif(to_jsonb(mi)->>'barcode', '') is not null) as productos_con_barcode,
  (select count(*) from public.menu_items mi
    where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
      and nullif(to_jsonb(mi)->>'sku', '') is not null)     as productos_con_sku,
  (select count(*) from public.inventory_items ii
    where ii.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid) as insumos;
