-- =============================================================================
-- 20260528_0003 — business_settings.open_drawer_on_cash
-- =============================================================================
--
-- Activa el envío del comando ESC/POS de apertura de gaveta (ESC p 0 25 250)
-- junto con la impresión del recibo cuando el método de pago es efectivo.
-- Si la impresora fiscal/cashier tiene una gaveta conectada por RJ-11, se
-- abre automáticamente; si no tiene, el comando se ignora silenciosamente
-- (es el comportamiento estándar del hardware ESC/POS).
--
-- Default `false` para preservar el comportamiento de todos los negocios
-- existentes que no tienen gaveta física conectada — un cambio silencioso
-- no debería cambiar el flujo de cobro de nadie sin opt-in.
--
-- Safe deploy: Flutter cae al default `false` si la columna aún no existe
-- (pre-migración) o si la query falla.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists open_drawer_on_cash boolean
    not null default false;

comment on column public.business_settings.open_drawer_on_cash is
  'Si true, los pagos en efectivo disparan el comando ESC/POS de apertura '
  'de gaveta en la impresora asignada al área fiscal/cashier. Default '
  'false. Se ignora silenciosamente si la impresora no tiene gaveta '
  'conectada físicamente.';

commit;
