-- ============================================================================
-- TÍA SARA — DIAGNÓSTICO PREVIO.  Business 6edecb1d-e940-45ff-83b5-044ca08319fb
--
-- CORRE ESTO PRIMERO Y PÉGAME EL RESULTADO. No escribe nada.
-- Confirma las cosas de las que depende la carga del menú:
--   1) el negocio existe y cuál es
--   2) qué impuestos tiene (ITBIS 18%, ¿Ley 10%?), activos y con sus canales
--   3) qué áreas de comanda hay, su `code` y si tienen impresora
--   4) si ya hay catálogo (para no duplicar)
--   5) menús activos (sin menu_item_links el producto NO sale en la caja)
--   6) ajustes: service_fee_enabled, inventory_mode, moneda
-- ============================================================================

-- 1) El negocio
select id, business_name, branch_name, business_type, country,
       status, created_at
from public.businesses
where id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid;

-- 2) Impuestos. OJO con is_service_fee: debe ser FALSE.
select id, name, rate, is_active, is_service_fee, include_in_ecf,
       apply_on_zone, apply_on_manual, apply_on_quick,
       apply_on_takeout, apply_on_delivery
from public.taxes
where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
order by name;

-- 3) Áreas de comanda, con cuántas impresoras tiene cada una.
select a.id, a.name, a.code, a.is_active,
       count(pap.printer_id) as impresoras
from public.print_areas a
left join public.print_area_printers pap on pap.area_id = a.id
where a.business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
group by a.id, a.name, a.code, a.is_active
order by a.name;

-- 4) ¿Ya hay catálogo?
select
  (select count(*) from public.categories
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid) as categorias,
  (select count(*) from public.menu_items
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid) as productos,
  (select count(*) from public.menu_items
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
       and is_active) as productos_activos,
  (select count(*) from public.modifier_groups
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid) as grupos_modificadores,
  (select count(*) from public.menus
     where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid) as menus;

-- 4b) Si hay productos, cuáles (para decidir si chocan con el menú nuevo).
select c.name as categoria, mi.name, mi.price, mi.tax_mode, mi.is_active,
       mi.print_area_code,
       exists (select 1 from public.order_items oi
               where oi.product_id = mi.id) as tiene_ventas
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
order by c.name, mi.name;

-- 4c) Categorías que ya existan (el import matchea por nombre exacto).
select name, position, is_active
from public.categories
where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
order by position, name;

-- 4d) Grupos de modificadores que ya existan.
select g.name, g.min_select, g.max_select, g.is_active,
       count(m.id) as opciones
from public.modifier_groups g
left join public.modifiers m on m.group_id = g.id
where g.business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
group by g.id, g.name, g.min_select, g.max_select, g.is_active
order by g.name;

-- 5) Menús. La caja filtra por menú vía menu_item_links.
select m.id, m.name, m.is_active, m.created_at,
       (select count(*) from public.menu_item_links l
         where l.menu_id = m.id) as productos_enlazados
from public.menus m
where m.business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid
order by m.created_at;

-- 6) Ajustes del negocio. Va con select * porque esta tabla difiere entre
--    entornos. Me interesan service_fee_enabled, inventory_mode,
--    currency_code y auto_print_order.
select * from public.business_settings
where business_id = '6edecb1d-e940-45ff-83b5-044ca08319fb'::uuid;

-- 7) Columnas VIVAS de las tablas que toca el import. La BD de prod diverge
--    de las migraciones del repo: aquí veo qué columnas son NOT NULL sin
--    default, para que el INSERT no reviente a mitad.
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in ('categories', 'menu_items', 'menu_item_taxes',
                     'menu_item_print_areas', 'menu_item_links', 'menus',
                     'print_areas', 'modifier_groups', 'modifiers',
                     'menu_item_groups')
order by table_name, ordinal_position;
