-- =============================================================================
-- 20261009_0006 — Set de pruebas DGII: reemplazo atómico y aprobaciones por emisor
-- =============================================================================
--
-- 1. Cargar un set borraba los casos anteriores y DESPUÉS insertaba los nuevos,
--    en dos llamadas. Si el insert fallaba, el set quedaba vacío.
--    `fn_ecf_replace_test_set_cases` hace las dos cosas en una transacción.
--
-- 2. Aprobaciones comerciales: el lector acepta el mismo e-NCF de emisores
--    distintos (la aprobación es emisor + e-NCF), pero la unicidad era
--    (negocio, set, e-NCF) y rechazaba el archivo con 23505. Ahora los sets de
--    e-CF y de simulación conservan (negocio, set, e-NCF) y las aprobaciones
--    usan (negocio, set, emisor, e-NCF), con `issuer_rnc` nuevo.
--
-- 3. Simulación: dos «Generar» a la vez leían la misma `simulation_sequences` y
--    reservaban los MISMOS e-NCF (la DGII no deja reusarlos).
--    `fn_ecf_replace_simulation_set` bloquea la fila del alta, comprueba que las
--    secuencias siguen siendo las que leyó quien generó y, solo entonces,
--    reserva y reemplaza los casos. Si otro ganó, aborta con
--    SIMULATION_CONFLICT sin cambiar nada.
--
-- Solo las usa ecf-onboarding con service_role. Aplicar ANTES de publicar la
-- versión de ecf-onboarding que las llama.
--
-- Depende de 20261009_0003.
-- =============================================================================

begin;

alter table public.ecf_test_set_cases
  add column if not exists issuer_rnc text;

comment on column public.ecf_test_set_cases.issuer_rnc is
  'Aprobaciones comerciales (kind = acecf): RNC del emisor del e-CF aprobado, solo dígitos.';

alter table public.ecf_test_set_cases
  drop constraint if exists ecf_test_set_cases_encf_unique;
drop index if exists public.ecf_test_set_cases_encf_unique;
create unique index ecf_test_set_cases_encf_unique
  on public.ecf_test_set_cases (business_id, kind, encf)
  where kind <> 'acecf';
drop index if exists public.ecf_test_set_cases_acecf_unique;
create unique index ecf_test_set_cases_acecf_unique
  on public.ecf_test_set_cases (business_id, kind, coalesce(issuer_rnc, ''), encf)
  where kind = 'acecf';

create or replace function public.fn_ecf_replace_test_set_cases(
  p_business_id uuid,
  p_kind text,
  p_cases jsonb
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_count integer;
begin
  if p_business_id is null or p_kind is null then
    raise exception 'BUSINESS_AND_KIND_REQUIRED';
  end if;
  if jsonb_typeof(p_cases) is distinct from 'array' then
    raise exception 'CASES_MUST_BE_ARRAY';
  end if;

  delete from public.ecf_test_set_cases
  where business_id = p_business_id
    and kind = p_kind;

  insert into public.ecf_test_set_cases (
    business_id, kind, position, case_id, ecf_type, encf, total, via,
    modifies, fields, summary_fields, issuer_rnc
  )
  select p_business_id, p_kind, c.position, c.case_id, c.ecf_type, c.encf,
         c.total, c.via, c.modifies, c.fields, c.summary_fields, c.issuer_rnc
  from jsonb_to_recordset(p_cases) as c(
    position integer, case_id text, ecf_type text, encf text, total numeric,
    via text, modifies text, fields jsonb, summary_fields jsonb, issuer_rnc text
  );
  get diagnostics v_count = row_count;

  return v_count;
end;
$$;

create or replace function public.fn_ecf_replace_simulation_set(
  p_business_id uuid,
  p_user_id uuid,
  p_expected_sequences jsonb,
  p_sequences jsonb,
  p_cases jsonb
)
returns timestamptz
language plpgsql
set search_path = public
as $$
declare
  v_current jsonb;
  v_now timestamptz := now();
begin
  select simulation_sequences into v_current
  from public.ecf_onboarding
  where business_id = p_business_id
  for update;

  if not found then
    raise exception 'ONBOARDING_NOT_FOUND';
  end if;
  if v_current is distinct from coalesce(p_expected_sequences, '{}'::jsonb) then
    raise exception 'SIMULATION_CONFLICT'
      using detail = 'Otra simulación reservó números mientras se armaba esta.';
  end if;

  update public.ecf_onboarding
  set simulation_sequences = p_sequences,
      simulation_set_generated_at = v_now,
      updated_by = p_user_id
  where business_id = p_business_id;

  perform public.fn_ecf_replace_test_set_cases(p_business_id, 'sim', p_cases);

  return v_now;
end;
$$;

revoke all on function public.fn_ecf_replace_test_set_cases(uuid, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.fn_ecf_replace_simulation_set(uuid, uuid, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.fn_ecf_replace_test_set_cases(uuid, text, jsonb) to service_role;
grant execute on function public.fn_ecf_replace_simulation_set(uuid, uuid, jsonb, jsonb, jsonb) to service_role;

commit;
