-- =============================================================================
-- Setting por negocio: modo de las franjas en la comanda de cocina.
--
-- CONTEXTO:
--   La comanda actual particiona items en dos secciones con franjas
--   inversas: "PARA COMER AQUI" para items dine-in y "PARA LLEVAR" para
--   items con isTakeout=true. Algunos negocios quieren forzar una sola
--   franja siempre (ej. delivery-only solo "PARA LLEVAR", o dine-in
--   estricto solo "PARA COMER AQUI" sin separar takeout).
--
-- SOLUCIÓN:
--   Columna `kitchen_ticket_section_mode` en `business_settings` con 3
--   valores discretos. CHECK constraint para evitar valores inválidos.
--   Default `'both'` preserva el comportamiento histórico.
--
-- VALORES:
--   - 'both'         → separa items en dos secciones (legacy, default).
--   - 'dine_in_only' → todos los items bajo única franja "PARA COMER AQUI".
--   - 'takeout_only' → todos los items bajo única franja "PARA LLEVAR".
--
-- IDEMPOTENTE: ADD COLUMN IF NOT EXISTS + recrea el CHECK constraint.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists kitchen_ticket_section_mode text not null default 'both';

-- Drop & re-create el constraint para que la migración sea re-ejecutable
-- y permita ajustar los valores válidos en el futuro sin error.
alter table public.business_settings
  drop constraint if exists business_settings_kitchen_ticket_section_mode_check;

alter table public.business_settings
  add constraint business_settings_kitchen_ticket_section_mode_check
  check (kitchen_ticket_section_mode in ('both', 'dine_in_only', 'takeout_only'));

comment on column public.business_settings.kitchen_ticket_section_mode is
  'Controla las franjas (banners inversos) en la comanda de cocina. '
  '''both'' = separa dine-in y takeout en dos secciones (default). '
  '''dine_in_only'' = una sola franja "PARA COMER AQUI" con todos los items. '
  '''takeout_only'' = una sola franja "PARA LLEVAR" con todos los items.';

commit;
