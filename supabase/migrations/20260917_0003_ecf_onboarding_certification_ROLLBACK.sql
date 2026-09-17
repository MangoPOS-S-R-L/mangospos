-- =============================================================================
-- ROLLBACK — 20260917_0003 — ecf_onboarding: avance de la certificación
-- =============================================================================

begin;

alter table public.ecf_onboarding
  drop column if exists postulation_signed_at,
  drop column if exists set_test_created_at,
  drop column if exists declaration_signed_at,
  drop column if exists roles_signed_at,
  drop column if exists dgii_authorized_at;

commit;
