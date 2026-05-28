-- =============================================================================
-- ROLLBACK — 20260528_0002 — business_settings.header_destinations_disabled
-- =============================================================================
--
-- Revierte la columna. Apps que la consulten caen al default in-code
-- (lista vacía = nada oculto), así que es safe rollback con la app actual.
-- =============================================================================

begin;

alter table public.business_settings
  drop column if exists header_destinations_disabled;

commit;
