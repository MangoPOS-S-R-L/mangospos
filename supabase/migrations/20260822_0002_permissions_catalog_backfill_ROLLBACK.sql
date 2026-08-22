-- =============================================================================
-- ROLLBACK de `20260822_0002_permissions_catalog_backfill.sql`.
--
-- Borra los 13 códigos backfilleados del catálogo.
--
-- ⚠️ ADVERTENCIA:
--   Borrar un código de `permissions` borra en CASCADE cualquier fila de
--   `role_permissions` y `user_permission_overrides` que lo referencie. Si
--   ya asignaste Créditos / Conteo / Producción a alguien después de
--   aplicar la migration, este rollback le quita esos permisos.
--
--   Este rollback existe por completitud: el revert razonable es NO
--   correrlo. Un catálogo con códigos de más no rompe nada (la UI solo
--   muestra los que están en el catálogo Dart).
-- =============================================================================

begin;

delete from public.permissions
where code in (
  'creditos.acceso',
  'creditos.vender',
  'creditos.abonar',
  'compras.ordenes.credito',
  'inventario.transferencias.aprobar',
  'inventario.conteo.acceso',
  'inventario.conteo.crear',
  'inventario.conteo.completar',
  'inventario.conteo.anular',
  'produccion.acceso',
  'produccion.crear',
  'produccion.completar',
  'produccion.anular'
);

commit;
