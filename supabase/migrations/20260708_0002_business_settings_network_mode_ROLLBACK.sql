-- Rollback de 20260708_0002_business_settings_network_mode.sql
begin;

alter table public.business_settings
  drop constraint if exists business_settings_network_mode_check;

alter table public.business_settings
  drop column if exists network_mode;

commit;
