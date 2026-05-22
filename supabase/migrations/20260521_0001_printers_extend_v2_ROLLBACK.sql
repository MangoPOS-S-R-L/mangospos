-- Rollback de `20260521_0001_printers_extend_v2.sql`.
--
-- IMPORTANTE: Si código nuevo (orchestrator v2) ya está en producción y lee
-- `transport`/`connection_config`, este rollback lo rompe. Solo correr si
-- v2 aún no está en uso o se va a degradar de versión.

begin;

alter table public.printers
  drop constraint if exists printers_transport_check;

alter table public.printers
  drop constraint if exists printers_purpose_check;

alter table public.printers
  drop column if exists last_error;

alter table public.printers
  drop column if exists connection_config;

alter table public.printers
  drop column if exists purpose;

alter table public.printers
  drop column if exists transport;

commit;
