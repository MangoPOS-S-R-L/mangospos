-- =============================================================================
-- ROLLBACK — 20260916_0002 — business_settings.multimesero_table_owner_only
-- =============================================================================

begin;

alter table public.business_settings
  drop column if exists multimesero_table_owner_only;

commit;
