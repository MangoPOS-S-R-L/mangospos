-- =============================================================================
-- Modo híbrido Hub LAN-first — agrega `network_mode` a `business_settings`.
--
-- Política de RED del LOCAL (business-level):
--   'cloud' (default) → cada caja habla directo con Supabase (comportamiento
--                       actual, intacto). Sin internet → cola local (Solo).
--   'hub'             → una computadora del local (la caja principal) es el
--                       servidor central de la LAN; todas las cajas leen/
--                       escriben de ella y el Hub es la ÚNICA subida a
--                       Supabase. Ver docs/PRD_HUB_HIBRIDO_LAN_FIRST.md.
--
-- El ROL de cada dispositivo (pos / hub / hub_backup) es device-level y vive
-- en el almacenamiento local del equipo, NO aquí — la BD solo guarda la
-- política del negocio. Default 'cloud' preserva el comportamiento histórico:
-- ningún negocio existente cambia hasta que el dueño active el modo Hub.
--
-- La app tolera la ausencia de esta columna (getter cae a 'cloud' vía
-- try/catch), así que aplicarla es seguro y reversible.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists network_mode text not null default 'cloud';

alter table public.business_settings
  drop constraint if exists business_settings_network_mode_check;

alter table public.business_settings
  add constraint business_settings_network_mode_check
  check (network_mode in ('cloud', 'hub'));

comment on column public.business_settings.network_mode is
  'Política de red del local: cloud (directo a Supabase, default) | hub '
  '(caja principal como servidor LAN, única subida). El rol del dispositivo '
  'es device-level. Ver docs/PRD_HUB_HIBRIDO_LAN_FIRST.md.';

commit;
