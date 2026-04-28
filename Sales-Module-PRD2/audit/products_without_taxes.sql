-- =============================================================================
-- File:        audit/products_without_taxes.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2 — auditoría operativa pre-deploy
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  read-only
--
-- Purpose:
--   Genera la lista de productos que NO tienen ningún impuesto asociado
--   en `menu_item_taxes`. Después del deploy del PRD 2, estos productos
--   van a NO cobrar nada (ITBIS ni propina).
--
--   Hoy (sistema actual): por la lógica global, esos productos cobran
--   propina al ser servidos en zona/manual aunque no tengan impuestos
--   linkeados (bug "Agua Dasany"). Después del PRD 2 ese comportamiento
--   se elimina.
--
--   Este script genera el material que se manda a cada operador piloto
--   con la pregunta:
--       "Estos productos no tienen impuestos asociados. ¿Es correcto
--        (son exentos) o falta configurarlos?"
--
--   Los que el operador confirma como olvido se asocian con ITBIS antes
--   del deploy. Los que confirma como exentos quedan así.
--
-- Apply order:
--   1. Correr en producción (read-only).
--   2. Exportar a CSV.
--   3. Filtrar por business y enviar a cada operador piloto.
-- =============================================================================

SELECT
  b.id   AS business_id,
  b.name AS business_name,
  mi.id   AS product_id,
  mi.name AS product_name,
  mi.price,
  mi.tax_mode,
  c.name AS category_name
FROM public.menu_items mi
JOIN public.businesses b   ON b.id = mi.business_id
LEFT JOIN public.categories c ON c.id = mi.category_id
WHERE NOT EXISTS (
  SELECT 1 FROM public.menu_item_taxes mit WHERE mit.item_id = mi.id
)
ORDER BY b.name, c.name NULLS LAST, mi.name;

-- Esperado al 2026-04-28: 76 filas.
-- Si el número difiere mucho al ejecutarse pre-deploy, regenerar este
-- export y comparar contra el baseline antes de comunicar.
