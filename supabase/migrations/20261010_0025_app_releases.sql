-- =============================================================================
-- 20261010_0025 — Versiones publicadas de la app (aviso de actualización)
-- =============================================================================
--
-- POR QUÉ. Pedido del dueño (10-oct): «una pestaña junto al sistema y, si hay
-- actualización, que lo diga». La flota corre 10 versiones distintas (169
-- equipos, de 1.8.3 a 2.0.14) y la app no tenía forma de saber que existía una
-- más nueva: el diálogo «Actualizaciones» siempre decía «está actualizado».
--
-- QUÉ HACE. app_releases: una fila por plataforma y build publicado. La app
-- compara su build instalado con el mayor de su plataforma y avisa (punto en
-- el menú de usuario + «Actualizaciones» con el detalle y el botón).
--   platform: windows | macos | android | ios | web | linux
--   download_url: instalador (Windows/Mac) o la ficha de la tienda (Android/iOS)
-- Lectura pública (anon y authenticated): no tiene datos de negocios. Solo se
-- escribe desde el SQL Editor / service_role al publicar.
--
-- Al publicar una versión (los scripts de release imprimen la fila):
--   insert into public.app_releases (platform, version, build, download_url, notes)
--   values ('macos', '2.0.21', 20021, 'https://mangopos.com/MangoPOS-2.0.21-macOS.dmg', '…')
--   on conflict (platform, build) do update
--     set version = excluded.version, download_url = excluded.download_url,
--         notes = excluded.notes, published_at = now();
--
-- IDEMPOTENTE. ROLLBACK: 20261010_0025_app_releases_ROLLBACK.sql
-- =============================================================================

begin;

create table if not exists public.app_releases (
  platform     text not null
               check (platform in ('windows', 'macos', 'android', 'ios', 'web', 'linux')),
  version      text not null,
  build        integer not null,
  download_url text,
  notes        text,
  published_at timestamptz not null default now(),
  primary key (platform, build)
);

comment on table public.app_releases is
  'Versiones publicadas de la app por plataforma; la app avisa si su build es menor (20261010_0025).';

alter table public.app_releases enable row level security;

drop policy if exists app_releases_read on public.app_releases;
create policy app_releases_read on public.app_releases
  for select to anon, authenticated
  using (true);

revoke all on public.app_releases from anon, authenticated;
grant select on public.app_releases to anon, authenticated;

commit;
