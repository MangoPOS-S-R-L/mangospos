-- ROLLBACK de 20260601_0003_cash_close_print_sales_by_area.sql
-- Quita la columna del toggle. Flutter cae al default `false` sin ella.

begin;

alter table public.business_settings
  drop column if exists cash_close_print_sales_by_area;

commit;
