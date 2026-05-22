-- =============================================================================
-- Agrega un cuarto valor al enum-like de `kitchen_ticket_section_mode`.
--
-- VALOR NUEVO:
--   'takeout_banner_only' → items dine-in se imprimen sin franja (van
--   directo al inicio de la lista); items takeout debajo, bajo la franja
--   "PARA LLEVAR". El cocinero asume dine-in por default y solo recibe
--   alerta visual cuando hay un item para llevar. Flujo típico para
--   negocios donde el dine-in es la norma y el takeout la excepción.
--
-- CAMBIO: solo extiende el CHECK constraint existente para admitir el
-- nuevo valor. La columna y el default ('both') no cambian.
--
-- IDEMPOTENTE: DROP/CREATE del constraint.
-- =============================================================================

begin;

alter table public.business_settings
  drop constraint if exists business_settings_kitchen_ticket_section_mode_check;

alter table public.business_settings
  add constraint business_settings_kitchen_ticket_section_mode_check
  check (
    kitchen_ticket_section_mode in (
      'both',
      'dine_in_only',
      'takeout_only',
      'takeout_banner_only'
    )
  );

comment on column public.business_settings.kitchen_ticket_section_mode is
  'Controla las franjas (banners inversos) en la comanda de cocina. '
  '''both'' = separa dine-in y takeout en dos secciones (default). '
  '''dine_in_only'' = una sola franja "PARA COMER AQUI" con todos los items. '
  '''takeout_only'' = una sola franja "PARA LLEVAR" con todos los items. '
  '''takeout_banner_only'' = dine-in sin franja arriba; takeout debajo con franja "PARA LLEVAR".';

commit;
