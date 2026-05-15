-- =============================================================================
-- ROLLBACK de `20260515_0002_permissions_backfill_and_policy.sql`.
--
-- Quita la policy nueva en `permissions` y borra los códigos backfilleados.
--
-- ⚠️ ADVERTENCIA:
--   Borrar los códigos de la tabla `permissions` también borra (CASCADE)
--   cualquier fila en `role_permissions` y `user_permission_overrides`
--   que referencie esos códigos. Si después de aplicar la migration ya
--   guardaste overrides con esos códigos, este rollback los pierde.
--
--   Si el problema fue solo con la policy, comentá el bloque DELETE y
--   corré solo el drop de la policy.
-- =============================================================================

begin;

drop policy if exists "permissions_write_admin" on public.permissions;

delete from public.permissions
where code in (
  'dashboard.acceso',
  'caja.movimientos_crear',
  'productos.acceso',
  'productos.ver',
  'productos.crear',
  'productos.editar',
  'productos.eliminar',
  'categorias.ver',
  'categorias.crear',
  'categorias.editar',
  'categorias.eliminar',
  'compras.acceso',
  'inventario.transferencias.crear',
  'inventario.transferencias.recibir'
);

commit;
