-- ROLLBACK de 20260829_0001_realtime_memberships.sql
-- Saca `memberships` de la publication `supabase_realtime`. La app sigue
-- funcionando: el repo de billing y AccountAccessRepository caen a poll.

begin;

do $$
begin
  if exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'memberships'
  ) then
    execute 'alter publication supabase_realtime drop table public.memberships';
  end if;
end $$;

commit;
