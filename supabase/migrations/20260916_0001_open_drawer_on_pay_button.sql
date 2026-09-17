-- =============================================================================
-- 20260916_0001 — business_settings.open_drawer_on_pay_button
-- =============================================================================
--
-- Segundo disparador de la gaveta, independiente de `open_drawer_on_cash`:
--   - open_drawer_on_cash       → abre al IMPRIMIR el recibo de un cobro en
--                                 efectivo (va pegado al ticket).
--   - open_drawer_on_pay_button → abre en cuanto el cajero toca "Pagar", antes
--                                 de elegir método, para tener el cambio a mano.
--
-- El pulso (ESC p 0 25 250, o ESC * r D 1 en Star raster) va a la impresora de
-- recibos de la caja. Si no tiene gaveta RJ-11, el comando se ignora.
--
-- Default `false`: nadie cambia de comportamiento sin opt-in.
--
-- Safe deploy: Flutter cae al default `false` si la columna aún no existe.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists open_drawer_on_pay_button boolean
    not null default false;

comment on column public.business_settings.open_drawer_on_pay_button is
  'Si true, tocar "Pagar" en la POS dispara el pulso de apertura de gaveta '
  'en la impresora de recibos de la caja, sin esperar al cobro. Default '
  'false. Independiente de open_drawer_on_cash.';

commit;
