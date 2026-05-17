-- Rollback de `20260517_0003_realtime_inventory.sql`.
-- Quita las tablas de la publication y devuelve REPLICA IDENTITY al
-- default (sin OLD completo en UPDATEs).

begin;

do $$
begin
  if exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'inventory_stock'
  ) then
    execute 'alter publication supabase_realtime drop table public.inventory_stock';
  end if;
end $$;

alter table public.inventory_stock replica identity default;

do $$
begin
  if exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'menu_items'
  ) then
    execute 'alter publication supabase_realtime drop table public.menu_items';
  end if;
end $$;

alter table public.menu_items replica identity default;

commit;
