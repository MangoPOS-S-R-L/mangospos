-- =============================================================================
-- ROLLBACK — 20261008_0001 — ecf_onboarding: requisitos completos
-- =============================================================================
-- OJO: borra las claves de la OFV guardadas. Desplegar antes la versión
-- anterior de ecf-onboarding (la nueva pide estas columnas).

begin;

alter table public.ecf_onboarding
  drop constraint if exists ecf_onboarding_branches_is_array,
  drop constraint if exists ecf_onboarding_ofv_password_sealed;

alter table public.ecf_onboarding
  drop column if exists phone,
  drop column if exists legal_rep_name,
  drop column if exists branches,
  drop column if exists ecf_types,
  drop column if exists ofv_user,
  drop column if exists ofv_password_enc,
  drop column if exists ofv_password_updated_at;

commit;
