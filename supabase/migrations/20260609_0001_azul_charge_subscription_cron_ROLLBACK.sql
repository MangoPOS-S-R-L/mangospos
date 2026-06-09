-- ROLLBACK de 20260609_0001_azul_charge_subscription_cron.sql
-- Desagenda el cron, borra la función y la tabla de config.
-- (No borra el esquema `private` por si otros objetos lo usan.)

begin;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'azul_charge_due';
  end if;
exception when insufficient_privilege then
  null;
end $$;

drop function if exists private.fn_azul_run_due_charges();
drop table if exists private.azul_cron_config;

commit;
