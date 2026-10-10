-- =============================================================================
-- ROLLBACK — 20261008_0003 — Set de pruebas de la DGII
-- =============================================================================
-- OJO: borra los casos cargados y lo que respondió la DGII. Desplegar antes la
-- versión anterior de ecf-onboarding (la nueva usa esta tabla y columnas).

begin;

drop table if exists public.ecf_test_set_cases;

alter table public.ecf_onboarding
  drop constraint if exists ecf_onboarding_dgii_test_token_sealed;

alter table public.ecf_onboarding
  drop column if exists test_set_filename,
  drop column if exists test_set_loaded_at,
  drop column if exists dgii_test_token_enc,
  drop column if exists dgii_test_token_expires_at;

commit;
