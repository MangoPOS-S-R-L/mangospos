-- ============================================================================
-- DIAGNÓSTICO previo a la carga de productos
-- Business 882ef5a4-93eb-4e58-92c3-bf532e179d45
-- ============================================================================
--
-- Correr TODO de una vez en Supabase Studio → SQL Editor y pegar los
-- resultados. Es 100% solo-lectura: no modifica nada.
--
-- Lo que necesito saber antes de escribir el seed:
--   1. Qué negocio es y en qué estado está el inventario.
--   2. Qué impuestos existen ya (¿hay ITBIS 18? ¿hay el 10% de ley?)
--      y cómo están configurados los apply_on_*.
--   3. Qué áreas de producción existen (los `code` exactos) — porque
--      menu_items.print_area_code es NOT NULL DEFAULT 'kitchen_hot' y si
--      ese código no existe en el negocio, "Enviar a cocina" revienta.
--   4. Qué bodegas hay (para el stock inicial de lo inventariable).
--   5. Qué categorías/productos ya están cargados (para no duplicar).
-- ============================================================================


-- ── 1) Negocio + ajustes ────────────────────────────────────────────────────
-- OJO: `service_fee_enabled` DEBE quedar en false. Si sale true, el 10% se
-- cobraría dos veces al vincularlo por producto (ver seed_business_6da31542_link_tax_10.sql).
-- `inventory_mode`: none = el motor no descuenta nada. Hay que subirlo a basic/advanced.
select
  b.id,
  b.business_name,
  b.branch_name,
  b.business_type,
  b.country,
  b.domain,
  b.status,
  bs.inventory_mode,
  bs.service_fee_enabled,
  bs.service_fee_rate,
  bs.default_tax_rate,
  bs.allow_negative_stock
from public.businesses b
left join public.business_settings bs on bs.business_id = b.id
where b.id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;


-- ── 2) Impuestos existentes ─────────────────────────────────────────────────
-- `t.*` a propósito: la BD viva tiene columnas (apply_on_*, is_service_fee)
-- que el schema.sql del repo no refleja completo.
select
  t.*,
  (select count(*)
     from public.menu_item_taxes mit
     join public.menu_items mi on mi.id = mit.item_id
    where mit.tax_id = t.id and mi.is_active)  as productos_vinculados
from public.taxes t
where t.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
order by t.rate, t.name;


-- ── 3) Áreas de producción + impresoras ─────────────────────────────────────
-- Necesito los `code` EXACTOS (kitchen / bar / pizzeria / ...).
select
  a.code,
  a.name,
  a.is_active,
  count(pap.printer_id) filter (where pap.enabled) as impresoras_activas
from public.print_areas a
left join public.print_area_printers pap on pap.area_id = a.id
where a.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
group by a.code, a.name, a.is_active
order by a.code;


-- ── 4) Bodegas ──────────────────────────────────────────────────────────────
select id, name, is_main, is_active
from public.warehouses
where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
order by is_main desc nulls last, name;


-- ── 5) Categorías ya existentes ─────────────────────────────────────────────
select
  c.position,
  c.name,
  c.is_active,
  count(mi.id) filter (where mi.is_active) as productos_activos
from public.categories c
left join public.menu_items mi
       on mi.category_id = c.id and mi.business_id = c.business_id
where c.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
group by c.position, c.name, c.is_active
order by c.position, c.name;


-- ── 6) Resumen del catálogo actual ──────────────────────────────────────────
select
  count(*)                                                     as productos,
  count(*) filter (where mi.is_active)                         as activos,
  count(*) filter (where mi.tax_mode = 'inclusive')            as inclusivos,
  count(*) filter (where mi.is_inventory_tracked)              as inventariables,
  count(*) filter (where mi.inventory_item_id is not null)     as con_link_inventario,
  count(distinct mi.print_area_code)                           as codigos_area_distintos,
  string_agg(distinct mi.print_area_code, ', ')                as codigos_area
from public.menu_items mi
where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;


-- ── 7) Insumos de inventario ya cargados ────────────────────────────────────
select count(*) as insumos, count(*) filter (where is_active) as activos
from public.inventory_items
where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;
