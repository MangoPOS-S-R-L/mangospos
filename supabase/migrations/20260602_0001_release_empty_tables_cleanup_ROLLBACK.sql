-- 20260602_0001_release_empty_tables_cleanup_ROLLBACK.sql
-- Revierte 20260602_0001_release_empty_tables_cleanup.sql:
--   desagenda el job de pg_cron y elimina la función.

begin;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid)
    from cron.job
    where jobname = 'release_empty_tables';
  end if;
exception when insufficient_privilege then
  raise notice 'Sin privilegio para desagendar pg_cron. Desagendar manualmente.';
end $$;

drop function if exists public.fn_release_empty_tables(integer);

commit;
