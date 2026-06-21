-- ROLLBACK de 20260619_0001 — vuelve el CHECK de currency_code al set
-- histórico {DOP, USD, EUR}.
--
-- ADVERTENCIA: si algún negocio ya migró a una moneda fuera de ese set
-- (ej. MXN, EUR-locale, etc.) este ROLLBACK fallará. En ese caso, primero
-- reasigna esos business_settings a DOP/USD/EUR antes de correr este script.

begin;

alter table public.business_settings
  drop constraint if exists business_settings_currency_code_check;

alter table public.business_settings
  add constraint business_settings_currency_code_check
  check (currency_code in ('DOP', 'USD', 'EUR'));

comment on column public.business_settings.currency_code is
  'Código ISO 4217 (DOP/USD/EUR). El símbolo (RD$, $, €) se deriva en el cliente. Default DOP para preservar comportamiento legacy.';

commit;
