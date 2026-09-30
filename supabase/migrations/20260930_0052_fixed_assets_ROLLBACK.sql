-- ROLLBACK de 20260930_0052_fixed_assets.sql
--
-- ⚠️ BORRA EL REGISTRO DE ACTIVOS FIJOS Y SU HISTORIA. No hay nada más que
--   revertir: el módulo no movió inventario, ni caja, ni compras.
--
--   Si ya se cargaron activos, exportarlos antes (UNA sola consulta, el SQL
--   Editor solo muestra el último resultado):
--     select a.code, a.name, a.category, a.brand, a.model, a.serial_number,
--            a.purchase_date, a.purchase_cost, a.status, a.retired_reason,
--            w.name as bodega, a.location_note,
--            concat_ws(' ', e.first_name, e.last_name) as responsable
--       from public.fixed_assets a
--       left join public.warehouses w on w.id = a.warehouse_id
--       left join public.employees e on e.id = a.assigned_employee_id
--      order by a.business_id, a.code;

begin;

set local lock_timeout = '5s';

drop function if exists public.fn_fixed_asset_set_status(uuid, text, text);
drop function if exists public.fn_fixed_asset_move(uuid, uuid, text, uuid, text);
drop function if exists public.fn_fixed_asset_update(uuid, jsonb);
drop function if exists public.fn_fixed_asset_create(uuid, jsonb);
drop function if exists public.fn_fixed_asset_check_refs(uuid, uuid, uuid);
drop function if exists public.fn_fixed_asset_log(
  uuid, uuid, text, uuid, uuid, text, text, uuid, uuid, text, text, text, jsonb);
drop function if exists public.fn_fixed_asset_actor_name(uuid);
drop function if exists public.fn_fixed_asset_can_manage(uuid);

-- La función que recibe la fila depende del TIPO de la tabla: va antes.
drop function if exists public.fn_fixed_asset_to_json(public.fixed_assets);

drop table if exists public.fixed_asset_movements;
drop table if exists public.fixed_assets;

-- Los permisos se quedan: quitarlos rompería roles que ya los tengan
-- asignados, y un código huérfano en el catálogo no hace daño.
-- delete from public.permissions where code like 'inventario.activos.%';

notify pgrst, 'reload schema';

commit;
