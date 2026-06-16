-- =============================================================================
-- ROLLBACK 20260616_0003 — vista kds_completed_today
-- =============================================================================
begin;
drop view if exists public.kds_completed_today;
commit;
