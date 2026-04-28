-- =============================================================================
-- File:        rollback/04_restore_calculate_functions.sql
-- Pairs with:  ../04_f2.2_calculate_totals_wrappers.sql
-- Reversible:  yes
--
-- Purpose:
--   Restaura las definiciones originales (pre-PRD 2) de
--   `calculate_order_totals` y `calculate_check_totals`.
--
--   El contenido autoritativo vive en:
--     ../snapshots/03_calculate_order_totals.sql
--     ../snapshots/04_calculate_check_totals.sql
--
--   En caso de rollback urgente, ejecutar este archivo aplicará las
--   definiciones tal como estaban en producción al 2026-04-28.
-- =============================================================================

-- Restaurar calculate_order_totals (snapshot pre-PRD-2)
\i ../snapshots/03_calculate_order_totals.sql

-- Restaurar calculate_check_totals (snapshot pre-PRD-2)
\i ../snapshots/04_calculate_check_totals.sql

-- NOTA: el comando \i es del cliente psql. Si se aplica desde el SQL
-- editor de Supabase, copiar el contenido de ambos snapshots y pegarlo
-- aquí en orden.
