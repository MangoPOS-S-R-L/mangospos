-- Rollback de 20260617_0001_promotions_happy_hour.sql
alter table public.promotions
  drop column if exists start_time,
  drop column if exists end_time;
