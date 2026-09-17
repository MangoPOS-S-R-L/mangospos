-- =============================================================================
-- 20260917_0002 — ecf_onboarding: alta de facturación electrónica por negocio
-- =============================================================================
--
-- La activación e-CF la hace un operador de MangoPOS desde el panel
-- (mangopos_administrador), no el cliente. Esta tabla guarda lo que el
-- operador va capturando mientras tanto:
--   - los datos del contribuyente TAL COMO están en la DGII (la dirección
--     FISCAL puede no ser la del local: Tropella declara Gurabo y opera en
--     Real Food Park),
--   - el ULID de la empresa en Alanube, apenas se da de alta o se vincula,
--   - el id del set de pruebas (fase 2).
--
-- El certificado digital y su contraseña NO se guardan acá ni en ninguna
-- otra tabla: pasan directo a Alanube en la misma petición.
--
-- Solo la escribe y la lee la Edge Function `ecf-onboarding` con service_role
-- después de validar `is_platform_operator()`. Por eso RLS queda encendido y
-- SIN policies: ni la POS ni el panel la tocan directo.
--
-- `business_alanube_settings` sigue siendo lo único que habilita la emisión;
-- se escribe al final, con `provision-ecf`, cuando el preflight pasa.
-- =============================================================================

begin;

create table if not exists public.ecf_onboarding (
  business_id          uuid primary key
                         references public.businesses(id) on delete cascade,
  rnc                  text,
  legal_name           text,
  trade_name           text,
  fiscal_address       text,
  province             text,
  municipality         text,
  email                text,
  alanube_company_id   text unique,
  company_linked_via   text
                         check (company_linked_via in ('registered', 'existing')),
  company_linked_at    timestamptz,
  set_test_id          text,
  created_by           uuid references auth.users(id),
  updated_by           uuid references auth.users(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on table public.ecf_onboarding is
  'Avance del alta e-CF de un negocio, capturado por un operador de MangoPOS. '
  'Solo la toca la Edge Function ecf-onboarding (service_role). No guarda el '
  'certificado digital ni su contraseña.';
comment on column public.ecf_onboarding.fiscal_address is
  'Domicilio fiscal registrado en la DGII. Puede diferir de businesses.address '
  '(dirección del local que sale en el ticket).';
comment on column public.ecf_onboarding.company_linked_via is
  'registered: la empresa se creó desde el panel (POST /company). '
  'existing: ya existía en Alanube y solo se vinculó el ULID.';
comment on column public.ecf_onboarding.set_test_id is
  'Id del set de pruebas de certificación en Alanube (POST /set-tests).';

drop trigger if exists set_ecf_onboarding_updated_at on public.ecf_onboarding;
create trigger set_ecf_onboarding_updated_at
  before update on public.ecf_onboarding
  for each row execute function public.trigger_set_updated_at();

alter table public.ecf_onboarding enable row level security;

commit;
