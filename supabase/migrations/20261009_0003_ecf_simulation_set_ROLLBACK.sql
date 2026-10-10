-- =============================================================================
-- ROLLBACK — 20261009_0003 — Set de pruebas DGII: simulación e-CF
-- =============================================================================
-- OJO: borra los casos de simulación y el registro de números usados (volver a
-- generar después podría repetir e-NCF que la DGII ya recibió). Desplegar antes
-- la versión anterior de ecf-onboarding.

begin;

delete from public.ecf_test_set_cases where kind = 'sim';

alter table public.ecf_test_set_cases
  drop constraint if exists ecf_test_set_cases_kind_check,
  add constraint ecf_test_set_cases_kind_check check (kind in ('ecf', 'acecf'));

alter table public.ecf_onboarding
  drop constraint if exists ecf_onboarding_simulation_sequences_is_object;

alter table public.ecf_onboarding
  drop column if exists simulation_set_generated_at,
  drop column if exists simulation_sequences;

commit;
