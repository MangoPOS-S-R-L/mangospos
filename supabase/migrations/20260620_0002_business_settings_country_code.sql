-- =============================================================================
-- Globalización por país — agrega `country_code` a `business_settings`.
-- La moneda base se DERIVA del país (ver lib/core/business/country_profile.dart):
-- el negocio elige país en el registro / Ajustes → Monedas y el cliente fija el
-- `currency_code` correspondiente. Default `DO` (República Dominicana) preserva
-- el comportamiento histórico — ningún negocio existente cambia.
--
-- Convención: ISO 3166-1 alpha-2. Mantener este CHECK sincronizado con
-- `CountryProfile.catalog` en el cliente.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists country_code text not null default 'DO';

alter table public.business_settings
  drop constraint if exists business_settings_country_code_check;

alter table public.business_settings
  add constraint business_settings_country_code_check
  check (country_code in (
    -- América
    'DO','US','CA','MX','GT','HN','NI','CR','PA','CO','VE','PE','BR','BO',
    'CL','AR','UY','PY',
    -- Europa
    'ES','DE','FR','IT','PT','GB','CH','SE','PL'
  ));

comment on column public.business_settings.country_code is
  'País del negocio (ISO 3166-1 alpha-2). La moneda base se deriva de aquí en '
  'el cliente (lib/core/business/country_profile.dart). Default DO (legacy).';

commit;
