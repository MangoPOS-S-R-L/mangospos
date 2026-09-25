-- ROLLBACK de 20260924_0001_reassign_table_waiter.sql
--
-- OJO: se borra la bitacora de reasignaciones. Las mesas que ya se
-- reasignaron QUEDAN con su mesero nuevo, y los items que se congelaron
-- conservan el autor que se les estampo: deshacer eso descuadraria el
-- reporte de ventas por mesero. Si hay que revertir una reasignacion, se
-- vuelve a asignar al mesero anterior, no con esto.

begin;

drop function if exists public.fn_reassign_table_waiter(uuid, uuid, text);

drop policy if exists "tswc_select" on public.table_session_waiter_changes;
drop table if exists public.table_session_waiter_changes;

delete from public.role_permissions
 where permission_id in (
   select id from public.permissions where code = 'ventas.mesas.reasignar_mesero'
 );
delete from public.permissions where code = 'ventas.mesas.reasignar_mesero';

commit;
