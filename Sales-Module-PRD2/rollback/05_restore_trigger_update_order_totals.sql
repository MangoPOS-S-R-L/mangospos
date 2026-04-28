-- =============================================================================
-- File:        rollback/05_restore_trigger_update_order_totals.sql
-- Pairs with:  ../05_f2.2_trigger_update_order_totals.sql
--
-- Purpose:
--   Restaura la versión pre-PRD-2 de trigger_update_order_totals.
--   Snapshot autoritativo: ../snapshots/05_trigger_update_order_totals.sql
--
--   En caso de rollback urgente, copiar el contenido del snapshot y
--   pegarlo aquí (o usar `\i ../snapshots/05_trigger_update_order_totals.sql`
--   si se ejecuta vía psql local).
-- =============================================================================

\i ../snapshots/05_trigger_update_order_totals.sql
