-- =============================================================================
-- Habilitar Realtime para inventory_stock y menu_items.
--
-- PROBLEMA:
--   El cliente Flutter se suscribe vía onPostgresChanges al canal
--   'rt:inventory_realtime' para escuchar cambios en stock y en
--   menu_items.is_active. Pero Supabase Realtime solo transmite tablas
--   incluidas en la publication `supabase_realtime`. Sin esto, el
--   listener queda silenciado y el cajero solo ve los cambios al salir
--   y volver a entrar a la pantalla (recarga manual del catálogo).
--
-- SOLUCIÓN:
--   1. Agregar ambas tablas a la publication.
--   2. Setear REPLICA IDENTITY FULL para que los eventos UPDATE incluyan
--      el row completo OLD/NEW. Necesario porque el callback compara
--      `old.is_active != new.is_active`; sin FULL solo llega la PK.
--
-- IDEMPOTENTE: se omite la tabla si ya está en la publication.
-- =============================================================================

begin;

-- inventory_stock: cualquier cambio dispara recarga del mapa de stock.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'inventory_stock'
  ) then
    execute 'alter publication supabase_realtime add table public.inventory_stock';
  end if;
end $$;

alter table public.inventory_stock replica identity full;

-- menu_items: necesario para detectar UPDATE de is_active por auto-86.
-- Sin esto, los productos desactivados solo desaparecen al salir/entrar.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'menu_items'
  ) then
    execute 'alter publication supabase_realtime add table public.menu_items';
  end if;
end $$;

alter table public.menu_items replica identity full;

commit;
