-- =============================================================================
-- File:        rollback/02_drop_populate_tax_lines.sql
-- Pairs with:  ../02_f2.2_fn_populate_tax_lines.sql
-- Reversible:  yes (no destructive: solo drop de trigger + función nueva)
-- =============================================================================

DROP TRIGGER IF EXISTS trg_populate_tax_lines ON public.order_items;
DROP FUNCTION IF EXISTS public.fn_populate_tax_lines();
