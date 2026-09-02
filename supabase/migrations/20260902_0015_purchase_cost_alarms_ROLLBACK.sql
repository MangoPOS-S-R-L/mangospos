-- Rollback de 20260902_0015_purchase_cost_alarms.sql

begin;

drop view if exists public.v_purchase_cost_dispersion;
drop view if exists public.v_purchase_cost_alarms;

alter table public.business_settings
  drop constraint if exists business_settings_cost_alarm_factor_check;
alter table public.business_settings
  drop column if exists cost_alarm_factor;

commit;
