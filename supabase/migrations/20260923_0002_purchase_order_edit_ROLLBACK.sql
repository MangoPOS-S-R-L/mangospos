-- ROLLBACK de 20260923_0002_purchase_order_edit.sql
--
-- OJO: la bitacora purchase_order_edits se BORRA con este rollback y con ella
-- el antes/despues de las correcciones que ya se hicieron. Los movimientos de
-- inventario que la funcion posteo NO se revierten: son historia del kardex y
-- deshacerlos aqui descuadraria el stock. Si hay que revertir una correccion,
-- se hace editando la orden de vuelta, no con esto.

begin;

drop function if exists public.fn_purchase_order_update(uuid, jsonb, jsonb, text, text);

drop policy if exists "poe_select" on public.purchase_order_edits;
drop table if exists public.purchase_order_edits;

delete from public.role_permissions
 where permission_id in (
   select id from public.permissions where code = 'compras.ordenes.editar'
 );
delete from public.permissions where code = 'compras.ordenes.editar';

commit;
