-- =============================================================================
-- Globalización de moneda — amplía los valores permitidos de
-- `business_settings.currency_code` de {DOP, USD, EUR} al catálogo completo de
-- monedas soportadas por el cliente (principales de América y Europa).
--
-- El cliente deriva símbolo, decimales y locale desde el código ISO 4217
-- (ver lib/core/currency/business_currency.dart). La BD solo guarda el code y
-- valida que esté dentro del catálogo. Default sigue siendo DOP — ningún
-- negocio existente cambia.
--
-- Mantener este CHECK sincronizado con `BusinessCurrency.catalog` en el cliente.
-- =============================================================================

begin;

-- Reemplazamos el CHECK viejo (DOP/USD/EUR) por el catálogo completo.
alter table public.business_settings
  drop constraint if exists business_settings_currency_code_check;

alter table public.business_settings
  add constraint business_settings_currency_code_check
  check (currency_code in (
    -- América
    'DOP','USD','CAD','MXN','BRL','ARS','CLP','COP','PEN','UYU','BOB','PYG',
    'GTQ','HNL','NIO','CRC','PAB','VES',
    -- Europa
    'EUR','GBP','CHF','SEK','NOK','DKK','PLN','CZK','HUF','RON','BGN','ISK',
    'TRY','UAH','RSD'
  ));

comment on column public.business_settings.currency_code is
  'Código ISO 4217 del catálogo soportado por el cliente (América + Europa). '
  'El símbolo, decimales y locale se derivan en el cliente '
  '(lib/core/currency/business_currency.dart). Default DOP preserva el legacy.';

commit;
