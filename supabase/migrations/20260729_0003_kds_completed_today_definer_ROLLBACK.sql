-- =============================================================================
-- ROLLBACK 20260729_0003 — Reactiva security_invoker en kds_completed_today
-- (vuelve al estado que dejó 20260729_0001; OJO: con RLS de order_items
-- vigente, filas con business_id NULL desaparecen para authenticated).
-- =============================================================================

begin;

alter view public.kds_completed_today set (security_invoker = on);

commit;
