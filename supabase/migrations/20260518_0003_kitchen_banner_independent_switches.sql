-- =============================================================================
-- Refactor de "modo de franjas" a 2 switches independientes.
--
-- ANTES:
--   Una sola columna `kitchen_ticket_section_mode` (text) con 4 valores
--   excluyentes. Eso obligaba al admin a elegir UNA combinación, sin
--   poder controlar cada franja por separado.
--
-- AHORA:
--   Dos columnas booleanas independientes:
--     - `kitchen_banner_dine_in`  → si TRUE, la sección de items dine-in
--       lleva su franja "PARA COMER AQUI" arriba.
--     - `kitchen_banner_takeout`  → si TRUE, la sección de items takeout
--       lleva su franja "PARA LLEVAR" arriba.
--   Los items siempre se separan por isTakeout — los switches solo
--   deciden si CADA sección imprime su franja.
--
-- BACKFILL:
--   Mapeamos los valores existentes de la columna vieja a los nuevos
--   booleanos. La columna vieja se deja en su lugar para rollback; un
--   PR futuro la puede dropear cuando ningún cliente lea desde ella.
--
-- IDEMPOTENTE: ADD COLUMN IF NOT EXISTS + UPDATE selectivo.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists kitchen_banner_dine_in boolean not null default true;

alter table public.business_settings
  add column if not exists kitchen_banner_takeout boolean not null default true;

comment on column public.business_settings.kitchen_banner_dine_in is
  'Si TRUE, la sección de items dine-in en la comanda de cocina imprime '
  'la franja inversa "PARA COMER AQUI" arriba. Si FALSE, los items '
  'dine-in se imprimen sin franja (pelados).';

comment on column public.business_settings.kitchen_banner_takeout is
  'Si TRUE, la sección de items takeout en la comanda de cocina imprime '
  'la franja inversa "PARA LLEVAR" arriba. Si FALSE, los items takeout '
  'se imprimen sin franja.';

-- Backfill desde la columna vieja, respetando la intención de cada modo.
-- Solo aplica a filas que tienen el valor por default (true, true) en
-- las columnas nuevas, para no pisar configuración del admin si éste
-- ya tocó los switches después de aplicar la migración.
update public.business_settings
set
  kitchen_banner_dine_in = case kitchen_ticket_section_mode
    when 'both'                then true
    when 'dine_in_only'        then true
    when 'takeout_only'        then false
    when 'takeout_banner_only' then false
    else true
  end,
  kitchen_banner_takeout = case kitchen_ticket_section_mode
    when 'both'                then true
    when 'dine_in_only'        then false
    when 'takeout_only'        then true
    when 'takeout_banner_only' then true
    else true
  end
where kitchen_ticket_section_mode is not null
  and kitchen_banner_dine_in = true
  and kitchen_banner_takeout = true;

commit;
