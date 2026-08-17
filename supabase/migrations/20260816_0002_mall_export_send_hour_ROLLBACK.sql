-- ROLLBACK de 20260816_0002_mall_export_send_hour.sql
--
-- Vuelve a la hora fija. OJO: la Edge Function desplegada lee `send_hour_local`;
-- si quitas la columna sin revertir también la function, cae al default de
-- 1:00 AM (el código usa coalesce), así que no se rompe, solo deja de ser
-- configurable.
--
-- Aplicar con:  psql -U supabase_admin -d postgres -f <este archivo>

begin;

alter table public.business_sales_export_config
  drop constraint if exists business_sales_export_config_send_hour_local_check;

alter table public.business_sales_export_config
  drop column if exists send_hour_local;

commit;
