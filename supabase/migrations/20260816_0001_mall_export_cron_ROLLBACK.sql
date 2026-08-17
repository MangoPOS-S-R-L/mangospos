-- ROLLBACK de 20260816_0001_mall_export_cron.sql
--
-- Deja el envío como estaba: solo desde la app, en el cierre de caja.
-- OJO: si vuelves a este estado, reactiva el envío de la app o la plaza deja de
-- recibir el archivo por completo:
--
--   update public.business_sales_export_config
--      set send_on_cash_close = true
--    where enabled = true;
--
-- La bitácora se conserva por defecto (es histórico de envíos). El DROP está
-- comentado al final por si de verdad quieres borrarla.

begin;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'mall_sales_export_daily';
  end if;
exception when insufficient_privilege then
  raise notice 'Sin privilegio para pg_cron; desagendar mall_sales_export_daily a mano.';
end $$;

drop function if exists private.fn_mall_export_run_daily();
drop table if exists private.mall_export_cron_config;

-- Bitácora: se conserva. Descomenta solo si quieres perder el historial.
-- drop policy if exists mall_export_log_read on public.mall_sales_export_log;
-- drop table if exists public.mall_sales_export_log;

commit;
