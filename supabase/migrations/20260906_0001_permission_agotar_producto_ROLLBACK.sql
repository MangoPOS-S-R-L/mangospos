-- Rollback de 20260906_0001_permission_agotar_producto.sql
--
-- Borra los grants y el codigo del catalogo. Al desaparecer del catalogo, el
-- cliente deja de recibirlo y el boton "Agotar producto" queda oculto para
-- todo el que no caiga en el preset del cliente (owner/admin por wildcard).
-- Si lo que quieres es solo devolverle el boton a los meseros, NO corras
-- esto: tildales el permiso en Roles y permisos.

begin;

delete from public.user_permission_overrides o
using public.permissions p
where p.id = o.permission_id
  and p.code = 'ventas.orden.agotar_producto';

delete from public.role_permissions rp
using public.permissions p
where p.id = rp.permission_id
  and p.code = 'ventas.orden.agotar_producto';

delete from public.permissions
where code = 'ventas.orden.agotar_producto';

commit;
