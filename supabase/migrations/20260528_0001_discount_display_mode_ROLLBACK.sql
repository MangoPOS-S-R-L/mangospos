-- ============================================================================
-- ROLLBACK — 20260528_0001 — business_settings.discount_display_mode
-- ============================================================================
--
-- Revierte la columna `discount_display_mode`. Las apps que consulten este
-- valor caerán a su default in-code ('pre_discount' en Flutter), por lo
-- que el rollback es seguro mientras la versión de la app sea reciente.
--
-- Si vas a rollback en producción, primero asegúrate que la build del
-- cliente no asuma que la columna existe en queries `not null`.
-- ============================================================================

begin;

alter table public.business_settings
  drop column if exists discount_display_mode;

commit;
