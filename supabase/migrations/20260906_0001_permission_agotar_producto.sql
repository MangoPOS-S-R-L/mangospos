-- =============================================================================
-- 20260906_0001_permission_agotar_producto.sql
--
-- Nuevo permiso `ventas.orden.agotar_producto` — el boton "Agotar producto"
-- (86) del modal de la linea de orden en la POS.
--
-- POR QUE:
--   Ese boton se le mostraba a CUALQUIERA que abriera una linea de la orden,
--   sin gate de permisos. Un toque apaga `menu_items.is_active` y el producto
--   desaparece del menu de TODAS las tablets (realtime + resync del catalogo)
--   hasta que alguien con acceso a Productos lo reactive a mano: la POS no
--   tiene "des-agotar". El dueno pidio quitarselo a los meseros y dejarlo en
--   duenos, admins, gerentes y CAJEROS.
--
-- POR QUE UN CODIGO NUEVO Y NO `productos.editar`:
--   `productos.editar` vive solo en los presets de owner/admin/manager — el
--   cajero no lo tiene, y con el se quedaba fuera. Este codigo separa "agotar
--   desde la POS" de "editar el catalogo".
--
-- QUE HACE:
--   1. Siembra el codigo en `public.permissions`. Sin esta fila el permiso es
--      DECORATIVO: `fn_save_user_access_profile` lo tira en el join en
--      silencio y `fn_user_effective_permissions` nunca lo devuelve (mismo
--      modo de fallo que arreglo 20260822_0002 con los codigos de credito).
--   2. Lo concede a los roles de sistema owner/admin/manager/cashier de TODOS
--      los negocios existentes, para que el cajero no pierda hoy lo que tenia.
--      `waiter`, `cook` y `delivery` quedan fuera A PROPOSITO — ese es el
--      cambio que se pidio. Los roles personalizados tampoco se tocan: si un
--      negocio los usa, el dueno tilda el permiso en Roles y permisos (ya
--      aparece en la grilla porque esta en el catalogo Dart).
--
-- NO REDEFINE `fn_seed_business_rbac_defaults`:
--   Rehacer ese cuerpo desde el repo pisaria lo que la funcion viva ya tenga
--   (la BD de produccion diverge de las migraciones). Para negocios NUEVOS el
--   permiso entra igual por el preset del cliente cuando el RBAC no esta
--   sembrado; si se sembro, se tilda una vez en Roles y permisos.
--
-- IDEMPOTENTE: si (upsert por code + on conflict do nothing en el grant).
-- REVERSIBLE: si, ver _ROLLBACK.
-- SIN RIESGO: solo INSERT/UPDATE en catalogo y grants. No toca funciones,
--   ni RLS, ni permisos ya asignados a un usuario concreto.
-- =============================================================================

begin;

-- 1. Catalogo -----------------------------------------------------------------
insert into public.permissions (code, name, module, description) values
  ('ventas.orden.agotar_producto',
   'Agotar producto (86) desde la orden',
   'operations',
   'Marca un producto como agotado desde la linea de la orden. Lo esconde del menu en TODOS los dispositivos y solo se puede reactivar desde Productos.')
on conflict (code) do update
  set name = excluded.name,
      module = excluded.module,
      description = excluded.description;

-- 2. Grant a los roles de sistema que lo conservan ----------------------------
insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager', 'cashier')
  and p.code = 'ventas.orden.agotar_producto'
on conflict (role_id, permission_id) do nothing;

commit;
