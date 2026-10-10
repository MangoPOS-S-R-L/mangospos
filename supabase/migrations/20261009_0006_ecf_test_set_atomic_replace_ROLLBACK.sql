-- Rollback manual de 20261009_0006. Vuelve a la unicidad (negocio, set, e-NCF)
-- para todos los sets: si hay aprobaciones con el mismo e-NCF de dos emisores,
-- el último paso falla y hay que borrar ese set de aprobaciones antes.
-- La versión de ecf-onboarding que llama estas funciones deja de funcionar
-- para cargar sets y generar la simulación: volver también a la anterior.
begin;

drop function if exists public.fn_ecf_replace_simulation_set(uuid, uuid, jsonb, jsonb, jsonb);
drop function if exists public.fn_ecf_replace_test_set_cases(uuid, text, jsonb);

drop index if exists public.ecf_test_set_cases_acecf_unique;
drop index if exists public.ecf_test_set_cases_encf_unique;
alter table public.ecf_test_set_cases
  drop column if exists issuer_rnc;
alter table public.ecf_test_set_cases
  add constraint ecf_test_set_cases_encf_unique unique (business_id, kind, encf);

commit;
