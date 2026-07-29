-- =============================================================================
-- ROLLBACK 20260729_0002 — Elimina la RPC fn_kds_completed_today.
-- La app cae automáticamente a la vista kds_completed_today (fallback en
-- KitchenRepository.getCompletedTodayItems).
-- =============================================================================

begin;

drop function if exists public.fn_kds_completed_today(uuid);

commit;
