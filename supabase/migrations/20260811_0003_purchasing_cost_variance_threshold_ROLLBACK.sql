-- Rollback de 20260811_0003_purchasing_cost_variance_threshold.sql

begin;

alter table public.business_settings
  drop column if exists cost_variance_threshold_pct;

commit;
