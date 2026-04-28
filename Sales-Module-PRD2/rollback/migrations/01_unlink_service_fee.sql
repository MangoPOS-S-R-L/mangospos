-- =============================================================================
-- File:        rollback/migrations/01_unlink_service_fee.sql
-- Pairs with:  ../../migrations/01_link_service_fee_to_taxed_products.sql
-- Reversible:  yes
--
-- Purpose:
--   Borra TODAS las filas de `menu_item_taxes` cuyo tax es is_service_fee=true.
--   Asume que antes del deploy del PRD 2 no había service-fee links manuales
--   (verificar con SELECT count(*) previo si hay duda).
--
-- WARNING:
--   Si algún operador linkeó propina manualmente DESPUÉS del deploy del PRD 2,
--   este DELETE también la borra. Verificar conteo antes de ejecutar.
-- =============================================================================

-- Pre-check
SELECT count(*) AS service_fee_links_before_unlink
FROM public.menu_item_taxes mit
JOIN public.taxes t ON t.id = mit.tax_id
WHERE coalesce(t.is_service_fee, false) = true;

-- Borrar
BEGIN;

DELETE FROM public.menu_item_taxes mit
USING public.taxes t
WHERE t.id = mit.tax_id
  AND coalesce(t.is_service_fee, false) = true;

-- Verificar (debe ser 0)
SELECT count(*) AS service_fee_links_after_unlink
FROM public.menu_item_taxes mit
JOIN public.taxes t ON t.id = mit.tax_id
WHERE coalesce(t.is_service_fee, false) = true;

-- Si OK → COMMIT;
-- Si no → ROLLBACK;
COMMIT;
