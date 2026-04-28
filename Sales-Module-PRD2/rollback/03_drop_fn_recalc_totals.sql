-- =============================================================================
-- File:        rollback/03_drop_fn_recalc_totals.sql
-- Pairs with:  ../03_f2.2_fn_recalc_totals.sql
-- Reversible:  yes
-- =============================================================================

DROP FUNCTION IF EXISTS public.fn_recalc_totals(uuid);
