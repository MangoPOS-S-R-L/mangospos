-- Rollback de `20260518_0002_kitchen_section_mode_takeout_banner.sql`.
-- Restaura el CHECK constraint a los 3 valores originales. Antes de
-- correr este rollback, normalizar a 'both' cualquier fila con
-- 'takeout_banner_only' (sino el constraint falla al recrearse).

begin;

-- Normaliza filas con el valor que vamos a quitar.
update public.business_settings
set kitchen_ticket_section_mode = 'both'
where kitchen_ticket_section_mode = 'takeout_banner_only';

alter table public.business_settings
  drop constraint if exists business_settings_kitchen_ticket_section_mode_check;

alter table public.business_settings
  add constraint business_settings_kitchen_ticket_section_mode_check
  check (
    kitchen_ticket_section_mode in (
      'both',
      'dine_in_only',
      'takeout_only'
    )
  );

commit;
