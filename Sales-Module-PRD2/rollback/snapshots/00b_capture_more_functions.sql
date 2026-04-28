-- =============================================================================
-- File:        00b_capture_more_functions.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2 — pre-step (additional capture)
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  read-only
--
-- Purpose:
--   En la inspección del snapshot anterior detectamos dos funciones referenciadas
--   por `fn_add_item_from_menu` que el PRD original no menciona. Sin entenderlas
--   no podemos reemplazar nada sin riesgo:
--
--   - fn_recalc_order_totals      → la llama tras insertar el item
--   - fn_resolve_order_item_tax_profile → devuelve tax_mode y tax_rate del producto
--
-- Apply order:
--   1. Ejecutar los 2 bloques en Supabase (producción).
--   2. Pegar el resultado en los archivos indicados.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- BLOQUE 12 → guardar como  12_fn_recalc_order_totals.sql
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.fn_recalc_order_totals'::regproc) AS def;


-- -----------------------------------------------------------------------------
-- BLOQUE 13 → guardar como  13_fn_resolve_order_item_tax_profile.sql
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.fn_resolve_order_item_tax_profile'::regproc) AS def;


-- -----------------------------------------------------------------------------
-- BLOQUE 14 (opcional) → guardar como  14_fn_check_max_checks.sql
-- BLOQUE 15 (opcional) → guardar como  15_fn_get_or_create_check.sql
-- BLOQUE 16 (opcional) → guardar como  16_fn_oi_sync_qty_quantity.sql
--
-- Estas no las vamos a modificar pero las capturamos por completitud (si algo
-- las llama indirectamente en el path nuevo, queremos saberlo).
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.fn_check_max_checks'::regproc) AS def;
SELECT pg_get_functiondef('public.fn_get_or_create_check'::regproc) AS def;
SELECT pg_get_functiondef('public.fn_oi_sync_qty_quantity'::regproc) AS def;
