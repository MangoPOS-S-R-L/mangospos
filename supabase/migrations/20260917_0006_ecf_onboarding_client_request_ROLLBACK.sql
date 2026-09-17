-- =============================================================================
-- ROLLBACK — 20260917_0006 — ecf_onboarding: solicitud del cliente
-- =============================================================================

begin;

drop index if exists public.ecf_onboarding_requested_at_idx;

alter table public.ecf_onboarding
  drop column if exists requested_at,
  drop column if exists requested_by,
  drop column if exists contact_name,
  drop column if exists contact_phone,
  drop column if exists already_authorized;

commit;
