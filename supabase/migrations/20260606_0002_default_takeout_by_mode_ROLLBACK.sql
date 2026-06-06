-- ROLLBACK de 20260606_0002_default_takeout_by_mode.sql

begin;

alter table public.business_settings
  drop column if exists default_takeout_quick,
  drop column if exists default_takeout_manual,
  drop column if exists default_takeout_delivery;

commit;
