-- =============================================================================
-- ROLLBACK — 20261009_0002 — Set de pruebas DGII: aprobaciones comerciales
-- =============================================================================
-- OJO: borra las aprobaciones comerciales cargadas. Desplegar antes la versión
-- anterior de ecf-onboarding (la nueva usa `kind`).

begin;

delete from public.ecf_test_set_cases where kind = 'acecf';

alter table public.ecf_test_set_cases
  drop constraint if exists ecf_test_set_cases_encf_unique,
  add constraint ecf_test_set_cases_encf_unique unique (business_id, encf),
  drop constraint if exists ecf_test_set_cases_via_check,
  add constraint ecf_test_set_cases_via_check check (via in ('ecf', 'rfce')),
  drop constraint if exists ecf_test_set_cases_kind_check;

drop index if exists public.ecf_test_set_cases_business_idx;
create index if not exists ecf_test_set_cases_business_idx
  on public.ecf_test_set_cases (business_id, position);

alter table public.ecf_test_set_cases drop column if exists kind;

alter table public.ecf_onboarding
  drop column if exists approval_set_filename,
  drop column if exists approval_set_loaded_at;

commit;
