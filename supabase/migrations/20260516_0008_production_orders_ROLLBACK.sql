-- Rollback de `20260516_0008_production_orders.sql`.
-- ⚠️ Si hay órdenes completadas con movimientos en inventory_movements
-- (reference_type='production'), esos movimientos QUEDAN (no se borran).
-- Stock real refleja la producción que ocurrió. Solo se borra el rastro
-- en production_orders/production_order_lines.

begin;

drop view if exists public.v_production_orders_summary;
drop function if exists public.fn_production_order_cancel(uuid, text);
drop function if exists public.fn_production_order_complete(uuid, numeric, jsonb);
drop function if exists public.fn_production_order_start(uuid);
drop function if exists public.fn_production_order_create(uuid, uuid, numeric, uuid, uuid, text);

-- Restaurar fn_inventory_record_movement a versión sin production_in/out
-- (mantengo el resto idéntico).
create or replace function public.fn_inventory_record_movement(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_movement_type public.movement_type,
  p_quantity numeric,
  p_cost_per_unit numeric default null,
  p_reference_id uuid default null,
  p_reference_type text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_signed_quantity numeric;
  v_movement public.inventory_movements;
begin
  if v_user_id is null then raise exception 'AUTH_REQUIRED'; end if;
  select public.user_business_role(v_user_id, p_business_id) into v_role;
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INVENTORY_ACCESS_DENIED';
  end if;
  if p_quantity is null or p_quantity = 0 then raise exception 'INVALID_QUANTITY'; end if;
  if not exists (select 1 from public.inventory_items where id = p_item_id and business_id = p_business_id) then
    raise exception 'ITEM_NOT_FOUND';
  end if;
  if not exists (select 1 from public.warehouses where id = p_warehouse_id and business_id = p_business_id and coalesce(is_active, true)) then
    raise exception 'WAREHOUSE_NOT_FOUND';
  end if;

  v_signed_quantity := case
    when p_movement_type in ('sale', 'transfer_out', 'waste') then -abs(p_quantity)
    when p_movement_type in ('purchase', 'transfer_in', 'return') then abs(p_quantity)
    else p_quantity
  end;

  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type, notes, created_by
  ) values (
    p_business_id, p_warehouse_id, p_item_id, p_movement_type,
    v_signed_quantity, p_cost_per_unit, p_reference_id, p_reference_type,
    p_notes, v_user_id
  ) returning * into v_movement;

  return jsonb_build_object(
    'id', v_movement.id,
    'business_id', v_movement.business_id,
    'warehouse_id', v_movement.warehouse_id,
    'item_id', v_movement.item_id,
    'movement_type', v_movement.movement_type,
    'quantity', v_movement.quantity,
    'created_at', v_movement.created_at
  );
end;
$$;

drop trigger if exists trg_production_orders_assign_code on public.production_orders;
drop function if exists public.fn_production_order_assign_code();

drop table if exists public.production_order_lines;
drop table if exists public.production_orders;

commit;
