-- ============================================================================
-- ESTANCIA NUEVA SPORT · CAFETERÍA — ACTIVAR todos los productos YA
-- Business 85924083-2e8e-4e64-8192-808ee24674ed            (01/10/2026)
--
-- Decisión del dueño: que salgan en la caja aunque todavía no tengan precio.
-- ⚠ Los que sigan en RD$0 se cobran GRATIS hasta que les pongan precio en
--   Productos (o hasta re-correr IMPORT_CAFETERIA.sql con la lista de precios).
-- No toca la OFERTA 3x2 de Michelob (sku 1219): esa va en Ofertas.
-- Para deshacer: el mismo update con is_active = false.
-- ============================================================================
with activados as (
  update public.menu_items
     set is_active  = true,
         updated_at = now()
   where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'
     and not is_active
     and sku is distinct from '1219'
  returning price
)
select count(*)                             as activados,
       count(*) filter (where price <= 0)   as activados_en_cero
from activados;
