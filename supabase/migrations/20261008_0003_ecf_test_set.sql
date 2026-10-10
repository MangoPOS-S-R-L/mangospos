-- =============================================================================
-- 20261008_0003 — Set de pruebas de la DGII (certificación e-CF)
-- =============================================================================
--
-- El set de pruebas ya no lo genera Alanube: la DGII entrega en su portal de
-- certificación un Excel con los comprobantes exactos que hay que mandar. El
-- operador lo sube en el panel y `ecf-onboarding` arma cada XML, lo firma con
-- el certificado del cliente (que viaja solo en esa petición) y lo manda al
-- ambiente CerteCF de la DGII.
--
-- `ecf_test_set_cases`: un caso por fila del Excel, con lo que respondió la
-- DGII. Subir otro archivo reemplaza todos los casos del negocio (la DGII pide
-- reiniciar el set cuando rechaza uno).
--
-- `ecf_onboarding.dgii_test_token_enc`: token de la DGII (dura ~1 h) cifrado
-- como la clave de la OFV, para consultar los envíos sin volver a pedir el
-- certificado. No es el certificado.
--
-- Las columnas set_test_id / set_test_created_at (set de Alanube) quedan sin
-- uso; no se borran para no perder el historial.
--
-- Tablas con RLS encendido y sin policies: solo service_role.
--
-- Depende de 20260917_0002 y 20261008_0001.
-- =============================================================================

begin;

create table if not exists public.ecf_test_set_cases (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  position       integer not null,
  case_id        text not null,
  ecf_type       text not null,
  encf           text not null,
  total          numeric(18, 2),
  via            text not null check (via in ('ecf', 'rfce')),
  modifies       text,
  fields         jsonb not null check (jsonb_typeof(fields) = 'array'),
  summary_fields jsonb check (summary_fields is null or jsonb_typeof(summary_fields) = 'array'),
  status         text not null default 'pending'
                 check (status in ('pending', 'sent', 'accepted', 'conditional', 'rejected', 'error')),
  track_id       text,
  security_code  text,
  signed_xml     text,
  messages       jsonb,
  sent_at        timestamptz,
  checked_at     timestamptz,
  created_at     timestamptz not null default now(),
  constraint ecf_test_set_cases_encf_unique unique (business_id, encf)
);

create index if not exists ecf_test_set_cases_business_idx
  on public.ecf_test_set_cases (business_id, position);

alter table public.ecf_test_set_cases enable row level security;

comment on table public.ecf_test_set_cases is
  'Set de pruebas de la DGII (certificación e-CF): un caso por fila del Excel. '
  'Lo escribe solo ecf-onboarding con service_role.';
comment on column public.ecf_test_set_cases.fields is
  'Pares [columna, valor] de la hoja ECF tal cual el archivo (sin celdas vacías ni #e).';
comment on column public.ecf_test_set_cases.summary_fields is
  'E32 menor de RD$250 mil: pares de la hoja RFCE (o derivados del E32 si se subió un CSV).';
comment on column public.ecf_test_set_cases.via is
  'ecf = se manda a Recepción y se consulta el trackId; rfce = E32 < 250 mil, se manda su resumen.';
comment on column public.ecf_test_set_cases.signed_xml is
  'e-CF firmado que se mandó (los E32 < 250 mil se suben a mano en el portal de la DGII).';
comment on column public.ecf_test_set_cases.security_code is
  'Primeros 6 caracteres del SignatureValue (va en el RFCE).';

alter table public.ecf_onboarding
  add column if not exists test_set_filename          text,
  add column if not exists test_set_loaded_at         timestamptz,
  add column if not exists dgii_test_token_enc        text,
  add column if not exists dgii_test_token_expires_at timestamptz;

alter table public.ecf_onboarding
  drop constraint if exists ecf_onboarding_dgii_test_token_sealed,
  add constraint ecf_onboarding_dgii_test_token_sealed
    check (dgii_test_token_enc is null or dgii_test_token_enc like 'v1:%');

comment on column public.ecf_onboarding.test_set_filename is
  'Archivo del set de pruebas de la DGII que está cargado (ecf_test_set_cases).';
comment on column public.ecf_onboarding.dgii_test_token_enc is
  'Token de CerteCF cifrado por ecf-onboarding (AES-256-GCM, ECF_CREDENTIALS_KEY). '
  'Solo sirve para consultar los envíos del set mientras no vence.';

commit;
