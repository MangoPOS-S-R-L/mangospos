-- =============================================================================
-- Agrega `currency_code` a `business_settings` para que la moneda del negocio
-- deje de estar hardcoded como `RD$` en el cliente. Default `DOP` (peso
-- dominicano) preserva el comportamiento histórico — los reportes de los 25+
-- negocios existentes no cambian. Cuando un comercio quiera cambiar moneda
-- (USD turístico, EUR), edita su business_settings.
--
-- Convención: usamos códigos ISO 4217 para `currency_code`. El símbolo
-- (RD$, $, €) se deriva en el cliente — la BD solo guarda el code.
--
-- Valores permitidos: mismo set que `bank_accounts.currency` para mantener
-- consistencia entre módulos.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists currency_code text not null default 'DOP';

-- CHECK separado para que la migración funcione idempotente (si ya hay rows
-- con valor distinto, el ALTER COLUMN ... ADD CHECK fallaría).
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'business_settings_currency_code_check'
  ) then
    alter table public.business_settings
      add constraint business_settings_currency_code_check
      check (currency_code in ('DOP', 'USD', 'EUR'));
  end if;
end$$;

comment on column public.business_settings.currency_code is
  'Código ISO 4217 (DOP/USD/EUR). El símbolo (RD$, $, €) se deriva en el cliente. Default DOP para preservar comportamiento legacy.';

commit;
