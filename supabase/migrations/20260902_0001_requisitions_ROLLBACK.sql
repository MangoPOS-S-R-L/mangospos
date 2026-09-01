-- ROLLBACK de 20260902_0001_requisitions.sql
--
-- ⚠️ BORRA LAS REQUISICIONES. Los movimientos de inventario que generaron NO
--   se tocan: las transferencias que ejecutaron los despachos son documentos
--   propios y siguen ahí, con su stock ya movido. Lo que se pierde es el
--   documento de la solicitud y el rastro de quién pidió qué.
--
--   Si hay requisiciones con historia que valga la pena, exportarlas antes:
--     select r.code, r.status, r.requested_at, l.item_id,
--            l.requested_qty, l.dispatched_qty, l.received_qty
--       from public.requisitions r
--       join public.requisition_lines l on l.requisition_id = r.id
--      order by r.code;

begin;

drop function if exists public.fn_requisition_cancel(uuid, text);
drop function if exists public.fn_requisition_receive(uuid, jsonb, text);
drop function if exists public.fn_requisition_dispatch(uuid, jsonb, text);
drop function if exists public.fn_requisition_create(uuid, uuid, uuid, jsonb, text);
drop function if exists public.fn_can_dispatch_warehouse(uuid, uuid);

drop table if exists public.requisition_lines;
drop table if exists public.requisitions;

-- Los permisos se quedan: quitarlos rompería roles que ya los tengan
-- asignados, y un código huérfano en el catálogo no hace daño.
-- delete from public.permissions where code like 'inventario.requisiciones.%';

commit;
