-- =============================================================================
-- ROLLBACK 20260616_0004 — RPC get_consolidated_inventory
-- =============================================================================
begin;
drop function if exists public.get_consolidated_inventory(uuid);
commit;
