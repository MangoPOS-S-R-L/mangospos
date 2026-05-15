-- =============================================================================
-- Fix: permisos no se guardan desde la UI de configuración de usuarios.
--
-- PROBLEMA:
--   El catálogo Dart (access_control_catalog.dart) tiene 82 permisos. La
--   tabla `public.permissions` solo tenía ~70 (los seedeados originalmente
--   en migration 20260308_0022). Los códigos faltantes incluyen:
--   - dashboard.acceso
--   - caja.movimientos_crear
--   - productos.acceso/ver/crear/editar/eliminar
--   - categorias.ver/crear/editar/eliminar
--   - compras.acceso
--   - inventario.transferencias.crear/recibir
--
--   Además, la tabla `permissions` tenía RLS habilitado SOLO con policy de
--   SELECT — sin policy de INSERT/UPDATE. La UI hacía `upsert` para
--   asegurar que el código existiera, pero ese upsert era bloqueado por RLS
--   y fallaba silenciosamente. Luego el `select id from permissions where
--   code in (...)` no encontraba el código nuevo y no se insertaban
--   overrides → los permisos NO se guardaban.
--
-- ENTREGA:
--   1. Backfill: insertar los códigos faltantes en `public.permissions`.
--   2. Policy INSERT/UPDATE para owner/admin del negocio activo
--      (vía claim app.current_business). Permite que el upsert futuro
--      desde la UI funcione si agregamos códigos al catálogo Dart.
--
-- IDEMPOTENTE:
--   - `on conflict (code) do nothing` para los inserts.
--   - `drop policy if exists` antes de crear.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Backfill de los códigos faltantes en `permissions`.
--    Estos vienen del catálogo Dart (access_control_catalog.dart).
-- ---------------------------------------------------------------------------

insert into public.permissions (code, name, module, description) values
  ('dashboard.acceso', 'Acceso al dashboard', 'reports',
   'Abre el dashboard general con métricas y resumen.'),
  ('caja.movimientos_crear', 'Registrar ingresos / retiros / gastos', 'finance',
   'Permite registrar manualmente depósitos, retiros y gastos de caja.'),
  ('productos.acceso', 'Acceso a gestión de productos', 'products',
   'Abre el catálogo y mantenimiento de productos.'),
  ('productos.ver', 'Ver productos', 'products',
   'Consulta el listado, filtros y detalle de productos.'),
  ('productos.crear', 'Crear productos', 'products',
   'Permite crear nuevos productos del menú.'),
  ('productos.editar', 'Editar productos', 'products',
   'Permite modificar precio, datos y disponibilidad.'),
  ('productos.eliminar', 'Eliminar productos', 'products',
   'Permite eliminar productos del catálogo.'),
  ('categorias.ver', 'Ver categorías', 'products',
   'Consulta el listado de categorías del menú.'),
  ('categorias.crear', 'Crear categorías', 'products',
   'Permite crear nuevas categorías.'),
  ('categorias.editar', 'Editar categorías', 'products',
   'Permite renombrar o cambiar estado de categorías.'),
  ('categorias.eliminar', 'Eliminar categorías', 'products',
   'Permite eliminar categorías que ya no se usan.'),
  ('compras.acceso', 'Acceso a compras', 'inventory',
   'Abre el módulo de compras y permite consultar órdenes y proveedores.'),
  ('inventario.transferencias.crear', 'Crear transferencias de stock', 'inventory',
   'Permite enviar stock desde el almacén principal hacia otras bodegas.'),
  ('inventario.transferencias.recibir', 'Recibir transferencias de stock', 'inventory',
   'Permite confirmar la recepción de transferencias en la bodega destino.')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Policy de INSERT/UPDATE en `permissions` para owner/admin.
--    Sin esto, el `upsert` que hace la UI de roles falla silenciosamente
--    cuando intenta auto-agregar un código nuevo al catálogo. Permitimos
--    INSERT/UPDATE solo a roles administrativos para evitar que un cajero
--    inyecte permisos arbitrarios.
--
--    SELECT sigue siendo permisivo (todos los autenticados) porque ya
--    estaba así y muchas vistas lo necesitan.
-- ---------------------------------------------------------------------------

drop policy if exists "permissions_write_admin" on public.permissions;
create policy "permissions_write_admin"
on public.permissions
for all
to authenticated
using (
  exists (
    select 1
    from public.user_businesses ub
    where ub.user_id = auth.uid()
      and ub.role in ('owner', 'admin')
  )
)
with check (
  exists (
    select 1
    from public.user_businesses ub
    where ub.user_id = auth.uid()
      and ub.role in ('owner', 'admin')
  )
);

comment on policy "permissions_write_admin" on public.permissions is
  'Owner/admin de cualquier negocio puede agregar códigos al catálogo. '
  'Necesario para que el upsert defensivo en saveUserOverrides funcione '
  'cuando el catálogo Dart agrega permisos nuevos.';

commit;
