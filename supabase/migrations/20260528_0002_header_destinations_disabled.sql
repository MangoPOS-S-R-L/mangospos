-- =============================================================================
-- 20260528_0002 — business_settings.header_destinations_disabled
-- =============================================================================
--
-- Permite que el owner/admin oculte destinos del header (topbar / drawer
-- móvil) para todos los empleados del business — independiente de los
-- permisos por rol.
--
-- Reglas finales de visibilidad en el shell:
--   destino visible para un empleado ⇔
--     (rol del empleado tiene `permissionCode` del destino)
--     AND (destino.route NO está en business_settings.header_destinations_disabled)
--
-- Almacenamos un array de routes (strings) — los `route` de
-- `ShellDestination` en Dart (`AppRoutes.dashboard`, `AppRoutes.sales`,
-- etc.). Default `'{}'` = nada deshabilitado = comportamiento histórico.
--
-- Safe deploy: si la app vieja consulta este valor antes de la migración,
-- Flutter cae al default `[]` y todo se muestra como antes.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists header_destinations_disabled text[]
    not null default '{}'::text[];

comment on column public.business_settings.header_destinations_disabled is
  'Routes de destinos del header (topbar/drawer) que el owner/admin ha '
  'ocultado para todos los empleados del business. Default {} = nada '
  'oculto. Se combina con los permisos por rol — un destino se muestra '
  'solo si el rol lo permite Y no está en esta lista.';

commit;
