-- Rollback de `20260518_0001_kitchen_ticket_section_mode.sql`.
-- Elimina el CHECK constraint y la columna. Cualquier valor configurado
-- por admin se pierde — el negocio vuelve al comportamiento legacy
-- (siempre 'both').

begin;

alter table public.business_settings
  drop constraint if exists business_settings_kitchen_ticket_section_mode_check;

alter table public.business_settings
  drop column if exists kitchen_ticket_section_mode;

commit;
