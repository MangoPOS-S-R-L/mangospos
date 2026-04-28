-- =============================================================================
-- File:        migrations/01_link_service_fee_to_taxed_products.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.5 — deploy
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes (con DELETE inverso)
-- Rollback:    rollback/migrations/01_unlink_service_fee.sql
--
-- Purpose:
--   Configuración pre-código del modelo unificado (OQ2-5 = A).
--
--   Hoy la propina se aplica globalmente por origin (sin estar linkeada
--   a productos individuales). Cuando se despliegue el código nuevo del
--   PRD 2, la propina pasa a leerse desde `menu_item_taxes` como
--   cualquier otro impuesto. Si no se linkea explícitamente, los
--   productos dejarían de cobrar propina (regresión funcional).
--
--   Este script preserva el comportamiento actual: linkea cada tax con
--   `is_service_fee=true` a TODOS los productos del mismo business que
--   ya tributan al menos un impuesto no-service-fee. Es decir:
--
--   - Producto con ITBIS asociado → además se le linkea la propina del
--     business. Mantiene su comportamiento.
--   - Producto SIN ningún impuesto asociado (los 76 detectados en F2.1)
--     → NO se le linkea propina. Pasa a quedar realmente exento (cierra
--     el bug de "Agua Dasany cobra propina sin estar configurada").
--
--   El operador puede ajustar después vía el script de auditoría
--   `audit/products_without_taxes.sql`.
--
--   El INSERT es idempotente (NOT EXISTS) → puede correrse múltiples
--   veces sin duplicar.
--
-- Apply order:
--   1. Staging (validar conteo).
--   2. Producción, INMEDIATAMENTE ANTES de aplicar los SQL 02-07 del
--      PRD 2 (los que cambian el código). El orden importa porque el
--      código vigente filtra `is_service_fee=false` al leer
--      `menu_item_taxes`, así que las nuevas filas son inertes hasta
--      que el código nuevo entre en vigor.
-- =============================================================================

-- Pre-check: capturar conteo previo (debe ser 0 si nunca se corrió antes).
-- Pegar resultado en bitácora de deploy.
SELECT count(*) AS service_fee_links_before
FROM public.menu_item_taxes mit
JOIN public.taxes t ON t.id = mit.tax_id
WHERE coalesce(t.is_service_fee, false) = true;

-- Aplicar:
INSERT INTO public.menu_item_taxes (item_id, tax_id)
SELECT mi.id, t.id
FROM public.menu_items mi
JOIN public.taxes t
  ON t.business_id = mi.business_id
WHERE coalesce(t.is_service_fee, false) = true
  AND coalesce(t.is_active, true)
  -- Solo productos que ya tributan AL MENOS un impuesto no-service-fee.
  -- Esto preserva el comportamiento actual sin agregar propina a los
  -- productos que están explícitamente exentos.
  AND EXISTS (
    SELECT 1
    FROM public.menu_item_taxes existing
    JOIN public.taxes et ON et.id = existing.tax_id
    WHERE existing.item_id = mi.id
      AND coalesce(et.is_service_fee, false) = false
  )
  -- Idempotencia: no insertar si ya existe el link.
  AND NOT EXISTS (
    SELECT 1
    FROM public.menu_item_taxes mit2
    WHERE mit2.item_id = mi.id AND mit2.tax_id = t.id
  );

-- Post-check: confirmar conteo después.
SELECT count(*) AS service_fee_links_after
FROM public.menu_item_taxes mit
JOIN public.taxes t ON t.id = mit.tax_id
WHERE coalesce(t.is_service_fee, false) = true;
