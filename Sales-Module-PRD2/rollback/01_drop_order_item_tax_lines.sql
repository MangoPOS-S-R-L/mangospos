-- =============================================================================
-- File:        rollback/01_drop_order_item_tax_lines.sql
-- Pairs with:  ../01_f2.2_create_order_item_tax_lines.sql
-- Reversible:  destructive (datos en la tabla se pierden)
--
-- Purpose:
--   Revierte la creación de `order_item_tax_lines`. Si en el momento del
--   rollback la tabla ya tiene datos, se pierden. Esto es aceptable porque
--   en PRD 2 la tabla todavía no se "consume" por reportes (eso es PRD 3),
--   así que las filas que pueda tener son auditoría que se va a regenerar
--   prospectivamente cuando se reintente el deploy.
-- =============================================================================

DROP POLICY IF EXISTS oitl_select ON public.order_item_tax_lines;
DROP TABLE IF EXISTS public.order_item_tax_lines CASCADE;
