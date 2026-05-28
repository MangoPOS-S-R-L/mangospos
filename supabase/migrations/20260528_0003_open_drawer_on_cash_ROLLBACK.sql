-- =============================================================================
-- ROLLBACK — 20260528_0003 — business_settings.open_drawer_on_cash
-- =============================================================================

begin;

alter table public.business_settings
  drop column if exists open_drawer_on_cash;

commit;
