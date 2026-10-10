-- =============================================================================
-- 20261009_0002 — Set de pruebas DGII: aprobaciones comerciales
-- =============================================================================
--
-- Paso 3 de la certificación ("Pruebas de datos aprobación comercial"): la DGII
-- da otro Excel en el que el contribuyente hace de COMPRADOR y aprueba (o
-- rechaza) e-CF que la DGII le "emitió". `ecf-onboarding` arma cada ACECF, lo
-- firma con el certificado del cliente y lo manda a CerteCF/AprobacionComercial.
--
-- Los casos van en la misma tabla que el set de e-CF, separados por `kind`. Los
-- e-NCF aprobados repiten la numeración del set de e-CF del cliente
-- (E310000000001...), así que la unicidad pasa a ser por tipo de set. Cargar un
-- set solo reemplaza los casos de su tipo.
--
-- Depende de 20261008_0003.
-- =============================================================================

begin;

alter table public.ecf_test_set_cases
  add column if not exists kind text not null default 'ecf';

alter table public.ecf_test_set_cases
  drop constraint if exists ecf_test_set_cases_kind_check,
  add constraint ecf_test_set_cases_kind_check check (kind in ('ecf', 'acecf')),
  drop constraint if exists ecf_test_set_cases_via_check,
  add constraint ecf_test_set_cases_via_check check (via in ('ecf', 'rfce', 'acecf')),
  drop constraint if exists ecf_test_set_cases_encf_unique,
  add constraint ecf_test_set_cases_encf_unique unique (business_id, kind, encf);

drop index if exists public.ecf_test_set_cases_business_idx;
create index if not exists ecf_test_set_cases_business_idx
  on public.ecf_test_set_cases (business_id, kind, position);

comment on column public.ecf_test_set_cases.kind is
  'ecf = pruebas de datos e-CF (+ resúmenes RFCE); acecf = pruebas de aprobación comercial.';
comment on column public.ecf_test_set_cases.via is
  'ecf = Recepción + trackId; rfce = E32 < 250 mil, se manda su resumen; acecf = aprobación comercial.';

alter table public.ecf_onboarding
  add column if not exists approval_set_filename  text,
  add column if not exists approval_set_loaded_at timestamptz;

comment on column public.ecf_onboarding.approval_set_filename is
  'Archivo de aprobaciones comerciales de la DGII que está cargado (kind = acecf).';

commit;
