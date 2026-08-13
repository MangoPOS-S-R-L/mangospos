-- ============================================================================
-- Import de catálogo Square → MangoPOS
-- Business 882ef5a4-93eb-4e58-92c3-bf532e179d45 (licorería MONCION)
-- Fuente: MLYH9X2TGPA28_catalog-2026-08-11-0140.csv (export de Square)
-- ============================================================================
--
-- PASO 5 — Verificación final y limpieza del staging.
--
-- Conteo esperado por categoría:
--   Cerveza       235
--   Wine          327
--   Whiskey       101
--   Rum            65
--   Tequila        69
--   Vodka          59
--   Ginebra        13
--   Cognac         22
--   Brandy          4
--   Licores        63
--   Champaña       66
--   Pre-Mix        50
--   Mix            16
--   Tragos         57
--   Cócteles       21
--   Fiesta         45
--   Comida         16
--   Hookah          3
--   Jugos          52
--   Papitas        16
--   Chicle         31
--   Cigarros       28
--   Cigarrillos     9
--   Tabaco          6
--   E-Cig          95
--   Misc           47
--   TOTAL        1516
--
-- Inventariables esperados: 1374
-- ============================================================================

-- 1) Resumen general
select
  (select count(*) from public.categories
    where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid)                        as categorias,
  (select count(*) from public.menu_items
    where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and is_active)          as productos,
  (select count(*) from public.menu_items
    where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and is_inventory_tracked) as inventariables,
  (select count(*) from public.inventory_items
    where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid)                        as insumos,
  (select count(*) from public.menu_item_taxes mit
     join public.menu_items mi on mi.id = mit.item_id
    where mi.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid)                     as vinculos_impuesto;

-- 2) Productos con código de barra (para el scanner)
select count(*) filter (where barcode is not null) as con_barcode,
       count(*)                                    as total
from public.menu_items
where business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and is_active;

-- 3) LIMPIEZA — borra el staging. Corre esto SOLO cuando los pasos 2, 3 y 4
--    hayan pasado sus verificaciones.
-- drop table if exists public._import_882ef5a4;
