-- =============================================================================
-- PRE-VUELO — Business fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- Solo LEE. Correr ANTES de import_products_fc3065c8.sql para confirmar
-- dos cosas que el import necesita y que no se pueden adivinar desde el repo:
--   1. Los nombres EXACTOS de los impuestos  -> van en el bloque 0 del import.
--   2. Los codes EXACTOS de las areas        -> van en el bloque 1 del areas.
--
-- Correr en Supabase Studio -> SQL Editor. Devuelve 5 resultados.
-- =============================================================================

-- 1) El negocio
select id, business_name, branch_name, business_type, country, status
from public.businesses
where id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1';

-- 2) Impuestos  ->  copia los `name` al bloque 0 del import
select name, rate, is_active, is_service_fee,
       apply_on_zone, apply_on_manual, apply_on_quick
from public.taxes
where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
order by name;

-- 3) Areas de produccion  ->  copia los `code` al bloque 1 del script de areas
select code, name, is_active
from public.print_areas
where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
order by code;

-- 4) Menus (el import engancha los productos al menu activo mas viejo;
--    si no hay ninguno, crea 'MENU PRINCIPAL')
select id, name, is_active, created_at
from public.menus
where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
order by created_at;

-- 5) Que hay ya cargado. Si productos > 0, el import hace UPDATE por sku
--    sobre los que coincidan (no duplica, pero sobrescribe nombre/precio/costo).
select
  (select count(*) from public.categories
     where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1') as categorias,
  (select count(*) from public.menu_items
     where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1') as productos,
  (select count(*) from public.menu_items
     where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
       and sku is not null) as productos_con_sku,
  (select count(*) from public.menu_items mi
     where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
       and not exists (select 1 from public.menu_item_taxes x where x.item_id = mi.id)
   ) as productos_sin_impuesto;
