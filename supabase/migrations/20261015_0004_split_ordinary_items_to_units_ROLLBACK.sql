begin;
set local lock_timeout='5s';
do $$ declare r record; begin
  for r in select definition from public.bill_split_unit_function_backups loop
    execute r.definition;
  end loop;
end $$;
-- Conservar el respaldo para permitir una reinstalación sin perder el original.
notify pgrst,'reload schema';
commit;
