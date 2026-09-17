-- =============================================================================
-- ROLLBACK — 20260916_0001 — business_settings.open_drawer_on_pay_button
-- =============================================================================

begin;

alter table public.business_settings
  drop column if exists open_drawer_on_pay_button;

commit;
