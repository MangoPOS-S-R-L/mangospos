-- =============================================================================
-- Rollback de 20260529_0003 — elimina fn_consolidate_keeper_atomic.
-- Importante: si esta función ya está siendo llamada por Flutter, revertir
-- esta migración rompe el merge de subcuentas hasta que se redeploye una
-- versión del cliente que use el patrón viejo (UPDATE + DELETE separados).
-- =============================================================================

DROP FUNCTION IF EXISTS public.fn_consolidate_keeper_atomic(uuid, uuid[], numeric, numeric);
