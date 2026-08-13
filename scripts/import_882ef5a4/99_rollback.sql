-- ============================================================================
-- Import de catálogo Square → MangoPOS
-- Business 882ef5a4-93eb-4e58-92c3-bf532e179d45 (licorería MONCION)
-- Fuente: MLYH9X2TGPA28_catalog-2026-08-11-0140.csv (export de Square)
-- ============================================================================
--
-- ROLLBACK — deshace el import completo.
--
-- ⚠ SOLO si el negocio no ha vendido nada todavía. Borrar productos es seguro
--   para los tickets ya emitidos (order_items.product_id es ON DELETE SET NULL
--   y el ticket conserva product_name/unit_price), pero los reportes por
--   producto pierden el enlace.
--
-- Corre los bloques EN ORDEN.
-- ============================================================================

begin;

-- 1) Movimientos y stock del import
delete from public.inventory_movements m
using public.inventory_items ii
where m.item_id = ii.id
  and ii.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
  and m.reference_type = 'initial_stock';

delete from public.inventory_stock st
using public.inventory_items ii
where st.item_id = ii.id and ii.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;

-- 2) Soltar el link antes de borrar insumos
update public.menu_items
set inventory_item_id = null, is_inventory_tracked = false
where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;

delete from public.inventory_items where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;

-- 3) Áreas
delete from public.menu_item_print_areas mipa
using public.menu_items mi
where mipa.menu_item_id = mi.id and mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;

-- 4) Productos y categorías
delete from public.menu_items  where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;
delete from public.categories  where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;

-- 5) Modo de inventario de vuelta a 'none'
update public.business_settings set inventory_mode = 'none'
where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid;

drop table if exists public._import_882ef5a4;

commit;
