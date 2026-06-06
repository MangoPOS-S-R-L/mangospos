-- =============================================================================
-- ROLLBACK de 20260605_0006 — restaura fn_split_items_equally SIN la guarda de
-- ofertas (vuelve a partir las líneas [DEAL:] en el split equitativo).
-- =============================================================================
-- Para revertir, re-aplicar la versión previa de la función:
--   supabase/migrations/20260512_0004_split_round_robin_distribution.sql
-- (es un `create or replace` con la misma firma; deja la función sin la guarda).
-- =============================================================================

-- Sin cambios automáticos: re-ejecutar 20260512_0004_split_round_robin_distribution.sql
-- para restaurar el comportamiento anterior.
select 1;
