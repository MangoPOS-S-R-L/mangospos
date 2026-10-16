begin;
set local lock_timeout='5s';
drop function if exists public.fn_apply_bill_split(uuid,uuid,jsonb,jsonb,uuid[],bigint,integer,boolean);
do $$ declare r record; begin
  for r in select definition from public.bill_split_function_backups loop execute r.definition; end loop;
end $$;
drop function if exists public.fn_finish_bill_split(uuid,uuid[]);
drop function if exists public.fn_bill_split_check_protected(uuid);
drop function if exists public.fn_lock_bill_split_order(uuid);
-- Conservar bitácora y respaldos para que reinstalar no duplique operaciones.
notify pgrst,'reload schema';
commit;
