-- =============================================================================
-- File:        00_capture_current_state.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2 — pre-step
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  read-only
-- Rollback:    n/a (esto ES el rollback)
--
-- Purpose:
--   Captura las definiciones actuales de funciones y triggers que el PRD 2 va
--   a modificar. El output de cada query se pega en su archivo correspondiente
--   en este mismo folder. Si algún `CREATE OR REPLACE` posterior falla en
--   producción, este es el material para reconstruir el estado pre-PRD-2.
--
-- Apply order:
--   1. Ejecutar cada bloque numerado en Supabase (producción).
--   2. Pegar el resultado de CADA bloque en el archivo indicado.
--   3. Hacer commit de los snapshots ANTES de tocar cualquier función.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- BLOQUE 1 → guardar como  01_fn_compute_item_totals.sql
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.fn_compute_item_totals'::regproc) AS def;


-- -----------------------------------------------------------------------------
-- BLOQUE 2 → guardar como  02_fn_add_item_from_menu.sql
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.fn_add_item_from_menu'::regproc) AS def;


-- -----------------------------------------------------------------------------
-- BLOQUE 3 → guardar como  03_calculate_order_totals.sql
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.calculate_order_totals'::regproc) AS def;


-- -----------------------------------------------------------------------------
-- BLOQUE 4 → guardar como  04_calculate_check_totals.sql
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.calculate_check_totals'::regproc) AS def;


-- -----------------------------------------------------------------------------
-- BLOQUE 5 → guardar como  05_trigger_update_order_totals.sql
--
-- Esto exporta la FUNCIÓN del trigger (no el `CREATE TRIGGER` en sí, que ya
-- sabemos por qué query previa: trg_compute_item_totals BEFORE INSERT OR
-- UPDATE ON order_items FOR EACH ROW EXECUTE FUNCTION fn_compute_item_totals).
--
-- Verificamos también si existe `trigger_update_order_totals` con ese nombre
-- exacto. Si no, ajustamos.
-- -----------------------------------------------------------------------------
SELECT pg_get_functiondef('public.trigger_update_order_totals'::regproc) AS def;


-- -----------------------------------------------------------------------------
-- BLOQUE 6 → guardar como  06_all_triggers_on_order_items_and_orders.txt
--
-- Dump del estado completo de triggers en las tablas que vamos a tocar, para
-- referencia.
-- -----------------------------------------------------------------------------
SELECT
  c.relname    AS table_name,
  t.tgname     AS trigger_name,
  pg_get_triggerdef(t.oid) AS definition,
  t.tgenabled  AS enabled,
  t.tgisinternal AS is_internal
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relname IN ('order_items', 'orders', 'order_checks')
  AND c.relnamespace = 'public'::regnamespace
  AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname;


-- -----------------------------------------------------------------------------
-- BLOQUE 7 → guardar como  07_taxes_table_columns.txt
--
-- Confirma que la tabla `taxes` tiene las columnas que el PRD asume
-- (apply_on_zone, apply_on_manual, apply_on_quick, apply_on_delivery,
--  is_service_fee, etc).
-- -----------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'taxes'
ORDER BY ordinal_position;


-- -----------------------------------------------------------------------------
-- BLOQUE 8 → guardar como  08_business_settings_columns.txt
--
-- Confirma qué columnas service_fee_* viven en business_settings (las vamos
-- a dejar de leer en PRD 2; las elimina PRD 3).
-- -----------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'business_settings'
ORDER BY ordinal_position;


-- -----------------------------------------------------------------------------
-- BLOQUE 9 → guardar como  09_order_items_columns.txt
--
-- Confirma columnas relevantes (tax, tax_rate, original_tax_rate, tax_mode,
-- service_fee, etc).
-- -----------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'order_items'
ORDER BY ordinal_position;


-- -----------------------------------------------------------------------------
-- BLOQUE 10 → guardar como  10_orders_and_checks_columns.txt
-- -----------------------------------------------------------------------------
SELECT 'orders' AS tbl, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'orders'
UNION ALL
SELECT 'order_checks' AS tbl, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'order_checks'
ORDER BY tbl, column_name;


-- -----------------------------------------------------------------------------
-- BLOQUE 11 → guardar como  11_menu_item_taxes_columns.txt
-- -----------------------------------------------------------------------------
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'menu_item_taxes'
ORDER BY ordinal_position;
