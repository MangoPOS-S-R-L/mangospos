-- Rollback de 20260527_0001_business_settings_currency_code.sql
-- ATENCIÓN: borra la columna currency_code y cualquier dato no-default
-- (negocios que cambiaron a USD/EUR pierden ese setting).

begin;

alter table public.business_settings
  drop constraint if exists business_settings_currency_code_check;

alter table public.business_settings
  drop column if exists currency_code;

commit;
