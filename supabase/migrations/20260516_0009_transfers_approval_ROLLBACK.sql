-- Rollback de `20260516_0009_transfers_approval.sql`.
-- ⚠️ Si hay transferencias en `pending_approval` al momento del rollback,
-- el CHECK reducido las rechazará. Antes de rollback:
--   update public.stock_transfers set status = 'cancelled'
--     where status = 'pending_approval';

begin;

drop function if exists public.fn_inventory_transfer_approve(uuid);
drop function if exists public.fn_inventory_transfer_apply_movements(uuid);

-- Restaurar fn_inventory_transfer_send a versión previa (siempre status='sent' + stock inline).
create or replace function public.fn_inventory_transfer_send(
  p_business_id uuid,
  p_from_warehouse_id uuid,
  p_to_warehouse_id uuid,
  p_items jsonb,
  p_notes text default null
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_in_transit_id uuid;
  v_transfer public.stock_transfers;
  v_item jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_cost numeric;
begin
  if p_business_id is null or p_from_warehouse_id is null or p_to_warehouse_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_from_warehouse_id = p_to_warehouse_id then
    raise exception 'SAME_WAREHOUSE';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_ITEMS';
  end if;

  v_role := public.user_business_role(auth.uid(), p_business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;
  if not exists (select 1 from public.warehouses where id = p_from_warehouse_id and business_id = p_business_id) then
    raise exception 'FROM_WAREHOUSE_NOT_FOUND';
  end if;
  if not exists (select 1 from public.warehouses where id = p_to_warehouse_id and business_id = p_business_id) then
    raise exception 'TO_WAREHOUSE_NOT_FOUND';
  end if;

  v_in_transit_id := public.ensure_in_transit_warehouse(p_business_id);

  insert into public.stock_transfers (
    business_id, from_warehouse_id, to_warehouse_id, transfer_number, status, notes, created_by
  ) values (
    p_business_id, p_from_warehouse_id, p_to_warehouse_id,
    public.fn_next_transfer_number(p_business_id), 'sent', p_notes, auth.uid()
  ) returning * into v_transfer;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := (v_item->>'item_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_cost := nullif(v_item->>'cost_per_unit','')::numeric;
    if v_item_id is null or v_qty is null or v_qty <= 0 then raise exception 'INVALID_ITEM_ROW'; end if;
    insert into public.stock_transfer_items (stock_transfer_id, item_id, quantity_sent, cost_per_unit)
      values (v_transfer.id, v_item_id, v_qty, v_cost);
    perform public.fn_inventory_record_movement(p_business_id, p_from_warehouse_id, v_item_id, 'transfer_out'::public.movement_type, v_qty, v_cost, v_transfer.id, 'stock_transfer', null);
    perform public.fn_inventory_record_movement(p_business_id, v_in_transit_id, v_item_id, 'transfer_in'::public.movement_type, v_qty, v_cost, v_transfer.id, 'stock_transfer', null);
  end loop;

  return v_transfer;
end;
$$;

-- Volver CHECK al original (3 estados).
alter table public.stock_transfers drop constraint if exists stock_transfers_status_check;
alter table public.stock_transfers
  add constraint stock_transfers_status_check
  check (status in ('sent','received','cancelled'));

alter table public.stock_transfers drop constraint if exists stock_transfers_approved_by_fkey;
alter table public.stock_transfers drop column if exists approved_at;
alter table public.stock_transfers drop column if exists approved_by;

alter table public.business_settings drop column if exists transfers_require_approval;

commit;
