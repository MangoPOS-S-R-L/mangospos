-- ROLLBACK de 20260620_0002 — quita `country_code` de `business_settings`.
-- La moneda (`currency_code`) NO se toca: queda como esté configurada.

begin;

alter table public.business_settings
  drop constraint if exists business_settings_country_code_check;

alter table public.business_settings
  drop column if exists country_code;

commit;
